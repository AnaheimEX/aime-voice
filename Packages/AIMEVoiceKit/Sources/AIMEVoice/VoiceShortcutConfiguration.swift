public import Foundation

/// Non-secret settings cached by the IME; provider credentials are loaded only when a voice task starts.
public struct VoiceShortcutConfiguration: Codable, Sendable, Equatable {
    public var enabled = false
    public var toggleShortcut = "Control+Alt+v"
    public var cancelShortcut = "Escape"
    public var rewriteShortcut = "Control+Alt+r"

    public init() {}

    public static func load() -> Self {
        guard let data = try? Data(contentsOf: VoiceSettings.settingsURL),
              let result = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return result
    }

    private enum CodingKeys: String, CodingKey { case enabled, toggleShortcut, cancelShortcut, rewriteShortcut }

    public init(from decoder: any Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
        toggleShortcut = try container.decodeIfPresent(String.self, forKey: .toggleShortcut) ?? toggleShortcut
        cancelShortcut = try container.decodeIfPresent(String.self, forKey: .cancelShortcut) ?? cancelShortcut
        rewriteShortcut = try container.decodeIfPresent(String.self, forKey: .rewriteShortcut) ?? rewriteShortcut
    }

    public static func validate(toggle: String, cancel: String, rewrite: String = "Control+Alt+r") throws {
        guard isSupported(rewrite), rewrite != toggle, rewrite != cancel,
              rewrite != "Control+Alt+p", rewrite != "Return", rewrite != "Escape" else {
            throw InvalidShortcut(message: "改写快捷键不能与录音、取消、回车或 AI 助手冲突")
        }
        guard !toggle.isEmpty, !cancel.isEmpty else { throw InvalidShortcut(message: "请设置开始/结束和取消快捷键") }
        guard toggle != cancel else { throw InvalidShortcut(message: "开始/结束与取消不能使用同一个快捷键") }
        guard isSupported(toggle), isSupported(cancel) else {
            throw InvalidShortcut(message: "请选择单键、功能键、左右修饰键或组合键")
        }
        guard toggle != "Control+Alt+p", cancel != "Control+Alt+p" else {
            throw InvalidShortcut(message: "⌃⌥P 已用于 AIME 的 AI 助手，请选择其他快捷键")
        }
    }

    // Type4Me HotkeyManager: prefer physical side bits, then use the event's
    // keyCode plus the family flag when IMK supplies device-independent flags.
    private static let modifierKeys: [UInt16: (name: String, mask: UInt, opposite: UInt, family: UInt)] = [
        59: ("Control_L", 0x0001, 0x2000, 1 << 18),
        62: ("Control_R", 0x2000, 0x0001, 1 << 18),
        55: ("Super_L", 0x0008, 0x0010, 1 << 20),
        54: ("Super_R", 0x0010, 0x0008, 1 << 20),
        58: ("Alt_L", 0x0020, 0x0040, 1 << 19),
        61: ("Alt_R", 0x0040, 0x0020, 1 << 19),
        56: ("Shift_L", 0x0002, 0x0004, 1 << 17),
        60: ("Shift_R", 0x0004, 0x0002, 1 << 17),
    ]

    public static func modifierName(keyCode: UInt16) -> String? { modifierKeys[keyCode]?.name }

    public static func modifierIsPressed(keyCode: UInt16, flags: UInt) -> Bool {
        guard let key = modifierKeys[keyCode] else { return false }
        if flags & key.mask != 0 { return true }
        if flags & key.opposite != 0 { return false }
        return flags & key.family != 0
    }

    /// Same key notation as the existing recorder, with F13–F20 supported for voice as well.
    public static func keyName(keyCode: UInt16, character: String?, flags: UInt) -> String? {
        let named: [UInt16: String] = [
            50: "grave", 27: "minus", 24: "equal", 33: "bracketleft", 30: "bracketright",
            42: "backslash", 41: "semicolon", 39: "apostrophe", 43: "comma", 47: "period", 44: "slash",
            49: "space", 48: "Tab", 36: "Return", 53: "Escape", 51: "BackSpace", 117: "Delete",
            116: "Page_Up", 121: "Page_Down", 115: "Home", 119: "End", 123: "Left", 124: "Right", 125: "Down", 126: "Up",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
            101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
            106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
        ]
        let key: String
        if let name = named[keyCode] { key = name }
        else if let character, let scalar = character.lowercased().unicodeScalars.first,
                (0x61...0x7a).contains(scalar.value) || (0x30...0x39).contains(scalar.value) {
            key = String(scalar)
        } else { return nil }
        var parts: [String] = []
        if flags & (1 << 18) != 0 { parts.append("Control") }
        if flags & (1 << 19) != 0 { parts.append("Alt") }
        if flags & (1 << 17) != 0 { parts.append("Shift") }
        if flags & (1 << 20) != 0 { parts.append("Super") }
        parts.append(key)
        return parts.joined(separator: "+")
    }

    public static func display(_ name: String) -> String {
        let labels = ["Control": "⌃", "Alt": "⌥", "Shift": "⇧", "Super": "⌘",
            "Control_L": "左 Control", "Control_R": "右 Control",
            "Super_L": "左 Command", "Super_R": "右 Command",
            "Alt_L": "左 Option", "Alt_R": "右 Option", "Shift_L": "左 Shift", "Shift_R": "右 Shift",
            "space": "空格", "Tab": "⇥", "Return": "↩", "Escape": "⎋", "BackSpace": "⌫",
            "Delete": "⌦", "Page_Up": "⇞", "Page_Down": "⇟", "Home": "↖", "End": "↘",
            "Left": "←", "Right": "→", "Up": "↑", "Down": "↓", "Caps_Lock": "⇪",
            "grave": "`", "minus": "-", "equal": "=", "bracketleft": "[", "bracketright": "]",
            "backslash": "\\", "semicolon": ";", "apostrophe": "'", "comma": ",", "period": ".", "slash": "/"]
        if name.isEmpty { return "未设置" }
        return name.split(separator: "+").map { part in
            labels[String(part)] ?? (part.count == 1 ? part.uppercased() : String(part))
        }.joined()
    }

    private static func isSupported(_ name: String) -> Bool {
        let parts = name.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard let key = parts.last, !key.isEmpty else { return false }
        let modifiers = parts.dropLast()
        guard Set(modifiers).count == modifiers.count,
              modifiers.allSatisfy({ ["Control", "Alt", "Shift", "Super"].contains($0) }) else { return false }
        if modifierKeys.values.contains(where: { $0.name == key }) { return modifiers.isEmpty }
        if key.count == 1, let scalar = key.unicodeScalars.first,
           (0x61...0x7a).contains(scalar.value) || (0x30...0x39).contains(scalar.value) { return true }
        if (1...20).contains(where: { key == "F\($0)" }) { return true }
        return ["grave", "minus", "equal", "bracketleft", "bracketright", "backslash", "semicolon",
                "apostrophe", "comma", "period", "slash", "space", "Tab", "Return", "Escape", "BackSpace",
                "Delete", "Page_Up", "Page_Down", "Home", "End", "Left", "Right", "Up", "Down"].contains(key)
    }

    private struct InvalidShortcut: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
