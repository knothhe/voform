import AppKit
import Carbon

enum TextInjectorError: LocalizedError {
    case accessibilityPermissionMissing
    case pasteEventCreationFailed

    var errorDescription: String? {
        switch self {
        case .accessibilityPermissionMissing: return "Accessibility permission is required to paste text."
        case .pasteEventCreationFailed: return "Could not create the paste keyboard event."
        }
    }
}

@MainActor
final class TextInjector {
    private struct PasteboardSnapshot {
        let items: [[NSPasteboard.PasteboardType: Data]]

        init(pasteboard: NSPasteboard) {
            items = (pasteboard.pasteboardItems ?? []).map { item in
                var values: [NSPasteboard.PasteboardType: Data] = [:]
                for type in item.types {
                    if let data = item.data(forType: type) { values[type] = data }
                }
                return values
            }
        }

        func restore(to pasteboard: NSPasteboard) {
            pasteboard.clearContents()
            let restored = items.map { values -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            }
            if !restored.isEmpty { pasteboard.writeObjects(restored) }
        }
    }

    func inject(_ text: String) async throws {
        guard AXIsProcessTrusted() else { throw TextInjectorError.accessibilityPermissionMissing }

        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)
        let originalInputSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
        var didSwitchInputSource = false

        if let originalInputSource, isCJKInputSource(originalInputSource), let asciiSource = preferredASCIIInputSource() {
            didSwitchInputSource = TISSelectInputSource(asciiSource) == noErr
            if didSwitchInputSource { try? await Task.sleep(for: .milliseconds(90)) }
        }

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            if didSwitchInputSource, let originalInputSource { TISSelectInputSource(originalInputSource) }
            snapshot.restore(to: pasteboard)
            throw TextInjectorError.pasteEventCreationFailed
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        // Give the target application time to consume the pasteboard before restoring it.
        try? await Task.sleep(for: .milliseconds(250))
        if didSwitchInputSource, let originalInputSource { TISSelectInputSource(originalInputSource) }
        try? await Task.sleep(for: .milliseconds(80))
        snapshot.restore(to: pasteboard)
    }

    private func isCJKInputSource(_ source: TISInputSource) -> Bool {
        let identifier = stringProperty(source, key: kTISPropertyInputSourceID)?.lowercased() ?? ""
        let languages = arrayProperty(source, key: kTISPropertyInputSourceLanguages)?.map { $0.lowercased() } ?? []
        let hasCJKLanguage = languages.contains { $0.hasPrefix("zh") || $0.hasPrefix("ja") || $0.hasPrefix("ko") }
        let hasCJKIdentifier = ["pinyin", "shuangpin", "cangjie", "zhuyin", "wubi", "japanese", "korean", "inputmethod.sogou", "inputmethod.wechat"].contains { identifier.contains($0) }
        return hasCJKLanguage || hasCJKIdentifier
    }

    private func preferredASCIIInputSource() -> TISInputSource? {
        let properties = [kTISPropertyInputSourceIsEnabled: true] as CFDictionary
        guard let unmanaged = TISCreateInputSourceList(properties, false),
              let sources = unmanaged.takeRetainedValue() as? [TISInputSource] else { return nil }
        let asciiSources = sources.filter { boolProperty($0, key: kTISPropertyInputSourceIsASCIICapable) }
        return asciiSources.first(where: {
            let id = stringProperty($0, key: kTISPropertyInputSourceID) ?? ""
            return id == "com.apple.keylayout.ABC" || id == "com.apple.keylayout.US"
        }) ?? asciiSources.first
    }

    private func stringProperty(_ source: TISInputSource, key: CFString) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    private func arrayProperty(_ source: TISInputSource, key: CFString) -> [String]? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFArray>.fromOpaque(pointer).takeUnretainedValue() as? [String]
    }

    private func boolProperty(_ source: TISInputSource, key: CFString) -> Bool {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return false }
        return Unmanaged<CFBoolean>.fromOpaque(pointer).takeUnretainedValue() == kCFBooleanTrue
    }
}
