import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// A system-wide keyboard shortcut. Needs no special permission.
final class HotKey {
    private static var action: (() -> Void)?
    private var ref: EventHotKeyRef?

    init?(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        HotKey.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKey.action?() }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x434C_5346), id: 1) // "CLSF"
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id,
                                         GetApplicationEventTarget(), 0, &ref)
        if status != noErr { return nil }
    }
}

enum Paster {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the macOS dialog that sends the user to the Accessibility settings.
    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Sends Command-V to whichever app is frontmost.
    static func sendPaste() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let v = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

extension ClipStore {
    /// Puts a clip back on the system pasteboard. Returns false if nothing could be written.
    func writeToPasteboard(_ clip: Clip) -> Bool {
        let pb = NSPasteboard.general
        switch clip.kind {
        case .text, .link:
            guard let text = clip.text else { return false }
            pb.clearContents()
            return pb.setString(text, forType: .string)
        case .file:
            let urls = (clip.filePaths ?? [])
                .filter { FileManager.default.fileExists(atPath: $0) }
                .map { URL(fileURLWithPath: $0) as NSURL }
            guard !urls.isEmpty else { return false }
            pb.clearContents()
            return pb.writeObjects(urls)
        case .image, .screenshot:
            guard let url = imageURL(for: clip), let image = NSImage(contentsOf: url) else { return false }
            pb.clearContents()
            return pb.writeObjects([image])
        }
    }
}

func appIcon(bundleID: String?) -> NSImage? {
    guard let bundleID,
          let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
    return NSWorkspace.shared.icon(forFile: url.path)
}
