import AppKit
import ApplicationServices
import CoreGraphics

/// 智能框选的「元素层」适配器：AX hit-test 穿透自身遮罩，沿父链回溯出候选矩形。
///
/// ## 为什么需要它
/// Vision 只能看像素，看不出「这是一个按钮 / 一个列表行 / 一整块卡片」。
/// 而 macOS 的辅助功能树正好有这层语义 —— 命中点下最深的元素，再沿父链回溯，
/// 就得到「叶子控件 → 容器 → 卡片」的候选梯度，供 UI 层按优先级挑选。
///
/// ## 坐标系（最容易错，按下面写）
/// - 输入 `point` 是 **AppKit 全局坐标**：原点主屏左下，Y 向上
/// - AX 的 `kAXPositionAttribute` / `kAXSizeAttribute` 与 `CGWindowListCopyWindowInfo`
///   的 bounds 都是 **CG 全局坐标**：原点主屏左上，Y 向下
/// - 点换算：`cgY = mainScreenHeight - point.y`
/// - 矩形换算：`appKitY = mainScreenHeight - (cgY + cgH)`（与 WindowLocator 同一口径）
///
/// ## 纪律
/// 1. **绝不弹权限窗**：只 `AXIsProcessTrusted()` 静默查询，未授权时直接返回空
///    （UI 层仍有窗口候选与 Vision 兜底，不因为没授权就失效）。
/// 2. **绝不阻塞调用方**：所有 AX IPC 都在这条专用串行队列上跑（QoS 用户交互级），
///    悬停探测是高频路径，主线程一个 IPC 都不能碰。
/// 3. **过期即中止**：每次探测/会话结束递增 `probeGeneration`，队列上每一步都验代，
///    用户手一抖把鼠标移开就立刻放弃剩余 IPC，不烧 CPU。
/// 4. **通用会话级懒激活（任意 Electron / Chromium / CEF / Tauri / 第三方壳）**：
///    Chromium 系默认不建全量 AX 树，只有 `AXManualAccessibility=true` 才吐元素——
///    否则网页表格的 `AXCell` / `AXRow` 在树里根本不存在；Firefox 对应
///    `AXEnhancedUserInterface=true`。**不用 bundleID 白名单**：白名单漏掉任何一个壳
///    （Antigravity 这类桌面 Electron App 就是活例子）等于直接放弃这张表。
///    原生 AppKit App 收到不支持的属性会在 `1ms` 内返回错误码，零副作用。
///    会话结束必须**恢复原值**，不留全局副作用。
/// 5. **刚激活要等树建好**：Electron 打开 DOM 无障碍树是异步的，从关切到开后
///    首次 hit-test 常只摸到窗口壳，故做一次 `120ms` 短等待重试（见 `probeOnQueue`）。
final class AXElementProber: SmartElementProbing, @unchecked Sendable {
    /// 一次会话内对某个 PID 写过的 AX 开关（用于会话结束时还原）
    private struct ActivationLease: Sendable {
        let pid: pid_t
        /// nil = 本次会话已尝试过但无需写入（系统壳跳过，或属性本来已开、或写入失败）
        let attributeName: String?
    }

    /// 点下命中窗口（CG 全局坐标判定，AppKit 坐标由调用方换算）
    private struct TargetWindow {
        let ownerPID: pid_t
        let ownerName: String
        let title: String
        let windowID: CGWindowID
    }

    /// 一轮 hit-test + 父链分类的结果（重试时与首轮对比取更优者）
    private struct HitProbeResult {
        let hitStatus: AXError
        let candidates: [SmartSelectionCandidate]
        /// 父链回溯层数（日志观测用）
        let ancestorDepth: Int
    }

    /// AX IPC 专用串行队列：串行保证「先探测后恢复」的顺序，也避免并发 IPC 抖动
    private let queue = DispatchQueue(label: "app.snapcut.smart-ax", qos: .userInteractive)
    private let lock = NSLock()

    /// 代际号：每次 probe / endSession 递增，队列上每步校验，过期提前退出
    private var probeGeneration: UInt64 = 0
    /// 是否处于一次智能框选会话（beginSession ... endSession）
    private var sessionActive = false
    private var activatedPIDs: [pid_t: ActivationLease] = [:]

    /// 父链最大回溯层数（防病态 AX 树卡死）
    ///
    /// 28 层是为了覆盖深层网页表格的典型链：
    /// `AXStaticText -> AXGroup -> AXCell -> AXRow -> AXTable -> … -> AXWebArea`，
    /// 层数不够就爬不到 `AXTable`，「表格优先」就成了空谈。
    private static let maxAncestorDepth = 28
    static let messagingTimeout: Float = 0.08

    // MARK: - SmartElementProbing

    /// **只查不弹**（`AXIsProcessTrusted` 不会触发系统授权框）
    func isAccessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    /// 幂等：重复调用不会丢掉已在途的激活租约（丢了就还原不回去了）
    func beginSession() {
        lock.withLock {
            if !sessionActive {
                sessionActive = true
                activatedPIDs.removeAll()
            }
            probeGeneration &+= 1
        }
    }

    func endSession() {
        let leases: [ActivationLease] = lock.withLock {
            probeGeneration &+= 1
            sessionActive = false
            let snapshot = activatedPIDs.values.filter { $0.attributeName != nil }
            activatedPIDs.removeAll()
            return snapshot
        }
        guard !leases.isEmpty else { return }
        // 恢复也走 AX 队列：不阻塞调用方，且与在途探测天然串行
        queue.async {
            for lease in leases {
                guard let attributeName = lease.attributeName else { continue }
                let appElement = AXUIElementCreateApplication(lease.pid)
                AXUIElementSetMessagingTimeout(appElement, Self.messagingTimeout)
                let status = AXUIElementSetAttributeValue(
                    appElement, attributeName as CFString, kCFBooleanFalse
                )
                Log.event(.overlay, "smartAX.restore", [
                    "pid": "\(lease.pid)",
                    "attr": attributeName,
                    "ok": status == .success ? "yes" : "no(\(status.rawValue))",
                ])
            }
        }
    }

    func probe(
        atGlobalPoint point: CGPoint,
        mainScreenHeight: CGFloat,
        excludingPID pid: Int32
    ) async -> [SmartSelectionCandidate] {
        let generation = nextGeneration()
        if Task.isCancelled { return [] }
        return await withCheckedContinuation { continuation in
            queue.async {
                let candidates = self.probeOnQueue(
                    point: point,
                    mainScreenHeight: mainScreenHeight,
                    excludingPID: pid,
                    generation: generation
                )
                continuation.resume(returning: candidates)
            }
        }
    }

    // MARK: - 队列内主流程

    private func probeOnQueue(
        point: CGPoint,
        mainScreenHeight: CGFloat,
        excludingPID pid: Int32,
        generation: UInt64
    ) -> [SmartSelectionCandidate] {
        let start = ContinuousClock.now
        guard isCurrent(generation) else { return [] }

        // 1) 点 → CG 坐标（Y 下），穿透自身全屏遮罩找真目标窗口
        let cgPoint = CGPoint(x: point.x, y: mainScreenHeight - point.y)
        guard let target = Self.topWindow(atCGPoint: cgPoint, excludingPID: pid) else {
            Log.event(.overlay, "smartAX.hit", ["win": "none", "trusted": "\(isAccessibilityTrusted())"])
            return []
        }
        guard isCurrent(generation) else { return [] }

        // 2) 未授权就走人（静默查询，绝不弹窗）；窗口候选由 UI 层兜底
        guard isAccessibilityTrusted() else {
            Log.event(.overlay, "smartAX.hit", [
                "win": "\(target.windowID)", "owner": target.ownerName, "trusted": "no",
            ])
            return []
        }

        // 3) 通用懒激活（每个 PID 每会话只尝试一次）
        let justActivated = prepareActivationIfNeeded(for: target.ownerPID)
        guard isCurrent(generation) else { return [] }

        let appElement = AXUIElementCreateApplication(target.ownerPID)
        AXUIElementSetMessagingTimeout(appElement, Self.messagingTimeout)

        // 4) hit-test + 父链回溯
        guard var result = hitTestOnQueue(
            cgPoint: cgPoint,
            appElement: appElement,
            target: target,
            mainScreenHeight: mainScreenHeight,
            generation: generation
        ) else { return [] }

        // 4.5) 刚把 PID 从关切到开：Electron 建 DOM 无障碍树是异步的，首轮常常只摸到
        // 一个窗口壳（0~1 个候选）。等 120ms 再试一次，用户就不用「先进窗口、再晃一下
        // 鼠标」才看到单元格——首次移进 Electron 窗口即可直接出格子。
        if justActivated, (result.hitStatus != .success || result.candidates.count <= 1) {
            Log.event(.overlay, "smartAX.rebuildWait", [
                "pid": "\(target.ownerPID)",
                "owner": target.ownerName,
                "n": "\(result.candidates.count)",
            ])
            guard sleepCheckingGeneration(0.12, generation) else { return [] }
            if let retry = hitTestOnQueue(
                cgPoint: cgPoint,
                appElement: appElement,
                target: target,
                mainScreenHeight: mainScreenHeight,
                generation: generation
            ), retry.candidates.count > result.candidates.count {
                result = retry
            }
        }

        var candidates = result.candidates
        // 5) 零 IPC 补齐「表格列」：HTML 表格父链里没有 AXColumn，用单元格宽度 + 整表算
        if let columnCandidate = Self.synthesizedColumnCandidate(
            in: candidates, ownerName: target.ownerName
        ) {
            candidates.append(columnCandidate)
        }

        let ms = elapsedMs(since: start)
        Log.event(.overlay, "smartAX.probe", [
            "win": "\(target.windowID)",
            "owner": target.ownerName,
            "depth": "\(result.ancestorDepth)",
            "n": "\(candidates.count)",
            "ms": ms,
        ])
        return candidates
    }

    /// 单轮 hit-test + 父链分类
    /// - Returns: nil 表示代际已过期（用户手一动就该立刻放弃剩余 IPC）
    private func hitTestOnQueue(
        cgPoint: CGPoint,
        appElement: AXUIElement,
        target: TargetWindow,
        mainScreenHeight: CGFloat,
        generation: UInt64
    ) -> HitProbeResult? {
        var hitRaw: AXUIElement?
        let hitStatus = AXUIElementCopyElementAtPosition(
            appElement, Float(cgPoint.x), Float(cgPoint.y), &hitRaw
        )
        guard hitStatus == .success, let hitElement = hitRaw else {
            Log.event(.overlay, "smartAX.hit", [
                "win": "\(target.windowID)",
                "owner": target.ownerName,
                "ax": "no(\(hitStatus.rawValue))",
            ])
            return HitProbeResult(hitStatus: hitStatus, candidates: [], ancestorDepth: 0)
        }

        // 沿父链回溯：叶子 → 单元格/列表项/表格 → 容器 → …（窗口层交给 WindowLocator，不重复）
        //
        // 先把整条父链的 (元素, 角色, 矩形) 收下来，再统一分类：
        // 网页无序列表的 `<li>` 在 Chrome/Safari 里常常是 `AXGroup`，
        // 必须看「父节点是不是 AXList/AXOutline」才能判成列表项，
        // 而且父链角色本来就要读，这样不多花一次 IPC。
        var chain: [ProbedNode] = []
        var cursor: AXUIElement? = hitElement

        while let element = cursor, chain.count < Self.maxAncestorDepth {
            guard isCurrent(generation) else { return nil }

            let role = Self.stringAttribute(element, kAXRoleAttribute) ?? ""
            if role == "AXApplication" { break }

            // 只为可能产出候选的角色读几何/标题（AXWindow 交给窗口层，IPC 能省就省）
            var rect: CGRect?
            var title = ""
            if role != "AXWindow", Self.candidateKind(forRole: role) != nil,
                let cgRect = Self.cgRect(of: element) {
                rect = Self.sanitizedAppKitRect(cgRect, mainScreenHeight: mainScreenHeight)
                if rect != nil { title = Self.label(of: element) }
            }
            chain.append(ProbedNode(element: element, role: role, rect: rect, title: title))

            cursor = Self.elementAttribute(element, kAXParentAttribute)
        }

        // 父链后缀里有没有 AXTable/AXGrid：「这一行是表格行还是列表项」的唯一判据
        // （chain 是「内 → 外」，所以从尾部倒着扫一遍累积）
        var enclosingTable = [Bool](repeating: false, count: chain.count)
        var seenTable = false
        for index in chain.indices.reversed() {
            enclosingTable[index] = seenTable
            if Self.tableRoles.contains(chain[index].role) { seenTable = true }
        }

        var candidates: [SmartSelectionCandidate] = []
        candidates.reserveCapacity(chain.count)
        for index in chain.indices {
            let node = chain[index]
            guard let rect = node.rect,
                let baseKind = Self.candidateKind(forRole: node.role) else { continue }
            let parent = index + 1 < chain.count ? chain[index + 1] : nil
            let kind = Self.refinedKind(
                baseKind,
                element: node.element,
                role: node.role,
                rect: rect,
                parentRole: parent?.role ?? "",
                parentRect: parent?.rect,
                hasEnclosingTable: enclosingTable[index]
            )
            candidates.append(SmartSelectionCandidate(
                rectGlobal: rect,
                kind: kind,
                windowID: nil,
                ownerName: target.ownerName,
                title: node.title
            ))
        }

        return HitProbeResult(
            hitStatus: hitStatus, candidates: candidates, ancestorDepth: chain.count
        )
    }

    /// 零 IPC 合成「表格列」候选
    ///
    /// HTML `<table>` 的父链几乎总是 `AXCell → AXRow → AXTable`，中间**没有**
    /// `AXColumn` 节点，但用户滚轮逐级选择时需要的正是四级：单元格 / 整行 / 整列 / 整表。
    /// 所以用「单元格宽度 + 整表宽高」把这列算出来，不花一次 IPC。
    private static func synthesizedColumnCandidate(
        in candidates: [SmartSelectionCandidate],
        ownerName: String
    ) -> SmartSelectionCandidate? {
        // 已经有真 AXColumn（原生 AppKit 表格）就不重复造
        guard !candidates.contains(where: { $0.kind == .tableColumn }) else { return nil }
        // candidates 与父链同序（内 → 外），第一个命中即最内层
        guard let cell = candidates.first(where: { $0.kind == .tableCell }),
            let table = candidates.first(where: { $0.kind == .table }) else { return nil }

        let cellRect = cell.rectGlobal
        let tableRect = table.rectGlobal
        // 单元格要「明显窄于整表」才谈得上独占一列；整表要高过单元格 1.4 倍才有行可分
        guard cellRect.width >= 20,
            cellRect.width < tableRect.width * 0.92,
            tableRect.height > cellRect.height * 1.4 else { return nil }

        let columnRect = CGRect(
            x: cellRect.minX,
            y: tableRect.minY,
            width: cellRect.width,
            height: tableRect.height
        ).intersection(tableRect)
        guard !columnRect.isNull, columnRect.width >= 1, columnRect.height >= 1 else { return nil }
        return SmartSelectionCandidate(
            rectGlobal: columnRect,
            kind: .tableColumn,
            windowID: nil,
            ownerName: ownerName,
            title: ""
        )
    }

    /// 分段 sleep，前后都验代（用户移开鼠标就不该再等这 120ms）
    private func sleepCheckingGeneration(_ seconds: TimeInterval, _ generation: UInt64) -> Bool {
        guard isCurrent(generation) else { return false }
        Thread.sleep(forTimeInterval: seconds)
        return isCurrent(generation)
    }

    // MARK: - 代际（过期保护）

    private func nextGeneration() -> UInt64 {
        lock.withLock {
            probeGeneration &+= 1
            return probeGeneration
        }
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        lock.withLock { probeGeneration == generation }
    }

    // MARK: - 通用懒激活（全 Electron / CEF / Tauri 通用）

    /// - Returns: 本次是否**刚刚**把该 PID 从关切到开（调用方据此做一次建树重试）
    @discardableResult
    private func prepareActivationIfNeeded(for pid: pid_t) -> Bool {
        // 先占位再干活：防同一 PID 在连续探测里重复尝试（IPC 很贵）
        let shouldAttempt = lock.withLock { () -> Bool in
            guard sessionActive, activatedPIDs[pid] == nil else { return false }
            activatedPIDs[pid] = ActivationLease(pid: pid, attributeName: nil)
            return true
        }
        guard shouldAttempt else { return false }

        guard let bundleID = Self.bundleIdentifier(ofPID: pid)?.lowercased() else { return false }
        guard let attributeName = Self.activationAttribute(forBundleID: bundleID) else { return false }

        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, Self.messagingTimeout)

        // 已经是开的：系统默认就吐全量树，无需租约、结束时不还原
        if Self.boolAttribute(appElement, attributeName) == true {
            Log.event(.overlay, "smartAX.activate", ["pid": "\(pid)", "attr": attributeName, "state": "already"])
            return false
        }

        let status = AXUIElementSetAttributeValue(appElement, attributeName as CFString, kCFBooleanTrue)
        guard status == .success else {
            Log.event(.overlay, "smartAX.activate", [
                "pid": "\(pid)", "attr": attributeName, "state": "no(\(status.rawValue))",
            ])
            return false
        }

        let stillSession = lock.withLock { () -> Bool in
            guard sessionActive else { return false }
            activatedPIDs[pid] = ActivationLease(pid: pid, attributeName: attributeName)
            return true
        }
        if !stillSession {
            // 会话已在 IPC 期间结束：立刻撤销，不留全局副作用
            _ = AXUIElementSetAttributeValue(appElement, attributeName as CFString, kCFBooleanFalse)
            return false
        }
        Log.event(.overlay, "smartAX.activate", ["pid": "\(pid)", "attr": attributeName, "state": "on"])
        return true
    }

    /// 激活属性的通用判据（与 Snow Shot 同口径）
    ///
    /// 旧实现靠 Chromium bundleID 白名单，白名单漏掉任何一个 Electron 壳
    /// （比如 Antigravity）就根本不会写开关，网页表格的 `AXCell`/`AXRow` 永远拿不到。
    /// 现在反过来：只**排除**几个纯系统壳，其余全部试 `AXManualAccessibility`。
    /// 代价极低：原生 AppKit App 对这种不存在的属性会 `1ms` 内返回不支持错误码，零副作用。
    private static func activationAttribute(forBundleID bundleID: String) -> String? {
        if skipActivationBundleIDs.contains(bundleID) { return nil }
        // Gecko 系只认这个开关（Firefox / Nightly / 各类 Mozilla 壳）
        if bundleID.contains("firefox") || bundleID.contains("mozilla") {
            return "AXEnhancedUserInterface"
        }
        return "AXManualAccessibility"
    }

    private static func bundleIdentifier(ofPID pid: pid_t) -> String? {
        // NSRunningApplication 可能在进程刚退出时为 nil，安全可选调用
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }

    /// 纯系统壳：没有网页/文档语义，写开关只是白花一次 IPC
    private static let skipActivationBundleIDs: Set<String> = [
        "com.apple.finder",
        "com.apple.dock",
        "com.apple.systemuiserver",
        "com.apple.controlcenter",
        "com.apple.windowmanager",
        "com.apple.notificationcenterui",
    ]

    // MARK: - 角色分类

    /// 父链上的一层（只存本轮回路内需要的东西，不出队列）
    private struct ProbedNode {
        let element: AXUIElement
        let role: String
        let rect: CGRect?
        let title: String
    }

    /// AX 角色 → 候选层级（粗糙一层，真正的语义还要看父链，见 `refinedKind`）
    private static func candidateKind(forRole role: String) -> SmartCandidateKind? {
        if tableRoles.contains(role) { return .table }
        if cellRoles.contains(role) { return .tableCell }
        if columnRoles.contains(role) { return .tableColumn }
        // 行先按列表项占位；父链里有 AXTable/AXGrid 时在 `refinedKind` 升级为 `.tableRow`
        if rowRoles.contains(role) { return .listItem }
        if listItemRoles.contains(role) { return .listItem }
        if elementRoles.contains(role) { return .element }
        if containerRoles.contains(role) { return .container }
        return nil
    }

    /// 二道标注：AX 角色只给「粗糙层级」，真正的语义必须看**父链**：
    ///
    /// - `AXRow` / `AXOutlineRow`：父链里有 `AXTable`/`AXGrid` ⇒ `.tableRow`，
    ///   否则就是无序列表 / 大纲的 `.listItem`；
    /// - 网页 `<li>` 在 AX 树里常常只是 `AXGroup`，但父节点是 `AXList`/`AXOutline`
    ///   —— 这种必须归为 `.listItem`，否则每行列表都会掉进 `.container`，
    ///   默认焦点被整块列表面板抢走（landmark 分组如 `AXLandmarkNavigation` 除外）；
    /// - 表格里的 `<th>` / `<td>` 在 Chromium AX 里有时不是 `AXCell` 而是一个 `AXGroup`：
    ///   父节点是行、自身处于表格内、且宽度明显窄于整行 ⇒ 按 `.tableCell` 处理
    ///   （兼容各种自定义 role / ARIA 表格）。
    private static func refinedKind(
        _ baseKind: SmartCandidateKind,
        element: AXUIElement,
        role: String,
        rect: CGRect,
        parentRole: String,
        parentRect: CGRect?,
        hasEnclosingTable: Bool
    ) -> SmartCandidateKind {
        if rowRoles.contains(role) {
            return hasEnclosingTable ? .tableRow : .listItem
        }
        guard role == "AXGroup", baseKind == .container else { return baseKind }
        if hasEnclosingTable, rowRoles.contains(parentRole),
            let parentRect, parentRect.width > 0, rect.width < parentRect.width * 0.92 {
            return .tableCell
        }
        guard parentRole == "AXList" || parentRole == "AXOutline" else { return baseKind }
        let subrole = stringAttribute(element, kAXSubroleAttribute) ?? ""
        if subrole.hasPrefix("AXLandmark") { return baseKind }
        return .listItem
    }

    /// 表格：大块矩形优先识别的头号目标
    /// （原先 `AXTable` 被归在容器里，导致整张表被单元格/单行字抢走默认焦点）
    private static let tableRoles: Set<String> = ["AXTable", "AXGrid"]

    /// 表格单元格（从 `elementRoles` 里独立出来：滚轮要能单独选一个格子）
    private static let cellRoles: Set<String> = ["AXCell"]

    /// 表格列（原生 AppKit 表格才吐；网页里靠 `synthesizedColumnCandidate` 零 IPC 合成）
    private static let columnRoles: Set<String> = ["AXColumn"]

    /// 表格行 / 大纲行（最终是 `.tableRow` 还是 `.listItem` 由父链决定）
    private static let rowRoles: Set<String> = ["AXRow", "AXOutlineRow"]

    /// 列表项：无序列表 / 大纲的每一行
    private static let listItemRoles: Set<String> = ["AXListItem"]

    /// 独立控件（但要经 `SmartCandidateResolver` 的面积闸门才可能成为默认焦点）
    private static let elementRoles: Set<String> = [
        "AXButton", "AXImage", "AXLink", "AXTextField", "AXTextArea",
        "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXComboBox",
        "AXSlider", "AXSegmentedControl", "AXStaticText",
    ]

    /// 结构性容器（卡片 / 面板 / 滚动区 / 网页主体等）
    private static let containerRoles: Set<String> = [
        "AXGroup", "AXScrollArea", "AXSplitGroup", "AXList", "AXOutline",
        "AXToolbar", "AXTabGroup", "AXWebArea", "AXSheet", "AXPopover",
        "AXSection", "AXArticle", "AXMain", "AXNavigation",
    ]

    // MARK: - 窗口穿透

    /// 取点下最顶层的普通窗口（排除自身遮罩：layer 0 + 非本进程 + 有透明度 + 够大）
    private static func topWindow(atCGPoint cgPoint: CGPoint, excludingPID pid: Int32) -> TargetWindow? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t, ownerPID != pid else { continue }
            guard let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let cgRect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { continue }
            let alpha = info[kCGWindowAlpha as String] as? Double ?? 1
            guard alpha > 0.05 else { continue }
            guard cgRect.width >= 40, cgRect.height >= 40 else { continue }
            guard cgRect.contains(cgPoint) else { continue }
            return TargetWindow(
                ownerPID: ownerPID,
                ownerName: info[kCGWindowOwnerName as String] as? String ?? "",
                title: info[kCGWindowName as String] as? String ?? "",
                windowID: info[kCGWindowNumber as String] as? CGWindowID ?? 0
            )
        }
        return nil
    }

    // MARK: - AX 属性读取（全部在 AX 队列上同步调用）

    private static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == CFStringGetTypeID() else { return nil }
        return raw as? String
    }

    private static func boolAttribute(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == CFBooleanGetTypeID() else { return nil }
        return raw as? Bool
    }

    private static func elementAttribute(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(raw, to: AXUIElement.self)
    }

    private static func pointAttribute(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(raw as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    private static func sizeAttribute(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(raw as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    /// AX position(size 用) + size → CG 全局矩形（Y 下）
    private static func cgRect(of element: AXUIElement) -> CGRect? {
        guard let position = pointAttribute(element, kAXPositionAttribute),
              let size = sizeAttribute(element, kAXSizeAttribute) else { return nil }
        guard position.x.isFinite, position.y.isFinite, size.width.isFinite, size.height.isFinite else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    /// 元素标签：优先 title，其次 description（按钮常只有 description 可读）
    private static func label(of element: AXUIElement) -> String {
        let raw = stringAttribute(element, kAXTitleAttribute)
            ?? stringAttribute(element, kAXDescriptionAttribute)
            ?? ""
        return String(raw.prefix(120))
    }

    /// CG 全局矩形 → AppKit 全局矩形，并过滤噪声（< 12pt 与非法值）
    private static func sanitizedAppKitRect(_ cgRect: CGRect, mainScreenHeight: CGFloat) -> CGRect? {
        guard cgRect.width >= 12, cgRect.height >= 12 else { return nil }
        guard cgRect.minX.isFinite, cgRect.minY.isFinite, cgRect.width.isFinite, cgRect.height.isFinite else {
            return nil
        }
        return CGRect(
            x: cgRect.minX,
            y: mainScreenHeight - cgRect.maxY,
            width: cgRect.width,
            height: cgRect.height
        )
    }

    // MARK: - 计时

    private func elapsedMs(since start: ContinuousClock.Instant) -> String {
        let (seconds, attoseconds) = (ContinuousClock.now - start).components
        let ms = Double(seconds) * 1000 + Double(attoseconds) / 1e15
        return String(format: "%.0f", ms)
    }
}
