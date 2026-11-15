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
            self.selectTool = selectTool
        }
    }

    /// event → 组合串 → settings.editorHotkeys 反查 action key。
    /// 文字输入态的键必须给输入框（调用方自行 guard，同原实现）。
    static func matchHotkey(_ event: NSEvent) -> String? {
        let settings = AppCoordinatorShared.coordinator?.settings ?? AppSettings.defaultSettings
        guard let combo = HotkeySpec.combo(
            fromkeyCode: UInt32(event.keyCode),
            modifiers: event.modifierFlags.hotkeyModifiers
        ) else { return nil }
        for (actionKey, stored) in settings.editorHotkeys {
            let effective = stored.isEmpty ? (AppSettings.defaultEditorHotkeys[actionKey] ?? "") : stored
            guard !effective.isEmpty else { continue }
            // 撞内置键（滚动 S / 快存 ⌘⌥S / 文字态 Esc/Return——调用方已挡）：
            // 组合一致时让内置语义先行（设置页有冲突提示）
            if HotkeySpec.parse(effective, allowBare: true)?.keyCode == HotkeySpec.parse(combo)?.keyCode,
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
        default: break
        }
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
        ]
        return map[keyCode]
    }
}
