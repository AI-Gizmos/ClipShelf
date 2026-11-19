import AppKit
import SwiftUI

/// The island: a small tab at the top-centre of the screen (hugging the notch when
/// the display has one) that expands on hover into a row of recent clips.
/// Click a card to paste it, or drag it into another app.

@MainActor
final class IslandState: ObservableObject {
    @Published var expanded = false
    @Published var hasNotch = false
    @Published var notchWidth: CGFloat = 0
    /// Height of the strip that sits in the menu bar area when expanded.
    @Published var topInset: CGFloat = 0

    var onPaste: (Clip) -> Void = { _ in }
    var onOpenLibrary: () -> Void = {}

    /// Which kinds of clip the cards show.
    @Published var filter: Filter = .all
    /// When on, the island stays expanded until switched off.
    @Published var keepOpen = false

    static let cardCount = 5
    static let expandedWidth: CGFloat = 770
    static let cardAreaHeight: CGFloat = 232
    static let filters: [Filter] = [.all, .screenshots, .text, .links, .images, .files]

    var collapsedSize: CGSize {
        hasNotch ? CGSize(width: notchWidth + 76, height: topInset) : CGSize(width: 132, height: 7)
    }

    var expandedSize: CGSize {
        CGSize(width: Self.expandedWidth, height: topInset + Self.cardAreaHeight)
    }
}

final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Lets clicks and drags start on the first mouse-down even though the island
/// never becomes the active window.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class IslandController {
    static let defaultsKey = "showIsland"

    private let store: ClipStore
    let state = IslandState()
    private var panel: IslandPanel!
    private var timer: Timer?
    private var insideTicks = 0
    private var outsideTicks = 0
    private var screenObserver: NSObjectProtocol?

    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.defaultsKey) as? Bool ?? true
    }

    init(store: ClipStore) {
        self.store = store
        buildPanel()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.layout() }
        }
        if isEnabled { show() }
    }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.defaultsKey)
        enabled ? show() : hide()
    }

    func collapse() {
        if !state.keepOpen { setExpanded(false) }
    }

    // MARK: Window

    private func buildPanel() {
        panel = IslandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        // Not a full-screen auxiliary window: the island stays out of full-screen apps.
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovable = false
        panel.ignoresMouseEvents = true
        panel.contentView = FirstMouseHostingView(
            rootView: IslandView().environmentObject(store).environmentObject(state))
    }

    /// The built-in notched display if there is one, otherwise the main display.
    private var screen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.screens.first
    }

    private func layout() {
        guard let screen else { return }
        let notchHeight = screen.safeAreaInsets.top
        state.hasNotch = notchHeight > 0
        if state.hasNotch {
            let left = screen.auxiliaryTopLeftArea?.width ?? 0
            let right = screen.auxiliaryTopRightArea?.width ?? 0
            state.notchWidth = max(screen.frame.width - left - right, 120)
            state.topInset = notchHeight
        } else {
            state.notchWidth = 0
            state.topInset = 8
        }
        // The window always has the expanded size; the view inside draws the small
        // or large shape, so the animation never has to resize the window.
        let size = state.expandedSize
        panel.setFrame(NSRect(x: screen.frame.midX - size.width / 2,
                              y: screen.frame.maxY - size.height,
                              width: size.width, height: size.height), display: true)
    }

    private func show() {
        layout()
        panel.orderFrontRegardless()
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func hide() {
        timer?.invalidate()
        timer = nil
        state.keepOpen = false
        setExpanded(false)
        panel.orderOut(nil)
    }

    // MARK: Hover

    private func rect(for size: CGSize) -> NSRect {
        guard let screen else { return .zero }
        return NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height,
                      width: size.width, height: size.height)
    }

    /// Hover is detected by watching the pointer position, which works while other
    /// apps are active and needs no permission.
    private func tick() {
        // Leave the island alone mid-click or mid-drag.
        guard NSEvent.pressedMouseButtons == 0 else { return }
        let mouse = NSEvent.mouseLocation
        if state.expanded {
            if state.keepOpen || rect(for: state.expandedSize).insetBy(dx: -14, dy: -14).contains(mouse) {
                outsideTicks = 0
            } else {
                outsideTicks += 1
                if outsideTicks >= 4 { setExpanded(false) }
            }
        } else {
            // A slightly taller target than the visible tab, and a short dwell so
            // passing over it on the way to the menu bar does not open it.
            var trigger = rect(for: state.collapsedSize)
            trigger.origin.y -= 3
            trigger.size.height += 6
            if trigger.contains(mouse) {
                insideTicks += 1
                if insideTicks >= 2 { setExpanded(true) }
            } else {
                insideTicks = 0
            }
        }
    }

    private func setExpanded(_ expanded: Bool) {
        insideTicks = 0
        outsideTicks = 0
        guard state.expanded != expanded else { return }
        state.expanded = expanded
        // Collapsed, the island is purely visual and never swallows a click.
        panel.ignoresMouseEvents = !expanded
    }

    /// Debug aid: draw the expanded island into a PNG.
    func snapshot(to path: String) {
        show()
        timer?.invalidate() // keep hover tracking from collapsing it again
        timer = nil
        setExpanded(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if let view = self.panel.contentView,
               let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: path))
            }
            NSApp.terminate(nil)
        }
    }
}

// MARK: Views

struct IslandView: View {
    @EnvironmentObject var store: ClipStore
    @EnvironmentObject var state: IslandState

    var body: some View {
        let size = state.expanded ? state.expandedSize : state.collapsedSize
        let radius: CGFloat = state.expanded ? 26 : (state.hasNotch ? 10 : 4)
        ZStack(alignment: .top) {
            UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius)
                .fill(Color.black)
            if state.expanded {
                expandedContent
                    .padding(.top, state.topInset)
                    .transition(.opacity)
            } else if state.hasNotch {
                collapsedContent
            }
        }
        .frame(width: size.width, height: size.height)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.3, dampingFraction: 0.84), value: state.expanded)
        .environment(\.colorScheme, .dark)
    }

    /// Shown either side of the notch: an icon on the left, the item count on the right.
    private var collapsedContent: some View {
        HStack {
            Image(systemName: "list.clipboard")
            Spacer()
            Text("\(store.clips.count)")
        }
        .font(.system(size: 11, weight: .semibold, design: .rounded))
        .foregroundStyle(Color.white.opacity(0.75))
        .padding(.horizontal, 11)
        .frame(maxHeight: .infinity)
    }

    private var expandedContent: some View {
        let clips = Array(store.visible(filter: state.filter, query: "").prefix(IslandState.cardCount))
        return VStack(spacing: 10) {
            toolbar
            filterRow
            cardRow(clips)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 16)
    }

    // Row 1: round buttons.
    private var toolbar: some View {
        HStack(spacing: 8) {
            roundButton("square.grid.2x2", help: "Open the full history (⌃⌘V)") { state.onOpenLibrary() }
            roundButton("magnifyingglass", help: "Search the full history") { state.onOpenLibrary() }
            Spacer()
            roundButton(state.keepOpen ? "pin.fill" : "pin",
                        active: state.keepOpen,
                        help: state.keepOpen ? "Let the island close again" : "Keep the island open") {
                state.keepOpen.toggle()
            }
        }
    }

    private func roundButton(_ symbol: String, active: Bool = false, help: String,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(active ? Color.black : Color.white.opacity(0.9))
                .frame(width: 28, height: 28)
                .background(Circle().fill(active ? Color.white : Color.white.opacity(0.1)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // Row 2: a summary on the left, type filters on the right.
    private var filterRow: some View {
        HStack(spacing: 6) {
            Text(summary)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.5))
            Spacer()
            ForEach(IslandState.filters) { filter in
                let selected = state.filter == filter
                Button {
                    state.filter = filter
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: Self.symbol(for: filter)).font(.system(size: 9, weight: .semibold))
                        Text(filter.rawValue).font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(selected ? Color.black : Color.white.opacity(0.85))
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(Capsule().fill(selected ? Color.white : Color.white.opacity(0.08)))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(selected ? 0 : 0.14), lineWidth: 1))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var summary: String {
        let pinned = store.clips.filter(\.pinned).count
        let total = "\(store.clips.count) clip\(store.clips.count == 1 ? "" : "s")"
        return pinned > 0 ? "\(total) · \(pinned) pinned" : total
    }

    private static func symbol(for filter: Filter) -> String {
        switch filter {
        case .all: return "square.grid.2x2.fill"
        case .screenshots: return "camera"
        case .text: return "textformat"
        case .links: return "link"
        case .images: return "photo"
        case .files: return "folder"
        case .pinned: return "pin"
        }
    }

    // Row 3: the cards.
    private func cardRow(_ clips: [Clip]) -> some View {
        HStack(spacing: 10) {
            if clips.isEmpty {
                Text(store.clips.isEmpty ? "Copy something and it will appear here"
                                         : "No \(state.filter.rawValue.lowercased()) in your history yet")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.55))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ForEach(clips) { clip in
                    IslandCard(clip: clip, imageURL: store.imageURL(for: clip))
                        .onTapGesture { state.onPaste(clip) }
                        .onDrag { dragProvider(for: clip) }
                        .help("\(clip.title)\nClick to paste, or drag into another app")
                }
                // Keep cards the same width when there are fewer than a full row.
                ForEach(0..<(IslandState.cardCount - clips.count), id: \.self) { _ in
                    Color.clear.frame(maxWidth: .infinity)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func dragProvider(for clip: Clip) -> NSItemProvider {
        switch clip.kind {
        case .text:
            return NSItemProvider(object: (clip.text ?? "") as NSString)
        case .link:
            let text = (clip.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = URL(string: text) { return NSItemProvider(object: url as NSURL) }
            return NSItemProvider(object: text as NSString)
        case .file:
            // Dragging carries the first item of a multi-file clip.
            if let path = clip.filePaths?.first(where: { FileManager.default.fileExists(atPath: $0) }) {
                return NSItemProvider(object: URL(fileURLWithPath: path) as NSURL)
            }
            return NSItemProvider()
        case .image, .screenshot:
            guard let url = store.imageURL(for: clip),
                  let provider = NSItemProvider(contentsOf: url) else { return NSItemProvider() }
            provider.suggestedName = clip.kind == .screenshot
                ? ((clip.title as NSString).deletingPathExtension)
                : "Clipshelf image"
            return provider
        }
    }
}

struct IslandCard: View {
    let clip: Clip
    let imageURL: URL?

    private var isFolder: Bool {
        guard clip.kind == .file, let path = clip.filePaths?.first else { return false }
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &dir) && dir.boolValue
    }

    /// Badge text, badge colour and card tint for each kind of clip.
    private var style: (label: String, symbol: String, color: Color) {
        switch clip.kind {
        case .image: return ("Image", "photo", Color(red: 0.86, green: 0.36, blue: 0.52))
        case .screenshot: return ("Screenshot", "camera", Color(red: 0.24, green: 0.68, blue: 0.62))
        case .text: return ("Text", "textformat", Color(white: 0.5))
        case .link: return ("Link", "link", Color(red: 0.33, green: 0.48, blue: 0.95))
        case .file:
            return isFolder ? ("Folder", "folder", Color(red: 0.90, green: 0.64, blue: 0.22))
                            : ("File", "doc", Color(red: 0.90, green: 0.64, blue: 0.22))
        }
    }

    var body: some View {
        let style = self.style
        let shape = RoundedRectangle(cornerRadius: 14)
        ZStack {
            background(style.color)
            content(style)
            // Footer: source app on the left, type badge on the right.
            VStack {
                Spacer()
                HStack(alignment: .bottom) {
                    if let icon = appIcon(bundleID: clip.sourceBundleID) {
                        Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                    }
                    Spacer()
                    HStack(spacing: 3) {
                        Image(systemName: style.symbol).font(.system(size: 8, weight: .bold))
                        Text(style.label).font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 6)
                    .frame(height: 16)
                    .background(RoundedRectangle(cornerRadius: 5).fill(style.color))
                }
                .padding(8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
        .overlay(alignment: .topTrailing) {
            if clip.pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                    .padding(8)
            }
        }
        .contentShape(shape)
    }

    @ViewBuilder private func background(_ tint: Color) -> some View {
        if let imageURL, let thumb = Thumbnails.image(for: imageURL, maxPixel: 400) {
            GeometryReader { geo in
                Image(nsImage: thumb)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
            }
            // Darken the bottom edge so the footer stays readable on bright pictures.
            LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
        } else {
            Color(white: 0.11)
            LinearGradient(colors: [tint.opacity(clip.kind == .text ? 0.0 : 0.22), .clear],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    @ViewBuilder private func content(_ style: (label: String, symbol: String, color: Color)) -> some View {
        if clip.kind == .image || clip.kind == .screenshot {
            if imageURL == nil || Thumbnails.image(for: imageURL!, maxPixel: 400) == nil {
                Image(systemName: "photo").font(.system(size: 22)).foregroundStyle(Color.white.opacity(0.5))
            }
        } else {
            VStack(alignment: .leading, spacing: 5) {
                Image(systemName: style.symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(clip.kind == .text ? Color.white.opacity(0.75) : style.color)
                    .frame(height: 18)
                Text(headline)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .lineLimit(2)
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.white.opacity(0.55))
                    .lineLimit(2)
            }
            .padding(.horizontal, 11)
            .padding(.top, 11)
            .padding(.bottom, 30)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var lines: [String] {
        (clip.text ?? "").split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private var headline: String {
        switch clip.kind {
        case .link:
            let text = (clip.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return URL(string: text)?.host ?? text
        case .text:
            return String((lines.first ?? "").prefix(120))
        default:
            return clip.title
        }
    }

    private var detail: String {
        switch clip.kind {
        case .link:
            let text = (clip.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let path = URL(string: text)?.path ?? ""
            return path.isEmpty || path == "/" ? relativeTime(clip.createdAt) : path
        case .text:
            if lines.count > 1 { return String(lines[1].prefix(120)) }
            return relativeTime(clip.createdAt)
        case .file:
            guard let path = clip.filePaths?.first else { return "" }
            return ((path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath
        default:
            return ""
        }
    }
}
