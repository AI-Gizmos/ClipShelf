import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

/// A panel that takes keyboard input without pulling focus away from the app
/// you were working in, so paste lands back where you were.
final class ShelfPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private let store = ClipStore()
    private let state = PanelState()
    private lazy var monitor = ClipboardMonitor(store: store)
    private var screenshots: ScreenshotWatcher?
    private var hotKey: HotKey?
    private var panel: ShelfPanel!
    private var statusItem: NSStatusItem!
    private var keyMonitor: Any?
    private var pauseItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private var askedForTrust = false
    private var island: IslandController!
    private var islandItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildPanel()
        buildStatusItem()

        island = IslandController(store: store)
        island.state.onPaste = { [weak self] clip in self?.paste(clip) }
        island.state.onOpenLibrary = { [weak self] in
            self?.island.collapse()
            self?.showPanel()
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--snapshot-island"),
           CommandLine.arguments.indices.contains(flag + 1) {
            island.snapshot(to: CommandLine.arguments[flag + 1])
            return
        }

        state.onPaste = { [weak self] clip in self?.paste(clip) }
        state.onRequestTrust = { Paster.requestTrust() }

        monitor.start()

        screenshots = ScreenshotWatcher { [weak self] url in
            guard let data = try? Data(contentsOf: url), data.count <= 40_000_000 else { return }
            let size = pixelSize(ofImageData: data)
            let hash = sha256Hex(data)
            Task { @MainActor in
                guard let self, !self.monitor.paused else { return }
                var clip = Clip(kind: .screenshot, filePaths: [url.path],
                                sourceApp: "Screenshot", sourceBundleID: "com.apple.screenshot.launcher",
                                hash: hash)
                clip.pixelWidth = size?.0
                clip.pixelHeight = size?.1
                self.store.add(clip, imageData: data, imageExtension: url.pathExtension.lowercased())
            }
        }
        screenshots?.start()

        // Debug aid: `Clipshelf --snapshot out.png` shows the panel, saves a picture
        // of it and quits. Used to check the layout without screen recording access.
        if let flag = CommandLine.arguments.firstIndex(of: "--snapshot"),
           CommandLine.arguments.indices.contains(flag + 1) {
            let path = CommandLine.arguments[flag + 1]
            showPanel()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if let view = self.panel.contentView,
                   let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: path))
                }
                NSApp.terminate(nil)
            }
            return
        }

        // Control-Command-V
        hotKey = HotKey(keyCode: kVK_ANSI_V, modifiers: controlKey | cmdKey) { [weak self] in
            Task { @MainActor in self?.togglePanel() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.saveNow()
    }

    /// Opening the app again (Spotlight, Finder, `open`) shows the panel.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return false
    }

    // MARK: Panel

    private func buildPanel() {
        panel = ShelfPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 480),
                           styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
                           backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.animationBehavior = .utilityWindow
        panel.delegate = self
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        let host = NSHostingView(rootView: PanelView().environmentObject(store).environmentObject(state))
        host.frame = effect.bounds
        host.autoresizingMask = [.width, .height]
        effect.addSubview(host)
        panel.contentView = effect
    }

    private func togglePanel() {
        panel.isVisible ? hidePanel() : showPanel()
    }

    private func showPanel() {
        state.query = ""
        state.filter = .all
        state.selection = 0
        state.trusted = Paster.isTrusted
        state.focusToken += 1

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2,
                                         y: visible.midY - size.height / 2 + visible.height * 0.08))
        }
        panel.makeKeyAndOrderFront(nil)

        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.panel.isKeyWindow else { return event }
                return self.handleKey(event) ? nil : event
            }
        }
    }

    private func hidePanel() {
        panel.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        hidePanel()
    }

    /// Returns true when the key was handled and should not reach the search field.
    private func handleKey(_ event: NSEvent) -> Bool {
        let clips = store.visible(filter: state.filter, query: state.query)
        let command = event.modifierFlags.contains(.command)
        let selected = clips.indices.contains(state.selection) ? clips[state.selection] : nil

        switch Int(event.keyCode) {
        case kVK_Escape:
            hidePanel()
            return true
        case kVK_DownArrow:
            if !clips.isEmpty { state.selection = min(state.selection + 1, clips.count - 1) }
            return true
        case kVK_UpArrow:
            state.selection = max(state.selection - 1, 0)
            return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if let selected { paste(selected) }
            return true
        case kVK_Tab:
            let all = Filter.allCases
            let index = all.firstIndex(of: state.filter) ?? 0
            let step = event.modifierFlags.contains(.shift) ? all.count - 1 : 1
            state.filter = all[(index + step) % all.count]
            return true
        case kVK_ANSI_P where command:
            if let selected { store.togglePin(selected) }
            return true
        case kVK_Delete where command:
            if let selected {
                store.delete(selected)
                state.selection = min(state.selection, max(clips.count - 2, 0))
            }
            return true
        default:
            if command, let chars = event.charactersIgnoringModifiers,
               let digit = Int(chars), (1...9).contains(digit) {
                if clips.indices.contains(digit - 1) { paste(clips[digit - 1]) }
                return true
            }
            return false
        }
    }

    private func paste(_ clip: Clip) {
        guard store.writeToPasteboard(clip) else {
            NSSound.beep()
            return
        }
        monitor.ignoreCurrentContents()
        store.touch(clip)
        hidePanel()
        island.collapse()

        if Paster.isTrusted {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { Paster.sendPaste() }
        } else if !askedForTrust {
            // The item is on the clipboard either way; ask once per launch for the
            // permission that lets us press ⌘V for the user.
            askedForTrust = true
            Paster.requestTrust()
        }
    }

    // MARK: Menu bar

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "list.clipboard",
                                           accessibilityDescription: "Clipshelf")

        let menu = NSMenu()
        menu.delegate = self
        let open = NSMenuItem(title: "Open Clipshelf", action: #selector(openFromMenu), keyEquivalent: "v")
        open.keyEquivalentModifierMask = [.control, .command]
        menu.addItem(open)
        menu.addItem(.separator())
        pauseItem = NSMenuItem(title: "Pause Capturing", action: #selector(togglePause), keyEquivalent: "")
        menu.addItem(pauseItem)
        islandItem = NSMenuItem(title: "Show Island", action: #selector(toggleIsland), keyEquivalent: "")
        menu.addItem(islandItem)
        loginItem = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Clear History…", action: #selector(clearHistory), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Show History Folder", action: #selector(showFolder), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Clipshelf", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) {
            item.target = self
        }
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        pauseItem.state = monitor.paused ? .on : .off
        islandItem.state = island.isEnabled ? .on : .off
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func openFromMenu() {
        // Let the menu finish closing before the panel takes the keyboard.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.showPanel() }
    }

    @objc private func togglePause() {
        monitor.paused.toggle()
        statusItem.button?.image = NSImage(
            systemSymbolName: monitor.paused ? "clipboard" : "list.clipboard",
            accessibilityDescription: monitor.paused ? "Clipshelf (paused)" : "Clipshelf")
        statusItem.button?.appearsDisabled = monitor.paused
    }

    @objc private func toggleIsland() {
        island.setEnabled(!island.isEnabled)
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not change the login setting"
            alert.informativeText = error.localizedDescription
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    @objc private func clearHistory() {
        let alert = NSAlert()
        alert.messageText = "Clear clipboard history?"
        alert.informativeText = "Everything except pinned items will be removed. This cannot be undone."
        alert.addButton(withTitle: "Clear History")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { store.clearUnpinned() }
    }

    @objc private func showFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([store.directory])
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
