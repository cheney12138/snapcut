import AppKit
import CoreGraphics

/// 贴图磁吸组注册表：live pins 的组关系唯一真相源。
///
/// - 统一视觉：每个 ≥2 张的拼贴组配一枚底层 `GroupBackdropPanel`（磨砂玻璃托盘）+
///   一枚顶部居中悬浮 `GroupBorderPanel`（[ ⊞ 已拼贴 · N 张 | 合并拼图 | 拆分 | × ]）；
/// - 拖底层磨砂托盘或顶栏胶囊 = 整组刚体 1:1 移动 + 松手滑入吸附。
@MainActor
final class PinMagnetRegistry {
    static let shared = PinMagnetRegistry()
    private init() {}

    // MARK: - 状态

    private var groups: [Int: [PinWindowController]] = [:]
    private var memberships: [ObjectIdentifier: Int] = [:]
    private var backdropPanels: [Int: GroupBackdropPanel] = [:]
    private var borderPanels: [Int: GroupBorderPanel] = [:]
    private var nextGroupID = 1

    /// 拖磨砂托盘或顶栏胶囊的整组刚体拖动
    private var borderDrag: BorderDragState?
    private struct BorderDragState {
        let groupID: Int
        let startCursor: CGPoint
        let startFrames: [ObjectIdentifier: CGRect]
        let startUnion: CGRect
        var snapOutcome: MagnetSnapOutcome?
        var snapPartner: PinWindowController?
    }

    // MARK: - pin 身份

    static func id(of pin: PinWindowController) -> String {
        String(describing: ObjectIdentifier(pin))
    }

    func pin(byID id: String) -> PinWindowController? {
        PinWindowController.livePins.first { Self.id(of: $0) == id }
    }

    // MARK: - 生命周期

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

    func groupMembers(of pin: PinWindowController) -> [PinWindowController] {
        guard let gid = groupID(for: pin) else { return [pin] }
        return groups[gid] ?? [pin]
    }

    /// 磁吸候选：除排除集合外的全部存活 pin（真实内容框，无虚拟垫偏移）
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
            items.append(MagnetSnapItem(id: Self.id(of: pin), frame: pin.windowFrame))
        }
        return items
    }

    // MARK: - 成组 / 拆组

    func union(_ a: PinWindowController, _ b: PinWindowController) {
        let ga = groupID(for: a)
        let gb = groupID(for: b)
        if let ga, ga == gb {
            refreshLayout(groupID: ga)
            return
        }
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
                closePanels(g)
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

    /// 单卡脱离所在组（组只剩 1 张时随之解散）
    func detach(_ pin: PinWindowController) {
        guard let gid = memberships[ObjectIdentifier(pin)] else { return }
        memberships[ObjectIdentifier(pin)] = nil
        pin.setInGroup(false)
        groups[gid]?.removeAll { $0 === pin }
        Log.event(.pin, "collage.group.detach", ["group": "\(gid)"])
        refreshLayout(groupID: gid)
    }

    // MARK: - 组磨砂托盘 + 顶栏布局

    func notifyLayoutChanged(_ pin: PinWindowController) {
        if let gid = groupID(for: pin) {
            refreshLayout(groupID: gid)
        }
    }

    /// 组内单卡被拖远时，柔化磨砂托盘与顶栏透明度，直觉提示「松手即移出组」
    func setDetachingPreview(groupID gid: Int, isDetaching: Bool) {
        let targetAlpha: CGFloat = isDetaching ? 0.36 : 1.0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            ctx.timingFunction = DesignTokens.Motion.easeOutStrong
            backdropPanels[gid]?.animator().alphaValue = targetAlpha
            borderPanels[gid]?.animator().alphaValue = targetAlpha
        }
    }

    func refreshLayout(groupID gid: Int, excluding excludedPin: PinWindowController? = nil) {
        guard let members = groups[gid], !members.isEmpty else {
            groups[gid] = nil
            closePanels(gid)
            return
        }
        guard members.count >= 2 else {
            dissolve(groupID: gid, members: members)
            return
        }
        for member in members { member.setInGroup(true) }

        let layoutMembers: [PinWindowController]
        if let excludedPin {
            let remaining = members.filter { $0 !== excludedPin }
            layoutMembers = remaining.count >= 2 ? remaining : members
        } else {
            layoutMembers = members
        }

        let union = MagnetGroup.unionRect(layoutMembers.map(\.windowFrame))

        let backdrop = backdropPanels[gid] ?? makeBackdropPanel(gid)
        backdrop.update(forUnion: union)
        backdrop.playEntranceIfNeeded()

        let topBar = borderPanels[gid] ?? makeBorderPanel(gid)
        topBar.refresh(count: members.count, union: union)
        topBar.playEntranceIfNeeded()
    }

    /// 一键拆分整组
    func dissolveGroup(groupID gid: Int) {
        guard let members = groups[gid] else { return }
        dissolve(groupID: gid, members: members)
    }

    /// 一键关闭整组内全部贴图（顶栏「×」按钮或 Esc）
    func closeGroup(groupID gid: Int) {
        guard let members = groups[gid] else { return }
        let snapshot = members
        closePanels(gid)
        groups[gid] = nil
        for member in snapshot {
            memberships[ObjectIdentifier(member)] = nil
            member.close()
        }
        Log.event(.pin, "collage.group.closeAll", ["group": "\(gid)", "count": "\(snapshot.count)"])
    }

    /// 全局隐藏或唤回所有拼贴组托盘与顶栏（Boss Key），严禁清空组状态与坐标
    func setAllGroupPanelsHidden(_ hidden: Bool) {
        if hidden {
            for panel in backdropPanels.values {
                panel.orderOut(nil)
            }
            for panel in borderPanels.values {
                panel.orderOut(nil)
            }
        } else {
            for panel in backdropPanels.values {
                panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
                panel.orderFrontRegardless()
            }
            for panel in borderPanels.values {
                panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
                panel.orderFrontRegardless()
            }
        }
    }

    /// 确保所有拼贴组顶栏严格位于贴图窗口之上
    func bringBorderPanelsToFront() {
        for panel in borderPanels.values {
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
            panel.orderFrontRegardless()
        }
    }

    private func dissolve(groupID gid: Int, members: [PinWindowController]) {
        for member in members {
            memberships[ObjectIdentifier(member)] = nil
            member.setInGroup(false)
        }
        groups[gid] = nil
        closePanels(gid)
        Log.event(.pin, "collage.group.dissolve", ["group": "\(gid)"])
    }

    private func closePanels(_ gid: Int) {
        backdropPanels[gid]?.dismissAnimated()
        backdropPanels[gid] = nil
        borderPanels[gid]?.dismissAnimated()
        borderPanels[gid] = nil
    }

    private func makeBackdropPanel(_ gid: Int) -> GroupBackdropPanel {
        let panel = GroupBackdropPanel(groupID: gid)
        panel.onDragBegin = { [weak self] in
            self?.beginBorderDrag(groupID: gid, at: NSEvent.mouseLocation)
        }
        panel.onDragMoved = { [weak self] in self?.borderDragMoved() }
        panel.onDragEnd = { [weak self] in self?.endBorderDrag() }
        panel.onCloseGroup = { [weak self] in self?.closeGroup(groupID: gid) }
        backdropPanels[gid] = panel
        return panel
    }

    private func makeBorderPanel(_ gid: Int) -> GroupBorderPanel {
        let panel = GroupBorderPanel(groupID: gid)
        panel.onAssemble = { [weak self] in self?.assemble(groupID: gid) }
        panel.onQuickCopy = { [weak self] in self?.quickCopyGroup(gid) }
        panel.onUngroup = { [weak self] in self?.dissolveGroup(groupID: gid) }
        panel.onCloseGroup = { [weak self] in self?.closeGroup(groupID: gid) }
        panel.onDragBegin = { [weak self] in
            self?.beginBorderDrag(groupID: gid, at: NSEvent.mouseLocation)
        }
        panel.onDragMoved = { [weak self] in self?.borderDragMoved() }
        panel.onDragEnd = { [weak self] in self?.endBorderDrag() }
        borderPanels[gid] = panel
        return panel
    }

    // MARK: - 拖磨砂托盘 / 顶栏胶囊 = 整组刚体 1:1 移动 + 松手滑入吸附

    private func beginBorderDrag(groupID gid: Int, at cursor: CGPoint) {
        guard borderDrag == nil, let members = groups[gid], members.count >= 2 else { return }
        SnapGlideAnimator.shared.cancel()
        var frames: [ObjectIdentifier: CGRect] = [:]
        for member in members { frames[ObjectIdentifier(member)] = member.windowFrame }
        borderDrag = BorderDragState(
            groupID: gid,
            startCursor: cursor,
            startFrames: frames,
            startUnion: MagnetGroup.unionRect(members.map(\.windowFrame)),
            snapOutcome: nil,
            snapPartner: nil
        )
    }

    func borderDragMoved() {
        guard var state = borderDrag, let members = groups[state.groupID] else { return }
        let cursor = NSEvent.mouseLocation
        let delta = CGSize(width: cursor.x - state.startCursor.x, height: cursor.y - state.startCursor.y)

        // 严格 1:1 跟随，零阻力死区
        for member in members {
            let start = state.startFrames[ObjectIdentifier(member)] ?? member.windowFrame
            member.setFrameOrigin(start.origin.offsetBy(delta))
        }

        let candidate = state.startUnion.offsetBy(dx: delta.width, dy: delta.height)
        let others = snapCandidates(excluding: members)
        if let outcome = MagnetGroup.previewSnap(candidate: candidate, others: others),
           let partner = pin(byID: outcome.partnerID) {
            if state.snapPartner !== partner {
                state.snapPartner?.contentView.setSnapGlow(false)
                partner.contentView.setSnapGlow(true)
            }
            state.snapOutcome = outcome
            state.snapPartner = partner
            SnapPreviewOverlay.shared.show(outcome: outcome)
        } else {
            state.snapPartner?.contentView.setSnapGlow(false)
            if state.snapOutcome != nil {
                SnapPreviewOverlay.shared.hide()
            }
            state.snapOutcome = nil
            state.snapPartner = nil
        }

        borderDrag = state
        refreshLayout(groupID: state.groupID)
    }

    func endBorderDrag() {
        guard let state = borderDrag else { return }
        borderDrag = nil
        SnapPreviewOverlay.shared.hide()
        state.snapPartner?.contentView.setSnapGlow(false)

        guard let outcome = state.snapOutcome,
              let partner = state.snapPartner,
              let members = groups[state.groupID],
              !members.isEmpty,
              PinWindowController.livePins.contains(where: { $0 === partner })
        else { return }

        Log.event(.pin, "collage.magnet.snap", [
            "edge": outcome.edge.rawValue,
            "align": outcome.alignKind?.rawValue ?? "free",
            "partner": Self.id(of: partner),
            "via": "tray",
        ])

        let currentUnion = MagnetGroup.unionRect(members.map(\.windowFrame))
        let delta = CGSize(
            width: outcome.frame.minX - currentUnion.minX,
            height: outcome.frame.minY - currentUnion.minY
        )
        let glideItems = members.map { m in
            let cur = m.windowFrame.origin
            return (m, cur, cur.offsetBy(delta))
        }
        let gid = state.groupID
        SnapGlideAnimator.shared.glide(
            items: glideItems,
            onStep: { [weak self] in
                self?.refreshLayout(groupID: gid)
            },
            onComplete: { [weak self, weak partner] in
                guard let self, let partner,
                      let leader = self.groups[gid]?.first,
                      PinWindowController.livePins.contains(where: { $0 === partner })
                else { return }
                self.union(leader, partner)
            }
        )
    }

    // MARK: - 合成整体（直接复制 / 合并进入标注编辑器）

    private func composeGroup(_ members: [PinWindowController], logFailureEvent: String) -> (image: CGImage, pxScale: CGFloat)? {
        let items = members.map { (image: $0.image, frame: $0.windowFrame) }
        guard let composited = PinAssembleEngine.compose(members: items) else {
            Log.error(.pin, logFailureEvent, ["reason": "compose"])
            return nil
        }
        return composited
    }

    private func quickCopyGroup(_ gid: Int) {
        guard let members = groups[gid], members.count >= 2,
              let composited = composeGroup(members, logFailureEvent: "collage.quickCopy.fail")
        else { return }
        let image = composited.image
        _ = AppCoordinatorShared.deps?.clipboard.writeImage(image) ?? ClipboardWriter.writeImage(image)
        AppCoordinatorShared.deps?.history.record(image)
        CaptureToast.show(
            image: image,
            message: "已复制拼图（\(members.count) 张）",
            onClick: {
                AppCoordinatorShared.coordinator?.openStandaloneEditor(image: image)
            }
        )
        Log.event(.pin, "collage.group.quickCopy", [
            "group": "\(gid)",
            "members": "\(members.count)",
        ])
    }

    func assemble(groupID gid: Int) {
        guard let members = groups[gid], members.count >= 2,
              let composited = composeGroup(members, logFailureEvent: "collage.assemble.fail")
        else { return }
        let composite = composited.image
        Log.event(.export, "collage.assemble", [
            "members": "\(members.count)",
            "pxW": "\(composite.width)",
            "pxH": "\(composite.height)",
        ])
        let union = MagnetGroup.unionRect(members.map(\.windowFrame))
        let canvasRect = union.insetBy(
            dx: -GroupBackdropPanel.matPadding,
            dy: -GroupBackdropPanel.matPadding
        )
        let targetScreen = NSScreen.screens.first { $0.frame.intersects(union) } ?? NSScreen.main

        let pins = members
        for pin in pins { memberships[ObjectIdentifier(pin)] = nil }
        groups[gid] = nil
        closePanels(gid)
        for pin in pins { pin.close() }

        // 直接进入一体化无边框 Apple 编辑器（原位无缝衔接 + 底部 Liquid Glass 悬浮工具栏），
        // 彻底替代旧版带黑标题栏与红绿灯的 CollageEditorWindowController
        if let coordinator = AppCoordinatorShared.coordinator {
            coordinator.openStandaloneEditor(
                image: composite,
                preferredScreen: targetScreen,
                preferredRect: canvasRect
            )
        } else {
            CollageEditorWindowController.present(composite: composite, pxScale: composited.pxScale)
        }
    }
}

private extension CGPoint {
    func offsetBy(_ size: CGSize) -> CGPoint {
        CGPoint(x: x + size.width, y: y + size.height)
    }
}
