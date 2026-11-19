import AppKit
import ImageIO

/// Holds the history in memory and persists it to
/// ~/Library/Application Support/Clipshelf (history.json + images/).
@MainActor
final class ClipStore: ObservableObject {
    @Published private(set) var clips: [Clip] = []

    /// Unpinned items beyond this count are dropped, oldest first.
    let maxUnpinned = 500

    let directory: URL
    let imagesDirectory: URL
    private var historyURL: URL { directory.appendingPathComponent("history.json") }
    private var saveWork: DispatchWorkItem?

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("Clipshelf", isDirectory: true)
        imagesDirectory = directory.appendingPathComponent("images", isDirectory: true)
        try? FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        // History can contain anything you copied: keep it readable by this user only.
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        load()
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: historyURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let loaded = try? decoder.decode([Clip].self, from: data) {
            clips = loaded
        } else {
            // Never overwrite a history file we could not read.
            let backup = directory.appendingPathComponent("history.unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: historyURL, to: backup)
        }
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func saveNow() {
        saveWork?.cancel()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(clips) else { return }
        try? data.write(to: historyURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: historyURL.path)
    }

    // MARK: Mutations

    /// Adds a clip, or moves an identical existing one back to the top.
    func add(_ clip: Clip, imageData: Data? = nil, imageExtension: String = "png") {
        var clip = clip
        if let index = clips.firstIndex(where: { $0.hash == clip.hash }) {
            var existing = clips.remove(at: index)
            existing.createdAt = Date()
            existing.sourceApp = clip.sourceApp ?? existing.sourceApp
            existing.sourceBundleID = clip.sourceBundleID ?? existing.sourceBundleID
            clips.insert(existing, at: 0)
            scheduleSave()
            return
        }
        if let imageData {
            let name = "\(clip.id.uuidString).\(imageExtension)"
            do {
                try imageData.write(to: imagesDirectory.appendingPathComponent(name), options: .atomic)
            } catch {
                return
            }
            clip.imageFile = name
        }
        clips.insert(clip, at: 0)
        trim()
        scheduleSave()
    }

    func touch(_ clip: Clip) {
        guard let index = clips.firstIndex(where: { $0.id == clip.id }) else { return }
        var existing = clips.remove(at: index)
        existing.createdAt = Date()
        clips.insert(existing, at: 0)
        scheduleSave()
    }

    func togglePin(_ clip: Clip) {
        guard let index = clips.firstIndex(where: { $0.id == clip.id }) else { return }
        clips[index].pinned.toggle()
        trim()
        scheduleSave()
    }

    func delete(_ clip: Clip) {
        guard let index = clips.firstIndex(where: { $0.id == clip.id }) else { return }
        removeImage(of: clips[index])
        clips.remove(at: index)
        scheduleSave()
    }

    func clearUnpinned() {
        for clip in clips where !clip.pinned { removeImage(of: clip) }
        clips.removeAll { !$0.pinned }
        scheduleSave()
    }

    private func trim() {
        var unpinnedSeen = 0
        var kept: [Clip] = []
        for clip in clips {
            if clip.pinned {
                kept.append(clip)
            } else if unpinnedSeen < maxUnpinned {
                unpinnedSeen += 1
                kept.append(clip)
            } else {
                removeImage(of: clip)
            }
        }
        if kept.count != clips.count { clips = kept }
    }

    private func removeImage(of clip: Clip) {
        guard let url = imageURL(for: clip) else { return }
        try? FileManager.default.removeItem(at: url)
        Thumbnails.forget(url)
    }

    // MARK: Lookups

    func imageURL(for clip: Clip) -> URL? {
        guard let name = clip.imageFile else { return nil }
        return imagesDirectory.appendingPathComponent(name)
    }

    /// Pinned first, then most recent, narrowed by filter and search words.
    func visible(filter: Filter, query: String) -> [Clip] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let matching = clips.filter { clip in
            guard filter.matches(clip) else { return false }
            if words.isEmpty { return true }
            let haystack = clip.searchText
            return words.allSatisfy { haystack.contains($0) }
        }
        return matching.filter(\.pinned) + matching.filter { !$0.pinned }
    }
}

/// Small in-memory cache of downscaled images for list rows and previews.
enum Thumbnails {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(for url: URL, maxPixel: Int) -> NSImage? {
        let key = "\(url.path)#\(maxPixel)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache.setObject(image, forKey: key)
        return image
    }

    static func forget(_ url: URL) {
        for size in [96, 400, 1200] { cache.removeObject(forKey: "\(url.path)#\(size)" as NSString) }
    }
}

func pixelSize(ofImageData data: Data) -> (Int, Int)? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let w = props[kCGImagePropertyPixelWidth] as? Int,
          let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
    return (w, h)
}
