// Copyright (c) 2026 zhiyu
// SPDX-License-Identifier: LicenseRef-Sprig-NC-SA-1.0

import XCTest
import AppKit
import SwiftUI
@testable import GitTool
@testable import GitCore

final class WorkspaceTests: XCTestCase {
    @MainActor func testSelectionLoadingAndNoticesDoNotMoveWorkspace() async throws {
        _ = NSApplication.shared
        let store = RepositoryStore(), root = URL(fileURLWithPath: "/tmp/sprig-layout-fixture")
        store.snapshot = try StatusParser.parse(Data("? short.txt\0? very-long-file-name-for-layout-regression.txt\0".utf8), root: root, gitDirectory: root, commonDirectory: root)
        store.selectedPath = "short.txt"
        store.preview = DiffPreview(file: store.selected!, scope: .working, document: .addedText("short\n", path: "short.txt"))
        let window = WorkspaceWindow(store: store); window.isReleasedWhenClosed = false
        defer { window.close(); store.stop() }
        window.setContentSize(NSSize(width: 1000, height: 720))
        func settle() async throws { try await Task.sleep(nanoseconds: 80_000_000); window.contentView?.layoutSubtreeIfNeeded() }
        func findSplit(_ view: NSView) -> NSSplitView? {
            if let split = view as? NSSplitView { return split }
            return view.subviews.compactMap { findSplit($0) }.first
        }
        func findCommitSplit(_ view: NSView) -> NSSplitView? {
            if let split = view as? NSSplitView, !split.isVertical { return split }
            return view.subviews.compactMap { findCommitSplit($0) }.first
        }
        try await settle()
        let split = try XCTUnwrap(findSplit(try XCTUnwrap(window.contentView)))
        let commitSplit = try XCTUnwrap(findCommitSplit(split))
        let editorHeight = commitSplit.subviews[1].frame.height
        let windowFrame = window.frame, splitFrame = split.convert(split.bounds, to: nil), sidebarWidth = split.subviews[0].frame.width
        func unchanged() {
            XCTAssertEqual(window.frame, windowFrame)
            XCTAssertEqual(split.convert(split.bounds, to: nil), splitFrame)
            XCTAssertEqual(split.subviews[0].frame.width, sidebarWidth, accuracy: 0.5)
            XCTAssertEqual(commitSplit.subviews[1].frame.height, editorHeight, accuracy: 0.5)
        }
        store.notice = "已暂存 1 个文件"; try await settle(); unchanged()
        store.notice = nil; store.loadingDiff = true; store.selectedPath = "very-long-file-name-for-layout-regression.txt"
        try await settle(); unchanged()
        store.preview = DiffPreview(file: store.selected!, scope: .working, document: .addedText(String(repeating: "long code ", count: 1000), path: store.selectedPath!))
        store.loadingDiff = false; store.commitMessage = String(repeating: "详细提交说明\n", count: 100)
        try await settle(); unchanged()
        store.error = String(repeating: "接口等待失败，请重试。", count: 40); try await settle(); unchanged()
        store.error = nil; store.preview = DiffPreview(file: store.selected!, scope: .working, document: .notice("二进制文件", path: store.selectedPath!)); try await settle(); unchanged()
    }
    @MainActor func testCommitPanelHeightPersistsAndRecoversAfterWindowShrink() throws {
        _ = NSApplication.shared
        let suite = "Sprig.CommitSplitTests." + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        typealias Split = CommitWorkspaceSplitView<Text, Text>
        let split = Split(files: Text("Files"), editor: Text("Draft"), preferences: preferences)
        split.setFrameSize(NSSize(width: 340, height: 700))
        XCTAssertEqual(split.editor.frame.height, 320, accuracy: 0.5)

        // AppKit applies the same divider movement for a drag; bottom height is saved.
        split.setPosition(700 - split.dividerThickness - 390, ofDividerAt: 0)
        XCTAssertEqual(split.editor.frame.height, 390, accuracy: 0.5)
        XCTAssertEqual(preferences.double(forKey: Split.preferenceKey), 390, accuracy: 0.5)

        split.setFrameSize(NSSize(width: 280, height: 500))
        XCTAssertGreaterThanOrEqual(split.files.frame.height, 200)
        XCTAssertGreaterThanOrEqual(split.editor.frame.height, 260)
        XCTAssertEqual(split.files.frame.height + split.editor.frame.height + split.dividerThickness, 500, accuracy: 0.5)
        XCTAssertEqual(preferences.double(forKey: Split.preferenceKey), 390, accuracy: 0.5)
        split.setFrameSize(NSSize(width: 340, height: 700))
        XCTAssertEqual(split.editor.frame.height, 390, accuracy: 0.5)

        let reopened = Split(files: Text("Files"), editor: Text("Draft"), preferences: preferences)
        reopened.setFrameSize(NSSize(width: 340, height: 700))
        XCTAssertEqual(reopened.editor.frame.height, 390, accuracy: 0.5)
        reopened.resetEditorHeight()
        XCTAssertEqual(reopened.editor.frame.height, 320, accuracy: 0.5)
        XCTAssertEqual(preferences.double(forKey: Split.preferenceKey), 320, accuracy: 0.5)
    }
    @MainActor func testCancelRestoresControlsAndPreservesDraftImmediately() {
        let store = RepositoryStore(); store.commitMessage = "existing draft"
        store.busy = true; store.aiStartedAt = Date(); let oldID = store.aiRequestID
        store.operationTask = Task { try? await Task.sleep(nanoseconds: 10_000_000_000) }
        store.cancelAI()
        XCTAssertFalse(store.busy); XCTAssertNil(store.aiStartedAt); XCTAssertNil(store.operationTask)
        XCTAssertNotEqual(store.aiRequestID, oldID); XCTAssertEqual(store.commitMessage, "existing draft")
        XCTAssertNil(store.sheet)
    }
}
