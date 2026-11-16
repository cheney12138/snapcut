import AppKit
import Carbon.HIToolbox

/// 编辑器键分发共享 helper（设计定稿 §1.4）：
/// 编辑器热键（⌘Z/H/O/P…，settings.editorHotkeys）原先是 OverlayWindow.keyDown
/// 里私有实现的——拼贴合成编辑宿主（CollageEditorWindowController）需要同一套
/// 分发逻辑，抽出共享；两处调用，行为零变化。
@MainActor
enum EditorKeyRouter {
    /// 动作集合：宿主各自构造（OverlayView → controller；拼贴编辑器 → 自有处理）
    struct Actions {
        var undo: () -> Void = {}
        var redo: () -> Void = {}
        var toggleVisibility: () -> Void = {}
        var ocr: () -> Void = {}
        var pin: () -> Void = {}
        var save: () -> Void = {}
        var done: () -> Void = {}
        var cancel: () -> Void = {}
        var scroll: () -> Void = {}
        var selectTool: (EditorSession.Tool) -> Void = { _ in }

        init(
            undo: @escaping () -> Void = {},
            redo: @escaping () -> Void = {},
            toggleVisibility: @escaping () -> Void = {},
            ocr: @escaping () -> Void = {},
            pin: @escaping () -> Void = {},
            save: @escaping () -> Void = {},
            done: @escaping () -> Void = {},
            cancel: @escaping () -> Void = {},
            scroll: @escaping () -> Void = {},
            selectTool: @escaping (EditorSession.Tool) -> Void = { _ in }
        ) {
            self.undo = undo
            self.redo = redo
            self.toggleVisibility = toggleVisibility
            self.ocr = ocr
            self.pin = pin
            self.save = save
            self.done = done
            self.cancel = cancel
            self.scroll = scroll
            self.selectTool = selectTool
        }
    }

    /// event → 组合串 → settings.editorHotkeys 反查 action key。
    /// 文字输入态的键必须给输入框（调用方自行 guard，同原实现）。
    /// 拼贴编辑器宿主用 matchHotkey(ignoringScroll: true)：滚动截图是截图编辑器
    /// 专属语义，合成编辑窗里 S 仍当普通键（不吞）。
    static func matchHotkey(_ event: NSEvent, ignoringScroll: Bool = false) -> String? {
        let settings = AppCoordinatorShared.coordinator?.settings ?? AppSettings.defaultSettings
        guard let combo = HotkeySpec.combo(
            fromkeyCode: UInt32(event.keyCode),
            modifiers: event.modifierFlags.hotkeyModifiers
        ) else { return nil }
        for (actionKey, stored) in settings.editorHotkeys {
            if ignoringScroll, actionKey == "scroll" { continue }
            let effective = stored.isEmpty ? (AppSettings.defaultEditorHotkeys[actionKey] ?? "") : stored
            guard !effective.isEmpty else { continue }
            // 撞内置键（快存 ⌘⌥S / 文字态 Esc/Return——调用方已挡）：
            // 组合一致时让内置语义先行（设置页有冲突提示）
            // ⚠️ combo 侧也必须 allowBare 解析（病例：滚动截图 S 键进不了采集态，
            // scroll.enter 只能靠工具栏按钮）：裸键事件（s/o/p）走默认 parse 会因
            // 「无修饰键」返回 nil ⇒ 裸键热键（scroll=s / ocr=o / pin=p）全部匹配不上；
            // named 键（return/esc）两侧同为 nil 的既有匹配语义保留（done/cancel 仍生效）。
            if HotkeySpec.parse(effective, allowBare: true)?.keyCode == HotkeySpec.parse(combo, allowBare: true)?.keyCode,
               effective == combo { return actionKey }
        }
        return nil
    }

    /// 分发 action key
    static func perform(_ actionKey: String, actions: Actions) {
        Log.event(.editor, "editor.hotkey", ["action": actionKey])
        switch actionKey {
        case "undo": actions.undo()
        case "redo": actions.redo()
        case "toggleVisibility": actions.toggleVisibility()
        case "ocr": actions.ocr()
        case "pin": actions.pin()
        case "save": actions.save()
        case "done": actions.done()
        case "cancel": actions.cancel()
        case "scroll": actions.scroll()
        default: break
        }
    }

    /// HotkeyModifiers（Core 纯数据）→ NSEvent.ModifierFlags（Carbon 注册用，UI 层桥）
    static func nsEventFlags(_ mods: HotkeyModifiers) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if mods.contains(.command) { flags.insert(.command) }
        if mods.contains(.shift) { flags.insert(.shift) }
        if mods.contains(.option) { flags.insert(.option) }
        if mods.contains(.control) { flags.insert(.control) }
        return flags
    }

    /// 热键 1-6 直选工具（R6）
    static func tool(for keyCode: Int) -> EditorSession.Tool? {
        let map: [Int: EditorSession.Tool] = [
            kVK_ANSI_1: .arrow,
            kVK_ANSI_2: .rect,
            kVK_ANSI_3: .text,
            kVK_ANSI_4: .mosaic,
            kVK_ANSI_5: .sequence,
            kVK_ANSI_6: .highlight,
            kVK_ANSI_7: .ellipse,
        ]
        return map[keyCode]
    }
}
