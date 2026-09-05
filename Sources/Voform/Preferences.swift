import AppKit

struct ShortcutModifiers: OptionSet, Equatable {
    let rawValue: Int

    static let control = ShortcutModifiers(rawValue: 1 << 0)
    static let option = ShortcutModifiers(rawValue: 1 << 1)
    static let shift = ShortcutModifiers(rawValue: 1 << 2)
    static let command = ShortcutModifiers(rawValue: 1 << 3)
    static let function = ShortcutModifiers(rawValue: 1 << 4)

    init(rawValue: Int) {
        self.rawValue = rawValue
    }

    init(eventFlags: NSEvent.ModifierFlags) {
        var result: ShortcutModifiers = []
        if eventFlags.contains(.control) { result.insert(.control) }
        if eventFlags.contains(.option) { result.insert(.option) }
        if eventFlags.contains(.shift) { result.insert(.shift) }
        if eventFlags.contains(.command) { result.insert(.command) }
        if eventFlags.contains(.function) { result.insert(.function) }
        self = result
    }

    init(eventFlags: CGEventFlags) {
        var result: ShortcutModifiers = []
        if eventFlags.contains(.maskControl) { result.insert(.control) }
        if eventFlags.contains(.maskAlternate) { result.insert(.option) }
        if eventFlags.contains(.maskShift) { result.insert(.shift) }
        if eventFlags.contains(.maskCommand) { result.insert(.command) }
        if eventFlags.contains(.maskSecondaryFn) { result.insert(.function) }
        self = result
    }

    var symbols: String {
        var result = ""
        if contains(.control) { result += "⌃" }
        if contains(.option) { result += "⌥" }
        if contains(.shift) { result += "⇧" }
        if contains(.command) { result += "⌘" }
        if contains(.function) { result += "Fn " }
        return result
    }
}

struct HoldShortcut: Equatable {
    var keyCode: UInt16
    var modifiers: ShortcutModifiers
    var keyTitle: String
    var isModifierOnly: Bool

    static let function = HoldShortcut(keyCode: 63, modifiers: .function, keyTitle: "Fn / Globe", isModifierOnly: true)
    static let optionSpace = HoldShortcut(keyCode: 49, modifiers: .option, keyTitle: "Space")
    static let defaultShortcut = optionSpace

    var displayTitle: String {
        if isModifierOnly { return keyTitle }
        return "\(modifiers.symbols)\(keyTitle)"
    }

    init(keyCode: UInt16, modifiers: ShortcutModifiers, keyTitle: String, isModifierOnly: Bool = false) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyTitle = keyTitle
        self.isModifierOnly = isModifierOnly
    }

    init(event: NSEvent) {
        keyCode = event.keyCode
        modifiers = ShortcutModifiers(eventFlags: event.modifierFlags)
        keyTitle = Self.keyTitle(for: event)
        isModifierOnly = false
    }

    private static func keyTitle(for event: NSEvent) -> String {
        let specialKeys: [UInt16: String] = [
            36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Escape",
            71: "Clear", 76: "Enter", 114: "Help", 115: "Home", 116: "Page Up",
            117: "Forward Delete", 119: "End", 121: "Page Down",
            123: "←", 124: "→", 125: "↓", 126: "↑",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5",
            97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
            103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
            106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20"
        ]
        if let title = specialKeys[event.keyCode] { return title }
        let characters = event.charactersIgnoringModifiers?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return characters.isEmpty ? "Key \(event.keyCode)" : characters.uppercased()
    }
}

enum RecordingMode: String, CaseIterable {
    case toggle
    case hold

    var title: String {
        self == .toggle ? "Press to toggle" : "Hold to talk"
    }
}

enum RecognitionLanguage: String, CaseIterable {
    case english = "en-US"
    case simplifiedChinese = "zh-CN"
    case traditionalChinese = "zh-TW"
    case japanese = "ja-JP"
    case korean = "ko-KR"

    var title: String {
        switch self {
        case .english: return "English"
        case .simplifiedChinese: return "简体中文"
        case .traditionalChinese: return "繁體中文"
        case .japanese: return "日本語"
        case .korean: return "한국어"
        }
    }
}

struct LLMConfiguration {
    var baseURL: String
    var apiKey: String
    var model: String

    var isConfigured: Bool {
        !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

final class Preferences {
    static let shared = Preferences()

    private enum Key {
        static let language = "recognitionLanguage"
        static let recordingMode = "recordingMode"
        static let shortcutKeyCode = "holdShortcutKeyCode"
        static let shortcutModifiers = "holdShortcutModifiers"
        static let shortcutKeyTitle = "holdShortcutKeyTitle"
        static let shortcutIsModifierOnly = "holdShortcutIsModifierOnly"
        static let shortcutDefaultVersion = "holdShortcutDefaultVersion"
        static let llmEnabled = "llmRefinementEnabled"
        static let apiBaseURL = "llmAPIBaseURL"
        static let apiKey = "llmAPIKey"
        static let model = "llmModel"
    }

    private let defaults = UserDefaults.standard

    private init() {
        defaults.register(defaults: [
            Key.language: RecognitionLanguage.simplifiedChinese.rawValue,
            Key.recordingMode: RecordingMode.toggle.rawValue,
            Key.shortcutKeyCode: Int(HoldShortcut.defaultShortcut.keyCode),
            Key.shortcutModifiers: HoldShortcut.defaultShortcut.modifiers.rawValue,
            Key.shortcutKeyTitle: HoldShortcut.defaultShortcut.keyTitle,
            Key.shortcutIsModifierOnly: HoldShortcut.defaultShortcut.isModifierOnly,
            Key.llmEnabled: false,
            Key.apiBaseURL: "https://api.openai.com/v1",
            Key.apiKey: "",
            Key.model: "gpt-4.1-mini"
        ])

        // Move the old Fn default to Option-Space, preserving other custom bindings.
        if defaults.integer(forKey: Key.shortcutDefaultVersion) < 3 {
            if holdShortcut == .function { holdShortcut = .defaultShortcut }
            defaults.set(3, forKey: Key.shortcutDefaultVersion)
        }
    }

    var recordingMode: RecordingMode {
        get { RecordingMode(rawValue: defaults.string(forKey: Key.recordingMode) ?? "") ?? .toggle }
        set { defaults.set(newValue.rawValue, forKey: Key.recordingMode) }
    }

    var language: RecognitionLanguage {
        get { RecognitionLanguage(rawValue: defaults.string(forKey: Key.language) ?? "") ?? .simplifiedChinese }
        set { defaults.set(newValue.rawValue, forKey: Key.language) }
    }

    var holdShortcut: HoldShortcut {
        get {
            HoldShortcut(
                keyCode: UInt16(clamping: defaults.integer(forKey: Key.shortcutKeyCode)),
                modifiers: ShortcutModifiers(rawValue: defaults.integer(forKey: Key.shortcutModifiers)),
                keyTitle: defaults.string(forKey: Key.shortcutKeyTitle) ?? HoldShortcut.defaultShortcut.keyTitle,
                isModifierOnly: defaults.bool(forKey: Key.shortcutIsModifierOnly)
            )
        }
        set {
            defaults.set(Int(newValue.keyCode), forKey: Key.shortcutKeyCode)
            defaults.set(newValue.modifiers.rawValue, forKey: Key.shortcutModifiers)
            defaults.set(newValue.keyTitle, forKey: Key.shortcutKeyTitle)
            defaults.set(newValue.isModifierOnly, forKey: Key.shortcutIsModifierOnly)
        }
    }

    var llmEnabled: Bool {
        get { defaults.bool(forKey: Key.llmEnabled) }
        set { defaults.set(newValue, forKey: Key.llmEnabled) }
    }

    var llmConfiguration: LLMConfiguration {
        get {
            LLMConfiguration(
                baseURL: defaults.string(forKey: Key.apiBaseURL) ?? "",
                apiKey: defaults.string(forKey: Key.apiKey) ?? "",
                model: defaults.string(forKey: Key.model) ?? ""
            )
        }
        set {
            defaults.set(newValue.baseURL, forKey: Key.apiBaseURL)
            // Deliberately store an empty string so the API key can be fully cleared.
            defaults.set(newValue.apiKey, forKey: Key.apiKey)
            defaults.set(newValue.model, forKey: Key.model)
        }
    }
}
