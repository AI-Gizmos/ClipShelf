import SwiftUI

@MainActor
final class PanelState: ObservableObject {
    @Published var query = "" { didSet { selection = 0 } }
    @Published var filter: Filter = .all { didSet { selection = 0 } }
    @Published var selection = 0
    @Published var trusted = Paster.isTrusted
    @Published var focusToken = 0

    var onPaste: (Clip) -> Void = { _ in }
    var onRequestTrust: () -> Void = {}
}

struct PanelView: View {
    @EnvironmentObject var store: ClipStore
    @EnvironmentObject var state: PanelState
    @FocusState private var searchFocused: Bool

    private var clips: [Clip] { store.visible(filter: state.filter, query: state.query) }

    var body: some View {
        let clips = self.clips
        let selected = clips.indices.contains(state.selection) ? clips[state.selection] : nil
        VStack(spacing: 0) {
            searchBar
            filterBar
            Divider()
            if clips.isEmpty {
                emptyState
            } else {
                HStack(spacing: 0) {
                    list(clips)
                        .frame(width: 310)
                    Divider()
                    PreviewPane(clip: selected)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            footer
        }
        .ignoresSafeArea()
        .onAppear { searchFocused = true }
        .onChange(of: state.focusToken) { _, _ in searchFocused = true }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
            TextField("Search clipboard history", text: $state.query)
                .textFieldStyle(.plain)
                .font(.system(size: 18))
                .focused($searchFocused)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var filterBar: some View {
        HStack(spacing: 6) {
            ForEach(Filter.allCases) { filter in
                Button {
                    state.filter = filter
                } label: {
                    Text(filter.rawValue)
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(state.filter == filter
                                           ? Color.accentColor.opacity(0.9)
                                           : Color.primary.opacity(0.07)))
                        .foregroundStyle(state.filter == filter ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    private func list(_ clips: [Clip]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(clips.enumerated()), id: \.element.id) { index, clip in
                        ClipRow(clip: clip, index: index, selected: index == state.selection)
                            .id(clip.id)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { state.onPaste(clip) }
                            .simultaneousGesture(TapGesture().onEnded { state.selection = index })
                    }
                }
                .padding(6)
            }
            .onChange(of: state.selection) { _, new in
                if clips.indices.contains(new) { proxy.scrollTo(clips[new].id) }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: store.clips.isEmpty ? "clipboard" : "magnifyingglass")
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
            Text(store.clips.isEmpty ? "Nothing copied yet" : "No matches")
                .font(.headline)
            Text(store.clips.isEmpty
                 ? "Copy something with ⌘C and it will show up here."
                 : "Try a different word or filter.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            if state.trusted {
                hint("↩", "Paste")
            } else {
                Button {
                    state.onRequestTrust()
                } label: {
                    Label("Allow Accessibility to paste automatically", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
                .help("Until then, Return copies the item and you press ⌘V yourself.")
                hint("↩", "Copy")
            }
            hint("⌘1–9", "Quick paste")
            hint("⌘P", "Pin")
            hint("⌘⌫", "Delete")
            hint("⇥", "Filter")
            Spacer()
            Text("\(store.clips.count) items")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)))
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

struct ClipRow: View {
    @EnvironmentObject var store: ClipStore
    let clip: Clip
    let index: Int
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            leading
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(clip.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 4) {
                    Text(clip.kind.label)
                    if let app = clip.sourceApp { Text("· \(app)") }
                    Text("· \(relativeTime(clip.createdAt))")
                }
                .font(.system(size: 11))
                .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 4)
            if clip.pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(selected ? Color.white : Color.orange)
            }
            if index < 9 {
                Text("⌘\(index + 1)")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(selected ? Color.white.opacity(0.7) : Color.secondary.opacity(0.6))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .foregroundStyle(selected ? Color.white : Color.primary)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor : Color.clear))
    }

    @ViewBuilder private var leading: some View {
        if let url = store.imageURL(for: clip), let thumb = Thumbnails.image(for: url, maxPixel: 96) {
            Image(nsImage: thumb)
                .resizable()
                .scaledToFill()
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else if clip.kind == .file, let path = clip.filePaths?.first {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().scaledToFit()
        } else if let icon = appIcon(bundleID: clip.sourceBundleID) {
            Image(nsImage: icon).resizable().scaledToFit()
        } else {
            Image(systemName: clip.kind.symbol)
                .font(.system(size: 16))
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)))
        }
    }
}

struct PreviewPane: View {
    @EnvironmentObject var store: ClipStore
    let clip: Clip?

    var body: some View {
        if let clip {
            VStack(alignment: .leading, spacing: 0) {
                content(clip)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                Divider()
                metadata(clip)
            }
        } else {
            Color.clear
        }
    }

    @ViewBuilder private func content(_ clip: Clip) -> some View {
        switch clip.kind {
        case .text, .link:
            ScrollView {
                Text(String((clip.text ?? "").prefix(20_000)))
                    .font(.system(size: 13, design: clip.kind == .link ? .default : .monospaced))
                    .foregroundStyle(clip.kind == .link ? Color.accentColor : Color.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
        case .image, .screenshot:
            if let url = store.imageURL(for: clip), let image = Thumbnails.image(for: url, maxPixel: 1200) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                missing("The saved image is missing.")
            }
        case .file:
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(clip.filePaths ?? [], id: \.self) { path in
                        let exists = FileManager.default.fileExists(atPath: path)
                        HStack(spacing: 8) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                                .resizable().frame(width: 28, height: 28)
                            VStack(alignment: .leading, spacing: 1) {
                                Text((path as NSString).lastPathComponent).font(.system(size: 13))
                                Text(exists ? (path as NSString).abbreviatingWithTildeInPath : "No longer at this location")
                                    .font(.system(size: 11))
                                    .foregroundStyle(exists ? Color.secondary : Color.orange)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
        }
    }

    private func missing(_ message: String) -> some View {
        Text(message).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func metadata(_ clip: Clip) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            row("Type", clip.kind.label)
            if let app = clip.sourceApp { row("From", app) }
            row("Copied", clip.createdAt.formatted(date: .abbreviated, time: .shortened))
            if let w = clip.pixelWidth, let h = clip.pixelHeight { row("Size", "\(w) × \(h)") }
            if let text = clip.text { row("Length", "\(text.count) characters") }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label).foregroundStyle(.secondary).frame(width: 50, alignment: .leading)
            Text(value).lineLimit(1)
        }
        .font(.system(size: 11))
    }
}

private let relativeFormatter: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .abbreviated
    return f
}()

func relativeTime(_ date: Date) -> String {
    if Date().timeIntervalSince(date) < 5 { return "now" }
    return relativeFormatter.localizedString(for: date, relativeTo: Date())
}
