// Copyright (c) 2026 zhiyu
// SPDX-License-Identifier: LicenseRef-Sprig-NC-SA-1.0

import SwiftUI
import AppKit
import GitCore

final class ScrollSynchronizer {
    private var clips: [String: NSClipView] = [:]
    private var observers: [String: NSObjectProtocol] = [:]
    private var synchronizing = false
    func register(_ clip: NSClipView, key: String) {
        unregister(key)
        clips[key] = clip; clip.postsBoundsChangedNotifications = true
        observers[key] = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in self?.sync(from: key) }
    }
    func unregister(_ key: String) { if let observer = observers.removeValue(forKey: key) { NotificationCenter.default.removeObserver(observer) }; clips.removeValue(forKey: key) }
    private func sync(from key: String) {
        guard !synchronizing, let source = clips[key] else { return }
        synchronizing = true; defer { synchronizing = false }
        for (otherKey, clip) in clips where otherKey != key {
            let point = NSPoint(x: clip.bounds.origin.x, y: source.bounds.origin.y)
            if abs(clip.bounds.origin.y - point.y) > 0.5 { clip.scroll(to: point); clip.enclosingScrollView?.reflectScrolledClipView(clip) }
        }
    }
    deinit { for observer in observers.values { NotificationCenter.default.removeObserver(observer) } }
}

struct DiffTable: NSViewRepresentable {
    let lines: [DiffLine?]
    let side: String
    let synchronizer: ScrollSynchronizer
    let identity: String
    let revision: String
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(), table = NSTableView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true
        scroll.backgroundColor = Palette.codeNS; scroll.drawsBackground = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("code"))
        column.minWidth = 100; column.maxWidth = 30_000; column.resizingMask = .autoresizingMask
        table.addTableColumn(column); table.headerView = nil; table.rowHeight = 23; table.intercellSpacing = .zero
        table.backgroundColor = Palette.codeNS; table.selectionHighlightStyle = .none
        table.delegate = context.coordinator; table.dataSource = context.coordinator
        table.columnAutoresizingStyle = .noColumnAutoresizing
        scroll.documentView = table; context.coordinator.table = table
        context.coordinator.synchronizer = synchronizer; context.coordinator.side = side
        synchronizer.register(scroll.contentView, key: side)
        context.coordinator.resizeObserver = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scroll.contentView, queue: .main) { [weak coordinator = context.coordinator] _ in coordinator?.resize() }
        context.coordinator.hunkObserver = NotificationCenter.default.addObserver(forName: .sprigNavigateHunk, object: nil, queue: .main) { [weak coordinator = context.coordinator] note in coordinator?.navigateHunk(note.object as? Int ?? 1) }
        scroll.contentView.postsFrameChangedNotifications = true
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        let changedFile = coordinator.identity != identity
        guard changedFile || coordinator.revision != revision else { coordinator.resize(); return }
        let position = scroll.contentView.bounds.origin
        coordinator.identity = identity; coordinator.revision = revision; coordinator.lines = lines; coordinator.side = side
        coordinator.longest = min(20_000, CGFloat(lines.compactMap { $0?.text.count }.max() ?? 0) * 8 + 96)
        coordinator.resize(); coordinator.table?.reloadData()
        let next = changedFile ? NSPoint.zero : NSPoint(
            x: min(position.x, max(0, (coordinator.table?.bounds.width ?? 0) - scroll.contentSize.width)),
            y: min(position.y, max(0, (coordinator.table?.bounds.height ?? 0) - scroll.contentSize.height)))
        scroll.contentView.scroll(to: next); scroll.reflectScrolledClipView(scroll.contentView)
    }
    static func dismantleNSView(_ view: NSScrollView, coordinator: Coordinator) { coordinator.synchronizer?.unregister(coordinator.side) }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var lines: [DiffLine?] = [], side = "", identity = "", revision = "", longest: CGFloat = 0
        weak var table: NSTableView?
        weak var synchronizer: ScrollSynchronizer?
        var resizeObserver: NSObjectProtocol?
        var hunkObserver: NSObjectProtocol?
        private var resizing = false
        func navigateHunk(_ direction: Int) {
            guard side != "right", let table, let scroll = table.enclosingScrollView, table.window != nil else { return }
            let top = Int(scroll.contentView.bounds.minY / 23)
            let hunks = lines.indices.filter { lines[$0]?.kind == .hunk }
            let target = direction > 0 ? hunks.first(where: { $0 > top }) : hunks.last(where: { $0 < top })
            guard let target else { return }
            let y = min(CGFloat(target) * 23, max(0, table.bounds.height - scroll.contentSize.height))
            scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: y)); scroll.reflectScrolledClipView(scroll.contentView)
        }
        func numberOfRows(in tableView: NSTableView) -> Int { lines.count }
        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let id = NSUserInterfaceItemIdentifier("line")
            let cell = tableView.makeView(withIdentifier: id, owner: nil) as? CodeCell ?? CodeCell()
            cell.identifier = id; cell.line = lines[row]; cell.side = side; cell.needsDisplay = true
            cell.setAccessibilityElement(true); cell.setAccessibilityRole(.staticText)
            if let line = lines[row] {
                let number = side == "left" ? line.old : line.new ?? line.old
                cell.setAccessibilityValue((number.map { "\($0) " } ?? "") + line.text)
            } else { cell.setAccessibilityValue("空行") }
            return cell
        }
        func resize() {
            guard !resizing, let table, let scroll = table.enclosingScrollView else { return }
            resizing = true; defer { resizing = false }
            let width = max(scroll.contentSize.width, longest)
            if let column = table.tableColumns.first, abs(column.width - width) > 0.5 { column.width = width }
            let size = NSSize(width: width, height: max(scroll.contentSize.height, CGFloat(lines.count) * 23))
            if table.frame.size != size { table.setFrameSize(size) }
        }
        deinit { if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }; if let hunkObserver { NotificationCenter.default.removeObserver(hunkObserver) } }
    }
}

private final class CodeCell: NSView {
    var line: DiffLine?
    var side = ""
    override var isFlipped: Bool { true }
    private static let codeFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private static let keyword = try! NSRegularExpression(pattern: "\\b(public|private|class|final|return|if|else|func|let|var|import|void|null|true|false|const|function|new)\\b|//.*$|#[^\\n]*$|\"[^\"]*\"")
    override func draw(_ dirtyRect: NSRect) {
        let background: NSColor
        switch line?.kind { case .addition: background = NSColor(srgbRed: 0.09, green: 0.22, blue: 0.16, alpha: 1); case .deletion: background = NSColor(srgbRed: 0.23, green: 0.13, blue: 0.15, alpha: 1); case .hunk: background = NSColor(srgbRed: 0.14, green: 0.17, blue: 0.21, alpha: 1); default: background = Palette.codeNS }
        background.setFill(); bounds.fill()
        guard let line else { return }
        let number = side == "left" ? line.old : line.new ?? line.old
        if let number {
            let text = "\(number)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: Self.codeFont, .foregroundColor: NSColor.secondaryLabelColor]
            text.draw(at: NSPoint(x: 46 - text.size(withAttributes: attributes).width, y: 3), withAttributes: attributes)
        }
        let sign = line.kind == .addition ? "+" : line.kind == .deletion ? "−" : ""
        (sign as NSString).draw(at: NSPoint(x: 55, y: 3), withAttributes: [.font: Self.codeFont, .foregroundColor: NSColor.secondaryLabelColor])
        let display = line.text.replacingOccurrences(of: "\t", with: "    ")
        let string = NSMutableAttributedString(string: display, attributes: [.font: Self.codeFont, .foregroundColor: line.kind == .hunk || line.kind == .note ? NSColor.secondaryLabelColor : NSColor(srgbRed: 0.78, green: 0.83, blue: 0.90, alpha: 1)])
        if line.kind != .hunk && line.kind != .note {
            let range = NSRange(location: 0, length: string.length)
            for match in Self.keyword.matches(in: display, range: range) {
                let token = (display as NSString).substring(with: match.range)
                let color: NSColor = token.hasPrefix("//") || token.hasPrefix("#") ? .secondaryLabelColor : token.hasPrefix("\"") ? .systemGreen : .systemBlue
                string.addAttribute(.foregroundColor, value: color, range: match.range)
            }
        }
        string.draw(at: NSPoint(x: line.kind == .hunk || line.kind == .note ? 12 : 76, y: 3))
    }
}
