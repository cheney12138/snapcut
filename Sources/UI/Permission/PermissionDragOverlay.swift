import AppKit
import CoreGraphics

/// 贴身拖拽源浮窗（Pattern: anchor-following drag-source overlay）
///
/// 用途：用户需要去系统设置手动加「屏幕录制」权限时，在设置窗口右下角贴一枚
/// 不抢焦点的浮层，浮层上的 App 图标可拖进 TCC 权限列表（负载与 Finder 逐字等价）。
///
/// 病例警告（照搬 pattern 文档，勿重蹈）：
/// - isMovableByWindowBackground 必须关，否则 mouseDown 阶段整窗被拖走
/// - 拖拽源必须 AppKit 原生（writeObjects + NSDraggingItem），SwiftUI onDrag 负载系统设置不认
/// - beginDraggingSession 的 source 必须是持久代理（单例），会话期间不能释放
/// - 拖拽进行中冻结一切重定位与消失
@MainActor
final class PermissionDragOverlay {
    static let shared = PermissionDragOverlay()

    // MARK: - 常量

    private static let settingsBundleID = "com.apple.systempreferences"
    private static let tickInterval: TimeInterval = 0.1
    private static let permissionPollInterval: TimeInterval = 2.0
    /// 目标窗消失超过这个时长 → 收浮层（孤儿浮层比没有浮层更糟）
    /// 12s：系统设置冷启动可能 >5s（病例：浮窗等不到目标出现就退场了）
    private static let orphanGrace: TimeInterval = 12.0

    private static let panelSize = CGSize(width: 172, height: 116)
    private static let anchorRight: CGFloat = 12
    private static let anchorBottom: CGFloat = 16

    // MARK: - 状态

    private var panel: NSPanel?
    private var tickTimer: Timer?
    private var pollTimer: Timer?
    private var targetGoneSince: Date?

    private var isShown = false
    /// 用户已把 App 拖进权限列表（等待重启生效）——浮窗切换「已添加」文案
    private var droppedInList = false
    private var dismissTimer: Timer?
    /// 是否已至少见过一次系统设置窗口（区分「冷启动中」与「已消失」）
    private var hasSeenTarget = false

    // MARK: - 对外接口

    /// 显示浮窗（幂等）。调用前提：目标（系统设置）即将被拉起。
    func show() {
        guard !isShown else { return }
        isShown = true
        droppedInList = false
        hasSeenTarget = false
        targetGoneSince = nil
        // 拖放进列表后：屏幕录制 TCC 需重启本进程才生效，轮询 preflight
        // 永远看不到 granted=true（Glance 辅助功能是即时生效，这里是特例）
        // → 监听 drag.end 切换「已添加，重启生效」态 + 定时退场
        DragSourceCoordinator.shared.onDragEnd = { [weak self] in
            MainActor.assumeIsolated {
                self?.markDropped()
            }
        }

        let panel = makePanel()
        self.panel = panel
        // 显示交给 tick：第一次找到系统设置窗口后才 orderFront + 贴角
        // （冷启动期直接显示会在错误位置闪现）
        Log.event(.permission, "dragOverlay.show")

        let tick = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(tick, forMode: .common)
        tickTimer = tick

        let poll = Timer(timeInterval: Self.permissionPollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollPermission() }
        }
        RunLoop.main.add(poll, forMode: .common)
        pollTimer = poll
    }

    func dismiss() {
        guard isShown else { return }
        isShown = false
        tickTimer?.invalidate()
        pollTimer?.invalidate()
        dismissTimer?.invalidate()
        tickTimer = nil
        pollTimer = nil
        dismissTimer = nil
        DragSourceCoordinator.shared.onDragEnd = nil
        panel?.orderOut(nil)
        panel = nil
        targetGoneSince = nil
        Log.event(.permission, "dragOverlay.dismiss")
    }

    /// 用户完成了一次拖放（drag.end）：切换提示并定时退场
    private func markDropped() {
        guard isShown, !droppedInList else { return }
        droppedInList = true
        (panel?.contentView as? PanelContentView)?.updateForDropped()
        Log.event(.permission, "dragOverlay.droppedInList")
        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.dismiss()
            }
        }
    }

    // MARK: - 窗体

    private func makePanel() -> NSPanel {
        let frame = NSRect(x: 0, y: 0, width: Self.panelSize.width, height: Self.panelSize.height)
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        // ⚠️ 必须关：开着的话 mouseDown 阶段整窗被拖走，拖拽手势接不到
        panel.isMovableByWindowBackground = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.contentView = PanelContentView(frame: frame, overlay: self)
        return panel
    }

    // MARK: - 锚定跟随（100ms tick）

    private func tick() {
        // ⚠️ 拖拽进行中冻结一切重定位与消失（拖一半浮层跑了 = 灾难）
        if DragSourceCoordinator.shared.isDragging || (NSEvent.pressedMouseButtons & 1) != 0 {
            return
        }

        guard let panel, isShown else { return }

        if let target = settingsWindowFrame() {
            hasSeenTarget = true
            targetGoneSince = nil
            if !panel.isVisible {
                panel.orderFrontRegardless()
            }
            place(panel: panel, at: target)
        } else if hasSeenTarget {
            // 目标窗最小化/切 Space → 跟着藏；进程退出 → 孤儿期后收
            if panel.isVisible {
                panel.orderOut(nil)
            }
            if targetGoneSince == nil {
                targetGoneSince = Date()
            } else if Date().timeIntervalSince(targetGoneSince!) > Self.orphanGrace {
                dismiss()
            }
        }
        // 冷启动（从未见过目标）：安静等待系统设置窗口出现，不显示不销毁
    }

    /// 贴角：目标窗右下角内侧（右距 12 / 下距 16），夹进屏幕 visibleFrame
    private func place(panel: NSPanel, at target: CGRect) {
        let size = Self.panelSize
        var origin = CGPoint(
            x: target.maxX - size.width - Self.anchorRight,
            y: target.minY + Self.anchorBottom
        )
        // 夹进目标窗所在屏幕的 visibleFrame（不遮菜单栏/Dock）
        let screen = NSScreen.screens.first { NSMouseInRect(target.midPoint, $0.frame, false) }
            ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
            origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        }
        panel.setFrameOrigin(origin)
    }

    /// 用 CGWindowListCopyWindowInfo 找系统设置 layer-0 最大在屏窗（NSRunningApplication 拿不到窗口列表）
    private func settingsWindowFrame() -> CGRect? {
        let targetBundleID = "com.apple.systempreferences"
        let settingsApps = NSRunningApplication.runningApplications(withBundleIdentifier: targetBundleID)
        guard let settingsApp = settingsApps.first,
              settingsApp.isActive || !settingsApp.isTerminated else { return nil }
        let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
            as? [[String: Any]] ?? []
        var best: CGRect?
        for info in infoList {
            guard let pid = info[kCGWindowOwnerPID as String] as? Int32,
                  pid == settingsApp.processIdentifier,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect.rect(fromDict: boundsDict) else { continue }
            if bounds.width < 50 || bounds.height < 50 { continue } // 排除杂音小窗
            if best == nil || bounds.area > best!.area {
                best = bounds
            }
        }
        return best.map(Self.cgToAppKit)
    }

    /// CG 全局坐标（原点在主屏左上，Y 向下）→ AppKit 全局坐标（原点主屏左下，Y 向上）
    private static func cgToAppKit(_ rect: CGRect) -> CGRect {
        // 主屏（含菜单栏）的完整高度：primary frame origin 是 (0,0)
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(
            x: rect.minX,
            y: primaryMaxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    // MARK: - 授权轮询

    private func pollPermission() {
        guard isShown else { return }
        // 免重启生效的兜底（多数情况下屏幕录制需要 relaunch）
        if CGPreflightScreenCaptureAccess() {
            Log.event(.permission, "dragOverlay.granted")
            dismiss()
        }
    }
}

// MARK: - 小工具

private extension CGRect {
    var midPoint: CGPoint { CGPoint(x: midX, y: midY) }
    var area: CGFloat { width * height }

    static func rect(fromDict d: [String: Any]) -> CGRect? {
        guard let x = d["X"] as? CGFloat,
              let y = d["Y"] as? CGFloat,
              let w = d["Width"] as? CGFloat,
              let h = d["Height"] as? CGFloat else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }
}
