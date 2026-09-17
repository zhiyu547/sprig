// Copyright (c) 2026 zhiyu
// SPDX-License-Identifier: LicenseRef-Sprig-NC-SA-1.0

import AppKit
import SwiftUI

struct CommitSplitView<Files: View, Editor: View>: NSViewRepresentable {
    let files: Files
    let editor: Editor

    init(@ViewBuilder files: () -> Files, @ViewBuilder editor: () -> Editor) {
        self.files = files(); self.editor = editor()
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CommitWorkspaceSplitView<Files, Editor>, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 340, height: proposal.height ?? 560)
    }
    func makeNSView(context: Context) -> CommitWorkspaceSplitView<Files, Editor> {
        CommitWorkspaceSplitView(files: files, editor: editor)
    }
    func updateNSView(_ view: CommitWorkspaceSplitView<Files, Editor>, context: Context) {
        view.files.rootView = files; view.editor.rootView = editor
    }
}

/// Keep the editor's chosen height when the window or repository content changes.
final class CommitWorkspaceSplitView<Files: View, Editor: View>: NSSplitView, NSSplitViewDelegate {
    static var defaultEditorHeight: CGFloat { 320 }
    static var minimumEditorHeight: CGFloat { 260 }
    static var minimumFilesHeight: CGFloat { 200 }
    static var preferenceKey: String { "Sprig.commitPanelHeight" }

    let files: NSHostingView<Files>
    let editor: NSHostingView<Editor>
    private let preferences: UserDefaults
    private var preferredEditorHeight: CGFloat
    private var layingOut = false
    private var resizingFrame = false

    init(files: Files, editor: Editor, preferences: UserDefaults = .standard) {
        self.files = NSHostingView(rootView: files)
        self.editor = NSHostingView(rootView: editor)
        self.preferences = preferences
        let saved = preferences.double(forKey: Self.preferenceKey)
        preferredEditorHeight = saved.isFinite && saved >= Self.minimumEditorHeight ? saved : Self.defaultEditorHeight
        super.init(frame: .zero)
        self.files.sizingOptions = []; self.editor.sizingOptions = []
        isVertical = false; dividerStyle = .thin; delegate = self
        addSubview(self.files); addSubview(self.editor)
        setAccessibilityLabel("上下拖动调整文件列表与提交区域高度，双击恢复默认")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override var isFlipped: Bool { true }
    override var dividerColor: NSColor { NSColor.white.withAlphaComponent(0.10) }

    private var usableHeight: CGFloat { max(0, bounds.height - dividerThickness) }
    private var minimumTopHeight: CGFloat { min(Self.minimumFilesHeight, max(0, usableHeight - Self.minimumEditorHeight)) }
    private var maximumTopHeight: CGFloat { max(0, usableHeight - Self.minimumEditorHeight) }

    override func setFrameSize(_ newSize: NSSize) {
        // AppKit posts a resize notification after resizeSubviews has returned too.
        // Temporary window constraints must not overwrite the user's chosen height.
        let wasResizing = resizingFrame
        resizingFrame = true
        super.setFrameSize(newSize)
        resizingFrame = wasResizing
    }
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        guard !layingOut else { return }
        layingOut = true; defer { layingOut = false }
        super.resizeSubviews(withOldSize: oldSize)
        positionDivider()
    }
    private func positionDivider() {
        guard bounds.height > 0 else { return }
        let top = min(max(minimumTopHeight, usableHeight - preferredEditorHeight), maximumTopHeight)
        setPosition(top, ofDividerAt: 0)
    }
    func resetEditorHeight() {
        preferredEditorHeight = Self.defaultEditorHeight
        layingOut = true; positionDivider(); layingOut = false
        preferences.set(preferredEditorHeight, forKey: Self.preferenceKey)
    }
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { minimumTopHeight }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { maximumTopHeight }
    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }
    func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect, forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int) -> NSRect {
        proposedEffectiveRect.insetBy(dx: 0, dy: -4)
    }
    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard !layingOut, !resizingFrame, usableHeight >= Self.minimumFilesHeight + Self.minimumEditorHeight else { return }
        preferredEditorHeight = max(Self.minimumEditorHeight, editor.frame.height)
        preferences.set(preferredEditorHeight, forKey: Self.preferenceKey)
    }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2, abs(point.y - files.frame.maxY) < 7 {
            resetEditorHeight()
        } else { super.mouseDown(with: event) }
    }
}
