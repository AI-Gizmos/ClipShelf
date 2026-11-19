import AppKit
import CryptoKit

enum ClipKind: String, Codable {
    case text, link, image, file, screenshot

    var label: String {
        switch self {
        case .text: return "Text"
        case .link: return "Link"
        case .image: return "Image"
        case .file: return "File"
        case .screenshot: return "Screenshot"
        }
    }

    var symbol: String {
        switch self {
        case .text: return "text.alignleft"
        case .link: return "link"
        case .image: return "photo"
        case .file: return "doc"
        case .screenshot: return "camera.viewfinder"
        }
    }
}

struct Clip: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: ClipKind
    var text: String?
    var filePaths: [String]?
    var imageFile: String?
    var pixelWidth: Int?
    var pixelHeight: Int?
    var sourceApp: String?
    var sourceBundleID: String?
    var createdAt = Date()
    var pinned = false
    var hash: String

    /// One-line title shown in the list.
    var title: String {
        switch kind {
        case .text, .link:
            let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let firstLine = trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            return String(firstLine.prefix(200))
        case .file:
            let names = (filePaths ?? []).map { ($0 as NSString).lastPathComponent }
            if names.count == 1 { return names[0] }
            return "\(names.count) items: " + names.prefix(3).joined(separator: ", ")
        case .image, .screenshot:
            if kind == .screenshot, let p = filePaths?.first {
                return (p as NSString).lastPathComponent
            }
            if let w = pixelWidth, let h = pixelHeight { return "Image \(w)×\(h)" }
            return "Image"
        }
    }

    /// Everything the search box matches against.
    var searchText: String {
        var parts: [String] = [kind.label]
        if let text { parts.append(text) }
        if let filePaths { parts.append(contentsOf: filePaths) }
        if let sourceApp { parts.append(sourceApp) }
        return parts.joined(separator: "\n").lowercased()
    }
}

enum Filter: String, CaseIterable, Identifiable {
    case all = "All", text = "Text", links = "Links", images = "Images"
    case files = "Files", screenshots = "Screenshots", pinned = "Pinned"

    var id: String { rawValue }

    func matches(_ clip: Clip) -> Bool {
        switch self {
        case .all: return true
        case .text: return clip.kind == .text
        case .links: return clip.kind == .link
        case .images: return clip.kind == .image
        case .files: return clip.kind == .file
        case .screenshots: return clip.kind == .screenshot
        case .pinned: return clip.pinned
        }
    }
}

func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func looksLikeLink(_ s: String) -> Bool {
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !t.isEmpty, t.count < 2048, !t.contains(where: \.isWhitespace) else { return false }
    guard let url = URL(string: t), let scheme = url.scheme?.lowercased() else { return false }
    return (scheme == "http" || scheme == "https") && url.host != nil
}
