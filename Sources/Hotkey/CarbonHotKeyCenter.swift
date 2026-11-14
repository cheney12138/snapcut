import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// Carbon RegisterEventHotKey 全局快捷键（docs/03 §9）
///
/// 优势：不需要辅助功能/输入监控权限。Carbon 已停止演进但该 API 在当前 macOS 完全可用，
/// 回退路径：NSEvent.addGlobalMonitorForEvents + 输入监控权限引导。
/// 热键签名常量（模块级：C 函数指针闭包内不能引用 dynamic Self）
private let kSnapcutHotKeySignature: OSType = 0x534E5043 // 'SNPC'

@MainActor
final class CarbonHotKeyCenter {

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var hotKeyIDs: [UInt32: () -> Void] = [:]
    private var nextID: UInt32 = 1

    // MARK: - 注册

    /// 注册全局快捷键。action 在主线程回调。
    func register(keyCode: Int, modifiers: NSEvent.ModifierFlags, action: @escaping () -> Void) -> Bool {
        installHandlerIfNeeded()

        let id = nextID
        nextID += 1
        hotKeyIDs[id] = action

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: kSnapcutHotKeySignature, id: id)
        let status = RegisterEventHotKey(
            UInt32(keyCode),
            carbonModifiers(from: modifiers),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, ref != nil else {
            hotKeyIDs[id] = nil
            Log.error(.hotkey, "hotkey.register.fail", ["err": "\(status)"])
            return false
        }
        hotKeyRef = ref
        Log.event(.hotkey, "hotkey.registered", [
            "id": "\(id)",
            "key": keyDescription(keyCode: keyCode, modifiers: modifiers),
        ])
        return true
    }

    func teardown() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
        }
        Log.event(.hotkey, "hotkey.teardown")
    }

    // MARK: - 私有

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                MainActor.assumeIsolated {
                    guard let event, let userData else { return OSStatus(noErr) }
                    var hkID = EventHotKeyID()
                    GetEventParameter(
                        event,
                        EventParamName(kEventParamDirectObject),
                        EventParamType(typeEventHotKeyID),
                        nil,
                        MemoryLayout<EventHotKeyID>.size,
                        nil,
                        &hkID
                    )
                    if hkID.signature == kSnapcutHotKeySignature {
                        let center = Unmanaged<CarbonHotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
                        center.hotKeyIDs[hkID.id]?()
                    }
                    return OSStatus(noErr)
                }
            },
            1,
            &eventType,
            userData,
            &handlerRef
        )
        if status != noErr {
            Log.error(.hotkey, "hotkey.handler.fail", ["err": "\(status)"])
        }
    }

    private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        return result
    }

    private func keyDescription(keyCode: Int, modifiers: NSEvent.ModifierFlags) -> String {
        var desc = ""
        if modifiers.contains(.command) { desc += "⌘" }
        if modifiers.contains(.shift) { desc += "⇧" }
        if modifiers.contains(.option) { desc += "⌥" }
        if modifiers.contains(.control) { desc += "⌃" }
        desc += KeyCodeNames.name(for: keyCode)
        return desc
    }
}

/// 常用键码 → 显示名（v0.1 只用到字母区）
enum KeyCodeNames {
    static func name(for keyCode: Int) -> String {
        let letters: [Int: String] = [
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
            kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
            kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
            kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
            kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
            kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
            kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
        ]
        return letters[keyCode] ?? "key(\(keyCode))"
    }
}
