import CoreGraphics

/// 热键规格（字符串 ⇄ keyCode+修饰符）——纯领域，无 AppKit/Carbon
///
/// 存储格式（设置面板写入）："cmd+shift+a" / "cmd+shift+s" / "opt+cmd+4"
/// 解析失败返回 nil，调用方回落默认值。
public struct HotkeySpec: Equatable, Sendable {
    public let keyCode: UInt32
    public let modifiers: HotkeyModifiers

    public init(keyCode: UInt32, modifiers: HotkeyModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// 虚拟键码表（仅覆盖常用 ASCII；查不到返回 nil）
    private static let keyCodes: [Character: UInt32] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26,
        "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38,
        "k": 40, "n": 45, "m": 46,
    ]

    public static func parse(_ text: String) -> HotkeySpec? {
        let parts = text.lowercased().split(separator: "+").map(String.init)
        guard let keyPart = parts.last, keyPart.count == 1, let char = keyPart.first,
              let code = keyCodes[char] else { return nil }
        var mods: HotkeyModifiers = []
        for part in parts.dropLast() {
            switch part {
            case "cmd", "command": mods.insert(.command)
            case "shift": mods.insert(.shift)
            case "opt", "option", "alt": mods.insert(.option)
            case "ctrl", "control": mods.insert(.control)
            default: return nil
            }
        }
        // 至少一个修饰键，否则会抢普通打字
        guard !mods.isEmpty else { return nil }
        return HotkeySpec(keyCode: code, modifiers: mods)
    }

    /// 反序列化（设置面板回填用）
    public static func string(keyCode: UInt32, modifiers: HotkeyModifiers) -> String? {
        guard let char = keyCodes.first(where: { $0.value == keyCode })?.key else { return nil }
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("opt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("cmd") }
        parts.append(String(char))
        return parts.joined(separator: "+")
    }
}
