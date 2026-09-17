// Copyright (c) 2026 zhiyu
// SPDX-License-Identifier: LicenseRef-Sprig-NC-SA-1.0

import SwiftUI
import AppKit

struct NativeSplitView<Left: View, Right: View>: NSViewRepresentable {
    let left: Left
    let right: Right
    init(@ViewBuilder left: () -> Left, @ViewBuilder right: () -> Right) { self.left = left(); self.right = right() }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WorkspaceSplitView<Left, Right>, context: Context) -> CGSize? {
        // Long diff lines and drafts must not enlarge the workspace.
        CGSize(width: proposal.width ?? 940, height: proposal.height ?? 560)
    }
    func makeNSView(context: Context) -> WorkspaceSplitView<Left, Right> { WorkspaceSplitView(left: left, right: right) }
    func updateNSView(_ view: WorkspaceSplitView<Left, Right>, context: Context) { view.left.rootView = left; view.right.rootView = right }
}

/// A plain AppKit split view owns its frames. SwiftUI supplies the panel content.
final class WorkspaceSplitView<Left: View, Right: View>: NSSplitView, NSSplitViewDelegate {
    let left: NSHostingView<Left>
    let right: NSHostingView<Right>
    private var sidebarWidth: CGFloat
    private var layingOut = false

    init(left: Left, right: Right) {
        self.left = NSHostingView(rootView: left); self.right = NSHostingView(rootView: right)
        let saved = UserDefaults.standard.double(forKey: "GitTool.sidebarWidth")
        sidebarWidth = saved > 0 ? saved : 340
        super.init(frame: .zero)
        self.left.sizingOptions = []; self.right.sizingOptions = []
        isVertical = true; dividerStyle = .thin; delegate = self
        addSubview(self.left); addSubview(self.right)
        setAccessibilityLabel("调整文件列表与代码区域宽度")
        NotificationCenter.default.addObserver(self, selector: #selector(adjustWidth(_:)), name: .gitToolAdjustSidebar, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func adjustWidth(_ notification: Notification) {
        guard let delta = notification.object as? Double else { return }
        sidebarWidth = delta == 0 ? 340 : min(max(280, left.frame.width + delta), maximumSidebarWidth)
        layoutPanels(); UserDefaults.standard.set(sidebarWidth, forKey: "GitTool.sidebarWidth")
    }

    private var maximumSidebarWidth: CGFloat { max(280, min(640, bounds.width - dividerThickness - 480)) }
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        guard !layingOut else { return }
        layingOut = true
        super.resizeSubviews(withOldSize: oldSize)
        if bounds.width > 0 { setPosition(min(max(280, sidebarWidth), maximumSidebarWidth), ofDividerAt: 0) }
        layingOut = false
    }
    private func layoutPanels() {
        guard bounds.width > 0, !layingOut else { return }
        layingOut = true; defer { layingOut = false }
        let width = min(max(280, sidebarWidth), maximumSidebarWidth)
        setPosition(width, ofDividerAt: 0)
        needsDisplay = true
    }
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { 280 }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { maximumSidebarWidth }
    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }
    func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect, forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int) -> NSRect {
        proposedEffectiveRect.insetBy(dx: -4, dy: 0)
    }
    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard !layingOut, left.frame.width >= 280 else { return }
        sidebarWidth = left.frame.width
        UserDefaults.standard.set(sidebarWidth, forKey: "GitTool.sidebarWidth")
    }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2, abs(point.x - left.frame.maxX) < 7 {
            sidebarWidth = 340; layoutPanels()
            UserDefaults.standard.set(sidebarWidth, forKey: "GitTool.sidebarWidth")
        } else { super.mouseDown(with: event) }
    }
}

extension Notification.Name {
    static let gitToolAdjustSidebar = Notification.Name("GitTool.adjustSidebar")
}
