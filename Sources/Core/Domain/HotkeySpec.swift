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

    /// 命名键（编辑器作用域）：键名 ⇄ 键码。return/esc 是 done/cancel 的
    /// 系统约定默认；字母裸键（o/p/h）是编辑器原语义。
    public static let namedKeys: [String: UInt32] = [
        "return": 36, "esc": 53, "space": 49, "delete": 51, "tab": 48,
        // F 区（用户裁定 2026-11-17「快捷配置不让用 F 区，不要加这个限制」；
        // 键码 = HIToolbox kVK_F1..F12）
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
        "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
        "left": 123, "right": 124, "down": 125, "up": 126,
    ]
    private static let namedKeySymbols: [String: String] = [
        "return": "⏎", "esc": "esc", "space": "Space", "delete": "⌫", "tab": "⇥",
    ]

    /// 显示格式化："cmd+shift+a" → "⌘ ⇧ A"（UI 三处共用：引导窗/托盘菜单/设置页）
    /// （病例：用户改了快捷键，引导窗提示还是写死的 ⌘⇧A）
    /// 命名键显示符号（"return"→"⏎"，"esc"→"esc"）；裸键无前缀（"o"→"O"）
    public static func display(_ text: String) -> String {
        let parts = text.lowercased().split(separator: "+").map(String.init)
        guard let key = parts.last, !key.isEmpty else { return text }
        var prefix = ""
        for mod in parts.dropLast() {
            switch mod {
            case "cmd", "command": prefix += "⌘ "
            case "shift": prefix += "⇧ "
            case "opt", "option", "alt": prefix += "⌥ "
            case "ctrl", "control": prefix += "⌃ "
            default: break
            }
        }
        if let symbol = namedKeySymbols[key] { return prefix + symbol }
        return prefix + (key.count == 1 ? key.uppercased() : key)
    }

    /// 全局热键解析（原语义：至少一个修饰键，防抢打字）
    public static func parse(_ text: String) -> HotkeySpec? {
        parse(text, allowBare: false)
    }

    /// 编辑器热键解析：allowBare = true 时允许裸键（"o"）与命名键
    /// （"return"/"esc"）——编辑器作用域无打字冲突（文字输入态不走这条路径）。
    public static func parse(_ text: String, allowBare: Bool) -> HotkeySpec? {
        let parts = text.lowercased().split(separator: "+").map(String.init)
        guard let keyPart = parts.last, !keyPart.isEmpty else { return nil }
        var code: UInt32? = nil
        if keyPart.count == 1, let char = keyPart.first {
            code = keyCodes[char]
        } else if let named = namedKeys[keyPart] {
            code = named
        }
        guard let keyCode = code else { return nil }
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
        // 至少一个修饰键，否则会抢普通打字（例外：编辑器作用域 allowBare；
        // F 键（功能键）任何作用域都无打字冲突，裸用安全——用户裁定 F 区
        // 全局放开）
        if mods.isEmpty {
            let isFunctionKey = keyPart.count > 1 && namedKeys[keyPart] != nil
                && keyPart.hasPrefix("f") && keyPart.dropFirst().first?.isNumber == true
            if !isFunctionKey {
                guard allowBare else { return nil }
                if keyPart.count != 1 { return nil }
            }
        }
        return HotkeySpec(keyCode: keyCode, modifiers: mods)
    }

    /// 反序列化（设置面板回填用）
    public static func string(keyCode: UInt32, modifiers: HotkeyModifiers) -> String? {
        var keyPart: String? = nil
        if let char = keyCodes.first(where: { $0.value == keyCode })?.key {
            keyPart = String(char)
        } else if let named = namedKeys.first(where: { $0.value == keyCode })?.key {
            keyPart = named
        }
        guard let key = keyPart else { return nil }
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("opt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("cmd") }
        parts.append(key)
        return parts.joined(separator: "+")
    }

    /// NSEvent → 组合串（编辑器 keyDown 匹配用；与 HotkeyRecorderView 的
    /// 录制格式同源）。返回 nil = 不可识别的键。
    public static func combo(fromkeyCode keyCode: UInt32, modifiers: HotkeyModifiers) -> String? {
        string(keyCode: keyCode, modifiers: modifiers)
    }
}
