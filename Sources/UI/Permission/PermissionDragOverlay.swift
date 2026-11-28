import AppKit
import ApplicationServices
import CoreGraphics

/// 贴身拖拽源浮窗（Pattern: anchor-following drag-source overlay）
///
/// 用途：用户需要去系统设置手动加「屏幕录制」/「辅助功能」权限时，在设置窗口右下角贴一枚
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

    /// 浮窗服务的权限目标（决定文案 + 授权判定口径 + tick 起跑延迟）
    enum TargetPermission: String {
        case screenRecording
        case accessibility
    }

    // MARK: - 常量

    private static let settingsBundleID = "com.apple.systempreferences"
    /// 主设置窗尺寸门槛（第二轮实锤后大幅提高）：第一轮的 500×320 没拦住——
    /// 实机日志 `hit=settings owner=系统设置 title=(redacted)` 证明 TCC 确认框
    /// （macOS 26 屏幕录制确认框带 App 图标预览，实测过 500×320 线）也被放行了。
    /// 系统设置主窗默认 800×600+，700×500 仍远在其下；TCC 确认框没这么大。
    private static let minMainWindowWidth: CGFloat = 700
    private static let minMainWindowHeight: CGFloat = 500
    private static let tickInterval: TimeInterval = 0.1
    /// show() 后延迟 3s 才开始 tick：TCC 确认框弹出后用户还没点「打开系统设置」的
    /// 时期内，浮窗必须安静待命（设置主窗冷启动要几秒，时序天然分离）
    private static let tickStartDelay: TimeInterval = 3.0
    /// 辅助功能：用户点「去授权…」是直开设置列表页（不经过 TCC 确认框），
    /// 没有抢跑风险，短延迟让浮窗尽快贴上去；系统设置主窗另有 policy==.regular
    /// 与 700×500 尺寸闸兜底，不会误贴到小确认框上。
    private static let accessibilityTickStartDelay: TimeInterval = 0.8
    private static let permissionPollInterval: TimeInterval = 2.0
    /// 目标窗消失超过这个时长 → 收浮层（孤儿浮层比没有浮层更糟）
    /// 12s：系统设置冷启动可能 >5s（病例：浮窗等不到目标出现就退场了）
    private static let orphanGrace: TimeInterval = 12.0

    /// 宽度实测（不是手感值）：图标列 16+48+12 = 76pt，中文最长一行
    /// 「已添加 ✓ 重启 Snapcut 后生效」@10pt = 139.7pt，右侧留 12pt 安全边 → 232。
    /// 旧 172 宽会让两条副标题（>110pt）被裁切。
    private static let panelSize = CGSize(width: 232, height: 116)
    private static let anchorRight: CGFloat = 12
    private static let anchorBottom: CGFloat = 16

    // MARK: - 状态

    private var panel: NSPanel?
    private var tickTimer: Timer?
    private var pollTimer: Timer?
    private var targetGoneSince: Date?

    private var isShown = false
    /// 当前浮窗服务的权限目标（pollPermission / 文案都按它分流）
    private var targetPermission: TargetPermission = .screenRecording
    /// tick 生效时刻（show() + tickStartDelay）：确认框在场期间不启动匹配
    private var tickStartAt = Date.distantPast
    /// 用户已把 App 拖进权限列表（等待重启生效）——浮窗切换「已添加」文案
    private var droppedInList = false
    private var dismissTimer: Timer?
    /// 是否已至少见过一次系统设置窗口（区分「冷启动中」与「已消失」）
    private var hasSeenTarget = false

    // MARK: - 对外接口

    /// 显示浮窗（幂等）。调用前提：目标（系统设置）即将被拉起。
    /// - Parameter target: 默认 `.screenRecording`（既有调用点零改动）
    func show(for target: TargetPermission = .screenRecording) {
        if isShown {
            // 同目标重复调用 → 幂等；换目标 → 先收再按新目标重开
            guard targetPermission != target else { return }
            dismiss()
        }
        targetPermission = target
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
        // tick 延迟 tickStartDelay 启动：TCC 确认框与设置主窗的时序天然分离
        // （用户点「打开系统设置」后设置冷启动要几秒），确认框在场期不匹配
        let startDelay = targetPermission == .accessibility
            ? Self.accessibilityTickStartDelay
            : Self.tickStartDelay
        tickStartAt = Date().addingTimeInterval(startDelay)
        Log.event(.permission, "dragOverlay.show", [
            "target": targetPermission.rawValue,
            "tickStartDelay": "\(startDelay)",
        ])

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
        Log.event(.permission, "dragOverlay.dismiss", ["target": targetPermission.rawValue])
    }

    /// 用户完成了一次拖放（drag.end）：切换提示并定时退场
    private func markDropped() {
        guard isShown, !droppedInList else { return }
        droppedInList = true
        (panel?.contentView as? PanelContentView)?.updateForDropped()
        Log.event(.permission, "dragOverlay.droppedInList", ["target": targetPermission.rawValue])
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
        panel.contentView = PanelContentView(frame: frame, overlay: self, target: targetPermission)
        return panel
    }

    // MARK: - 锚定跟随（100ms tick）

    private func tick() {
        // show() 后的静默期：TCC 确认框在场期间不启动匹配（防抢跑第一道闸）
        guard Date() >= tickStartAt else { return }

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
        // match 打点由 settingsWindowFrame() 的 noteMatchResult 落（状态变化时才记，10Hz 不刷屏）
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

    /// tick 10Hz 轮询 → match 打点只在状态变化时落一条（避免日志刷屏）
    private var matchLogSignature: String?

    /// 匹配结果变化时落一条 dragOverlay.match（记 owner/title/size，供实机根因核对）
    private func noteMatchResult(hit: Bool, owner: String, title: String,
                                 missReason: String, size: String = "") {
        let signature = hit ? "hit|\(owner)|\(title)" : "miss|\(missReason)"
        guard signature != matchLogSignature else { return }
        matchLogSignature = signature
        Log.event(.permission, "dragOverlay.match", [
            "hit": hit ? "settings" : missReason,
            "owner": owner,
            "title": title,
            "size": size,
        ])
    }

    /// 用 CGWindowListCopyWindowInfo 找系统设置 layer-0 主窗（NSRunningApplication 拿不到窗口列表）
    ///
    /// 病例二轮（第一轮 500×320 + 标题校验没拦住）：实机日志
    ///   evt=dragOverlay.show
    ///   evt=dragOverlay.match hit=settings owner=系统设置 title=(redacted)
    /// 即 TCC 确认框（「'Snapcut' 想要录制此电脑的屏幕和音频」，owner 与系统设置同进程
    /// com.apple.systempreferences）被 match 成目标窗。逐闸复盘：
    /// - 尺寸闸 500×320：macOS 26 确认框带 App 图标预览，实际尺寸过了线 → 没拦住；
    /// - 标题闸：未授权期 kCGWindowName 被系统裁剪（title=(redacted)）→ 形同虚设。
    ///
    /// 新判据链（四道闸，命中必须全过；打点保留各分支供实机定位）：
    /// ① 进程形态闸：NSRunningApplication(com.apple.systempreferences) 存在且
    ///   activationPolicy == .regular——TCC 确认框由后台形态的 systempreferences
    ///   进程承载（无 Dock 图标）；用户点「打开系统设置」后进程才转 regular 并拉起主窗。
    /// ② 静默期闸：show() 后 3s 内不启动 tick（确认框在场期天然排除）。
    /// ③ 尺寸闸 700×500：确认框没这么大；设置主窗默认 800×600+。
    /// ④ 标题闸：标题可读时（授权后）才校验含「设置/Settings」——不能依赖
    ///   kCGWindowName（未授权期被裁剪），也不能依赖辅助功能权限。
    /// 同进程多窗（确认框 + 主窗并存）时取面积最大者 = 主窗。
    private func settingsWindowFrame() -> CGRect? {
        guard let settingsApp = NSRunningApplication
            .runningApplications(withBundleIdentifier: Self.settingsBundleID).first else {
            noteMatchResult(hit: false, owner: "", title: "", missReason: "settingsNotRunning")
            return nil
        }
        // ① 进程形态闸：确认框承载期进程不是 regular（后台形态，无 Dock 图标）
        let policy = settingsApp.activationPolicy
        guard policy == .regular else {
            noteMatchResult(hit: false, owner: "系统设置", title: "",
                            missReason: "policySuspect(policy=\(policy.rawValue))")
            return nil
        }
        let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
            as? [[String: Any]] ?? []
        var best: CGRect?
        var bestOwner = ""
        var bestTitle = ""
        for info in infoList {
            guard let pid = info[kCGWindowOwnerPID as String] as? Int32,
                  pid == settingsApp.processIdentifier,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect.rect(fromDict: boundsDict) else { continue }
            let owner = info[kCGWindowOwnerName as String] as? String ?? "?"
            let title = info[kCGWindowName as String] as? String ?? ""
            let titleDisplay = title.isEmpty ? "(redacted)" : title
            if bounds.width < 50 || bounds.height < 50 { continue } // 排除杂音小窗
            // ③ 尺寸闸：700×500（确认框过不了；设置主窗默认 800×600+）
            if bounds.width < Self.minMainWindowWidth || bounds.height < Self.minMainWindowHeight {
                noteMatchResult(hit: false, owner: owner, title: titleDisplay,
                                missReason: "dialogSuspect",
                                size: "\(Int(bounds.width))x\(Int(bounds.height))")
                continue
            }
            // ④ 标题闸（kCGWindowName 未授权期缺省 → 跳过，靠①③双闸兜底）
            if !title.isEmpty,
               !title.contains("设置"),
               !title.localizedCaseInsensitiveContains("settings") {
                noteMatchResult(hit: false, owner: owner, title: titleDisplay,
                                missReason: "titleMismatch",
                                size: "\(Int(bounds.width))x\(Int(bounds.height))")
                continue
            }
            if best == nil || bounds.area > best!.area {
                best = bounds
                bestOwner = owner
                bestTitle = titleDisplay
            }
        }
        guard let rect = best else {
            noteMatchResult(hit: false, owner: "", title: "", missReason: "noSettingsWindow")
            return nil
        }
        noteMatchResult(hit: true, owner: bestOwner, title: bestTitle,
                        missReason: "", size: "\(Int(rect.width))x\(Int(rect.height))")
        return Self.cgToAppKit(rect)
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

    /// 授权轮询：按目标权限各自判定（两者语义完全不同，不可混用）
    /// - `.screenRecording`：`CGPreflightScreenCaptureAccess()` 只查不弹；
    ///   但录屏授权需重启进程才生效，这里是免重启场景的兜底。
    /// - `.accessibility`：`AXIsProcessTrusted()` 只查不弹；用户把 Snapcut 拖进
    ///   辅助功能列表并打开开关的瞬间即变 true → 立刻收浮窗（无需重启）。
    private func pollPermission() {
        guard isShown else { return }
        let granted: Bool
        switch targetPermission {
        case .screenRecording:
            granted = CGPreflightScreenCaptureAccess()
        case .accessibility:
            granted = AXIsProcessTrusted()
        }
        if granted {
            Log.event(.permission, "dragOverlay.granted", ["target": targetPermission.rawValue])
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
