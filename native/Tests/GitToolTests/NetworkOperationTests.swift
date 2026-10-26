// Copyright (c) 2026 zhiyu
// SPDX-License-Identifier: LicenseRef-Sprig-NC-SA-1.0

import XCTest
import AppKit
@testable import GitTool
@testable import GitCore

final class NetworkOperationTests: XCTestCase {
    @MainActor func testCancellationKeepsWritesSerializedAndIgnoresLateProgress() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sprig-network-ui-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await CommandRunner().run(["init", "-b", "main"], at: root)
        let store = RepositoryStore(); store.repository = try await GitRepository.open(root)
        defer { store.stop() }
        store.commitMessage = "existing draft"; store.pendingPushOID = "local-commit"
        store.runNetworkOperation("推送") { _, operation in
            operation.progress("上传对象 · 25% · 8.00 MiB · 1.25 MiB/s")
            while !operation.isCancelled { try await Task.sleep(nanoseconds: 10_000_000) }
            // Cleanup remains in flight after the cancellation request.
            try await Task.sleep(nanoseconds: 150_000_000)
            throw CancellationError()
        }
        let operation = try XCTUnwrap(store.networkOperation), task = try XCTUnwrap(store.operationTask)
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertTrue(store.networkProgress.contains("25%")); XCTAssertTrue(store.busy)
        store.cancelNetworkOperation()
        XCTAssertTrue(operation.isCancelled); XCTAssertTrue(store.busy); XCTAssertTrue(store.networkCancelling)
        XCTAssertFalse(task.isCancelled, "Local restoration must not be cancelled with the transport")
        var secondWriteStarted = false
        store.runOperation("another write") { _ in secondWriteStarted = true; return "unexpected" }
        XCTAssertFalse(secondWriteStarted)
        await task.value
        XCTAssertFalse(store.busy); XCTAssertNil(store.networkOperation); XCTAssertNil(store.networkStartedAt)
        XCTAssertEqual(store.commitMessage, "existing draft"); XCTAssertEqual(store.pendingPushOID, "local-commit")
        XCTAssertTrue(store.notice?.contains("已取消") == true)
        XCTAssertTrue(store.notice?.contains("远端") == true)
        operation.progress("late progress must be ignored")
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(store.networkProgress, "")
    }
    @MainActor func testNetworkFooterFitsMinimumWindowAndKeepsCancelVisible() async throws {
        _ = NSApplication.shared
        let store = RepositoryStore(), root = URL(fileURLWithPath: "/tmp/sprig-network-layout")
        store.snapshot = try StatusParser.parse(Data("? service.swift\0".utf8), root: root, gitDirectory: root, commonDirectory: root)
        store.selectedPath = "service.swift"
        store.preview = DiffPreview(file: store.selected!, scope: .working, document: .addedText("let ready = true\n", path: "service.swift"))
        store.commitMessage = "feat: upload project files"
        store.busy = true; store.busyTitle = "推送到 origin/main"
        store.networkStartedAt = Date().addingTimeInterval(-241)
        store.networkProgress = "上传对象 · 63% · 315.00 MiB · 1.25 MiB/s"
        store.networkCanCancel = true; store.networkOperation = GitNetworkOperation()
        let window = WorkspaceWindow(store: store); window.isReleasedWhenClosed = false
        defer { window.close(); store.stop() }
        window.setContentSize(NSSize(width: 940, height: 680))
        try await Task.sleep(nanoseconds: 100_000_000)
        let content = try XCTUnwrap(window.contentView); content.layoutSubtreeIfNeeded()
        let originalFrame = window.frame
        func capture(_ name: String) throws {
            guard let path = ProcessInfo.processInfo.environment["SPRIG_UI_SNAPSHOT_DIR"] else { return }
            let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: bitmap)
            let bytes = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try bytes.write(to: URL(fileURLWithPath: path).appendingPathComponent(name))
        }
        try capture("push-progress.png")
        store.cancelNetworkOperation()
        try await Task.sleep(nanoseconds: 80_000_000); content.layoutSubtreeIfNeeded()
        XCTAssertEqual(window.frame, originalFrame)
        XCTAssertTrue(store.busy); XCTAssertTrue(store.networkCancelling)
        try capture("push-cancelling.png")
    }

}
