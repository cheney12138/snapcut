import AppKit
import CoreGraphics

/// 贴图磁吸组注册表（设计定稿 §1.2）：live pins 的组关系唯一真相源。
///
/// - `pinID → groupID` 的成员映射 + `groups: [Int: [PinWindowController]]`
/// - 组视觉（GroupBorderPanel）生命周期在这里管理：成组 ≥2 张建框，
///   只剩 1 张解散
/// - 不做持久化（pin 本身不持久化，一致）
/// - 吸附时机：拖动中实时预览；union 在 mouseUp 提交（可撤销、不闪烁）
@MainActor
final class PinMagnetRegistry {
    static let shared = PinMagnetRegistry()
    private init() {}

    // MARK: - 状态

    private var groups: [Int: [PinWindowController]] = [:]
    private var memberships: [ObjectIdentifier: Int] = [:]
    private var borderPanels: [Int: GroupBorderPanel] = [:]
    private var nextGroupID = 1

    /// 组框拖空白处的整组刚体拖动（含磁吸，⌘拖同款语义）
    private var borderDrag: BorderDragState?
    private struct BorderDragState {
        let groupID: Int
        let startCursor: CGPoint
        let startFrames: [ObjectIdentifier: CGRect]
        let startUnion: CGRect
        var snap: (partner: PinWindowController, edge: MagnetEdge)?
        /// 磁吸手感（任务 B，同 PinWindowController.DragState）
        var easer = SnapEaser()
        var resnap = SnapResnapGuard()
    }

    // MARK: - pin 身份（MagnetSnapItem.id：进程内唯一即可）

    static func id(of pin: PinWindowController) -> String {
        String(describing: ObjectIdentifier(pin))
    }

    func pin(byID id: String) -> PinWindowController? {
        PinWindowController.livePins.first { Self.id(of: $0) == id }
    }

    // MARK: - 生命周期

    /// pin 创建（无组状态，无需登记）
    func register(_ pin: PinWindowController) {}

    /// pin 关闭：摘出组；组只剩 1 张时解散
    func remove(_ pin: PinWindowController) {
        guard let gid = memberships[ObjectIdentifier(pin)] else { return }
        memberships[ObjectIdentifier(pin)] = nil
        groups[gid]?.removeAll { $0 === pin }
        refreshLayout(groupID: gid)
    }

    func groupID(for pin: PinWindowController) -> Int? {
        memberships[ObjectIdentifier(pin)]
    }

    func memberCount(_ gid: Int) -> Int { groups[gid]?.count ?? 0 }

    /// pin 所在组的成员（未成组 → [pin] 自身）
    func groupMembers(of pin: PinWindowController) -> [PinWindowController] {
        guard let gid = groupID(for: pin) else { return [pin] }
        return groups[gid] ?? [pin]
    }

    /// 磁吸候选：除排除集合外的全部存活 pin（外框空间；未成组 pin 用
    /// frame 外扩 9pt 的虚拟外框——垫出现前后几何不跳变）。
    /// ignoreGroupOf：拖动中剔除该 pin 所在组的成员（⌥拆组拖不吸回原组）。
    func snapCandidates(
        excluding pins: [PinWindowController],
        ignoreGroupOf: PinWindowController? = nil
    ) -> [MagnetSnapItem] {
        let exclude = Set(pins.map(ObjectIdentifier.init))
        let ignoreGroup = ignoreGroupOf.flatMap { groupID(for: $0) }
        var items: [MagnetSnapItem] = []
        for pin in PinWindowController.livePins {
            if exclude.contains(ObjectIdentifier(pin)) { continue }
            if let ignoreGroup, groupID(for: pin) == ignoreGroup { continue }
            let outer = pin.windowFrame(insetByGroupPad: !pin.inGroup)
            items.append(MagnetSnapItem(id: Self.id(of: pin), frame: outer))
        }
        return items
    }

    // MARK: - 成组 / 拆组

    /// union 提交（mouseUp 吸附生效时调用；a 可为组拖 leader）
    /// a、b 同组 → 只刷新布局；否则并成大组并记 collage.group.merge
    func union(_ a: PinWindowController, _ b: PinWindowController) {
        let ga = groupID(for: a)
        let gb = groupID(for: b)
        if let ga, ga == gb {
            refreshLayout(groupID: ga)
            return
        }
        // 目标组：a 有组用 a 的（⌘组拖吸到散件保留原组 id）；
        // 都无组 → 新建
        let target: Int
        switch (ga, gb) {
        case (nil, nil):
            target = nextGroupID
            nextGroupID += 1
            groups[target] = []
        case (let g?, _):
            target = g
        case (nil, let g?):
            target = g
        }
        for pin in [a, b] {
            if let g = groupID(for: pin), g != target {
                for member in groups[g] ?? [] {
                    memberships[ObjectIdentifier(member)] = target
                    groups[target]?.append(member)
                }
                groups[g] = nil
                closePanel(g)
            }
            if groupID(for: pin) == nil {
                memberships[ObjectIdentifier(pin)] = target
                groups[target]?.append(pin)
            }
        }
        Log.event(.pin, "collage.group.merge", [
            "group": "\(target)",
            "members": "\(groups[target]?.count ?? 0)",
        ])
        refreshLayout(groupID: target)
    }

    /// ⌥拖拆组：pin 脱离所在组（组只剩 1 张时随之解散）
    func detach(_ pin: PinWindowController) {
        guard let gid = memberships[ObjectIdentifier(pin)] else { return }
        memberships[ObjectIdentifier(pin)] = nil
        groups[gid]?.removeAll { $0 === pin }
        Log.event(.pin, "collage.group.detach", ["group": "\(gid)"])
        refreshLayout(groupID: gid)
    }

    // MARK: - 组框布局（成员几何变化 → 重算 union rect）

    /// 成员 frame 变化（重排 / 缩放 / 拖动中）后调用
    func notifyLayoutChanged(_ pin: PinWindowController) {
        if let gid = groupID(for: pin) {
            refreshLayout(groupID: gid)
        }
    }

    func refreshLayout(groupID gid: Int) {
        guard let members = groups[gid], !members.isEmpty else {
            groups[gid] = nil
            closePanel(gid)
            return
        }
        // reviewer 修正 2026-11-15：原 guard 含 borderDrag?.groupID != gid——
        // 拖组框路径（borderDragMoved 末尾显式调本方法）正撞短路，虚线框/徽标/
        // 合成键永远留在原地不跟随。改为纯成员数判断（borderDrag 期间成员只经
        // setFrameOrigin 落位、不触发 notifyLayoutChanged，安全）。
        guard members.count >= 2 else {
            dissolve(groupID: gid, members: members)
            return
        }
        for member in members { member.setInGroup(true) }
        let union = MagnetGroup.unionRect(members.map { $0.windowFrame })
        let panel = borderPanels[gid] ?? makeBorderPanel(gid)
        // 窗体外扩 22（GroupFrame.panelOutset）：浮标骑框顶外 −11pt 不再被窗缘裁切
        let outset = DesignTokens.GroupFrame.panelOutset
        panel.setFrame(union.insetBy(dx: -outset, dy: -outset), display: true)
        panel.orderFrontRegardless()
        panel.refresh(count: members.count)
        panel.playEntranceIfNeeded()
    }

    private func dissolve(groupID gid: Int, members: [PinWindowController]) {
        for member in members { member.setInGroup(false) }
        groups[gid] = nil
        closePanel(gid)
        Log.event(.pin, "collage.group.dissolve", ["group": "\(gid)"])
    }

    private func closePanel(_ gid: Int) {
        borderPanels[gid]?.dismissAnimated()   // 退场 fade 0.15s（completion 持有面板收窗）
        borderPanels[gid] = nil
    }

    private func makeBorderPanel(_ gid: Int) -> GroupBorderPanel {
        let panel = GroupBorderPanel(groupID: gid)
        panel.onAssemble = { [weak self] in self?.assemble(groupID: gid) }
        panel.onDragBegin = { [weak self] in
            self?.beginBorderDrag(groupID: gid, at: NSEvent.mouseLocation)
        }
        panel.onDragMoved = { [weak self] in self?.borderDragMoved() }
        panel.onDragEnd = { [weak self] in self?.endBorderDrag() }
        borderPanels[gid] = panel
        return panel
    }

    // MARK: - 组框拖空白处 = 整组刚体移动（含磁吸）

    private func beginBorderDrag(groupID gid: Int, at cursor: CGPoint) {
        guard borderDrag == nil, let members = groups[gid], members.count >= 2 else { return }
        var frames: [ObjectIdentifier: CGRect] = [:]
        for member in members { frames[ObjectIdentifier(member)] = member.windowFrame }
        borderDrag = BorderDragState(
            groupID: gid,
            startCursor: cursor,
            startFrames: frames,
            startUnion: MagnetGroup.unionRect(members.map { $0.windowFrame }),
            snap: nil
        )
    }

    func borderDragMoved() {
        guard var state = borderDrag, let members = groups[state.groupID] else { return }
        let cursor = NSEvent.mouseLocation
        let delta = CGSize(width: cursor.x - state.startCursor.x, height: cursor.y - state.startCursor.y)
        let candidate = state.startUnion.offsetBy(dx: delta.width, dy: delta.height)
        let others = snapCandidates(excluding: members)
        let active = state.snap.map { (Self.id(of: $0.partner), $0.edge) }
        let now = CACurrentMediaTime()

        func applyFree() {
            let rendered = state.easer.freeFrame(target: candidate.origin, now: now)
            let moveDelta = CGSize(
                width: rendered.x - state.startUnion.origin.x,
                height: rendered.y - state.startUnion.origin.y
            )
            for member in members {
                let start = state.startFrames[ObjectIdentifier(member)] ?? member.windowFrame
                member.setFrameOrigin(start.origin.offsetBy(moveDelta))
            }
        }

        if let outcome = MagnetGroup.snap(candidate: candidate, others: others, active: active),
           // 重吸防抖：刚分离 200ms 内同伙伴同边不重吸
           !state.resnap.shouldSuppress(partnerID: outcome.partnerID, edge: outcome.edge, now: now) {
            // 分离阻力 + 落位缓动（同 PinWindowController.dragGroupMoved）
            let resist = SnapFeel.resistOffset(candidate: candidate, outcome: outcome)
            let target = candidate.origin.offsetBy(CGSize(
                width: outcome.frame.minX - candidate.minX,
                height: outcome.frame.minY - candidate.minY
            )).offsetBy(resist)
            let partner = pin(byID: outcome.partnerID)
            let isNewSnap = state.snap.map {
                $0.partner !== partner || $0.edge != outcome.edge
            } ?? true
            let rendered = state.easer.snapFrame(target: target, newSnap: isNewSnap, now: now)
            let moveDelta = CGSize(
                width: rendered.x - state.startUnion.origin.x,
                height: rendered.y - state.startUnion.origin.y
            )
            for member in members {
                let start = state.startFrames[ObjectIdentifier(member)] ?? member.windowFrame
                member.setFrameOrigin(start.origin.offsetBy(moveDelta))
            }
            if state.snap?.partner !== partner {
                state.snap?.partner.contentView.setSnapGlow(false)
                partner?.contentView.setSnapGlow(true)
            }
            state.snap = partner.map { ($0, outcome.edge) }
            borderDrag = state
        } else {
            if let snapped = state.snap {
                Log.event(.pin, "collage.magnet.release", [:])
                snapped.partner.contentView.setSnapGlow(false)
                state.resnap.noteRelease(
                    partnerID: Self.id(of: snapped.partner),
                    edge: snapped.edge,
                    now: now
                )
                state.snap = nil
                borderDrag = state
            }
            applyFree()
        }
        refreshLayout(groupID: state.groupID)
    }

    func endBorderDrag() {
        guard let state = borderDrag else { return }
        borderDrag = nil
        state.snap?.partner.contentView.setSnapGlow(false)
        if let snap = state.snap {
            Log.event(.pin, "collage.magnet.snap", [
                "edge": snap.edge.rawValue,
                "partner": Self.id(of: snap.partner),
                "via": "border",
            ])
            // 整组吸到对方：leader 取组内任一成员做 union
            // reviewer 补丁：partner 可能在拖动中途被 Esc 关掉（僵尸引用）——
            // union 前校验存活，避免把已关窗塞回组
            if let leader = groups[state.groupID]?.first,
               PinWindowController.livePins.contains(where: { $0 === snap.partner }) {
                union(leader, snap.partner)
            }
        }
    }

    // MARK: - 合成整体（组 → 合成图 → 标注编辑器）

    func assemble(groupID gid: Int) {
        guard let members = groups[gid], members.count >= 2 else { return }
        let items = members.map { (image: $0.image, frame: $0.windowFrame) }
        guard let composited = PinAssembleEngine.compose(members: items) else {
            Log.error(.pin, "collage.assemble.fail", ["reason": "compose"])
            return
        }
        let composite = composited.image
        Log.event(.export, "collage.assemble", [
            "members": "\(members.count)",
            "pxW": "\(composite.width)",
            "pxH": "\(composite.height)",
        ])
        // 成员 pin 窗体全部关闭（图像已烤入合成图）；先摘组再关窗，
        // 避免 close→remove 触发 dissolve 逻辑对残组的误处理
        let pins = members
        for pin in pins { memberships[ObjectIdentifier(pin)] = nil }
        groups[gid] = nil
        closePanel(gid)
        for pin in pins { pin.close() }
        // pxScale 透传（reviewer 补丁：多屏 pin 时 NSScreen.main 猜的 scale 会错
        // → 编辑器 ptSize/标注/马赛克整体错位；用烤图时的真实 scale）
        CollageEditorWindowController.present(composite: composite, pxScale: composited.pxScale)
    }
}

// MARK: - 几何小工具

private extension CGPoint {
    func offsetBy(_ size: CGSize) -> CGPoint {
        CGPoint(x: x + size.width, y: y + size.height)
    }
}
