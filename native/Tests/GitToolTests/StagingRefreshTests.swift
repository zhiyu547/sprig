// Copyright (c) 2026 zhiyu
// SPDX-License-Identifier: LicenseRef-Sprig-NC-SA-1.0

import XCTest
import AppKit
@testable import GitTool
@testable import GitCore

final class StagingRefreshTests: XCTestCase {
    @MainActor private func settle(_ window: NSWindow) async throws {
        try await Task.sleep(nanoseconds: 100_000_000)
        window.contentView?.layoutSubtreeIfNeeded()
    }
    @MainActor private func tables(in view: NSView) -> [NSTableView] {
        if let table = view as? NSTableView { return [table] }
        return view.subviews.flatMap { tables(in: $0) }
    }
    @MainActor private func pixels(_ view: NSView, rect: NSRect) throws -> Data {
        let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: rect))
        view.cacheDisplay(in: rect, to: image)
        return Data(bytes: try XCTUnwrap(image.bitmapData), count: image.bytesPerRow * image.pixelsHigh)
    }
    @MainActor func testDiffPixelsAndViewportSurvivePendingStagingRefresh() async throws {
        _ = NSApplication.shared
        let store = RepositoryStore(), root = URL(fileURLWithPath: "/tmp/sprig-pixel-fixture")
        store.snapshot = try StatusParser.parse(Data("? code.txt\0? other.txt\0".utf8), root: root, gitDirectory: root, commonDirectory: root)
        store.selectedPath = "code.txt"
        let document = DiffDocument.addedText((1...200).map { "Line \($0): unchanged visible code" }.joined(separator: "\n"), path: "code.txt")
        store.preview = DiffPreview(file: store.selected!, scope: .working, document: document)
        let window = WorkspaceWindow(store: store); window.isReleasedWhenClosed = false
        defer { window.close(); store.stop() }
        try await settle(window)
        let rootView = try XCTUnwrap(window.contentView)
        let beforeTables = tables(in: rootView), codeTable = try XCTUnwrap(beforeTables.last)
        let clip = try XCTUnwrap(codeTable.enclosingScrollView?.contentView)
        clip.scroll(to: NSPoint(x: 0, y: 230))
        try await settle(window)
        let position = clip.bounds.origin
        let area = codeTable.convert(NSRect(x: 70, y: position.y + 50, width: 220, height: 110), to: rootView)
        let before = try pixels(rootView, rect: area)
        XCTAssertGreaterThan(Set(before).count, 20, "The captured region must contain rendered code, not a blank surface")
        store.indexUpdatePaths = ["other.txt"]; store.busy = true; store.loadingDiff = true
        try await settle(window)
        XCTAssertFalse(store.blockingBusy)
        XCTAssertEqual(try pixels(rootView, rect: area), before, "Pending refresh must not hide or dim the code")
        XCTAssertTrue(tables(in: rootView).last === codeTable, "Keep the same native code table")
        XCTAssertEqual(clip.bounds.origin, position)
        // Moving the current diff from working to staged changes labels, not its pixels/viewport.
        store.scope = .staged
        store.preview = DiffPreview(file: store.selected!, scope: .staged, document: document)
        store.loadingDiff = false; store.busy = false; store.indexUpdatePaths = []
        try await settle(window)
        XCTAssertTrue(tables(in: rootView).last === codeTable)
        XCTAssertEqual(clip.bounds.origin, position)
        XCTAssertEqual(try pixels(rootView, rect: area), before)
    }

    private func git(_ root: URL, _ arguments: [String]) throws {
        let task = Process(), pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/git"); task.currentDirectoryURL = root
        task.arguments = ["-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false"] + arguments
        task.standardOutput = pipe; task.standardError = pipe
        try task.run(); let output = pipe.fileHandleForReading.readDataToEndOfFile(); task.waitUntilExit()
        if task.terminationStatus != 0 { throw GitError.message(String(decoding: output, as: UTF8.self)) }
    }
    @MainActor private func waitForDiff(_ store: RepositoryStore) async throws {
        let deadline = Date().addingTimeInterval(3)
        while store.loadingDiff, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(store.loadingDiff); XCTAssertNil(store.diffError)
    }
    @MainActor func testRealStageUnstageKeepPreviewUntilNewScopeIsReady() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sprig-staging-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = RepositoryStore()
        defer { store.stop(); try? FileManager.default.removeItem(at: root) }
        try git(root, ["init", "-b", "main"]); try git(root, ["config", "user.name", "Fixture"]); try git(root, ["config", "user.email", "fixture@example.invalid"])
        for name in ["first.txt", "other.txt"] { try Data("base\n".utf8).write(to: root.appendingPathComponent(name)) }
        try git(root, ["add", "."]); try git(root, ["commit", "-m", "base"])
        for name in ["first.txt", "other.txt"] { try Data("base\nchange\n".utf8).write(to: root.appendingPathComponent(name)) }
        let repo = try await GitRepository.open(root)
        store.repository = repo; store.snapshot = try await repo.snapshot()
        store.select(try XCTUnwrap(store.snapshot?.files.first { $0.path == "first.txt" }))
        try await waitForDiff(store); let initialPatch = store.document?.raw
        store.readDiff = { repo, file, scope in
            try await Task.sleep(nanoseconds: 250_000_000)
            return try await repo.diff(for: file, scope: scope)
        }
        // Updating a different checkbox leaves the displayed file and content intact.
        store.toggleStage(try XCTUnwrap(store.snapshot?.files.first { $0.path == "other.txt" }))
        XCTAssertTrue(store.busy); XCTAssertTrue(store.updatingIndex); XCTAssertFalse(store.blockingBusy)
        await store.operationTask?.value
        XCTAssertTrue(store.snapshot?.files.first { $0.path == "other.txt" }?.hasStaged == true)
        XCTAssertTrue(store.loadingDiff); XCTAssertEqual(store.document?.raw, initialPatch)
        XCTAssertEqual(store.previewScope, .working); XCTAssertNil(store.notice)
        try await waitForDiff(store)
        for staged in [true, false, true, false] {
            let oldScope = store.previewScope
            store.toggleStage(try XCTUnwrap(store.selected))
            await store.operationTask?.value
            XCTAssertEqual(store.selected?.hasStaged, staged)
            XCTAssertFalse(store.busy); XCTAssertFalse(store.updatingIndex)
            XCTAssertTrue(store.loadingDiff); XCTAssertEqual(store.previewScope, oldScope)
            XCTAssertEqual(store.document?.raw, initialPatch)
            try await waitForDiff(store)
            XCTAssertEqual(store.previewScope, staged ? .staged : .working)
            XCTAssertEqual(store.document?.raw, initialPatch)
            XCTAssertEqual(store.previewFile?.path, "first.txt")
        }
        // An index lock failure must not change the checkbox or discard the preview.
        try Data().write(to: root.appendingPathComponent(".git/index.lock"))
        store.toggleStage(try XCTUnwrap(store.selected)); await store.operationTask?.value
        XCTAssertNotNil(store.error); XCTAssertFalse(store.selected?.hasStaged ?? true)
        XCTAssertEqual(store.document?.raw, initialPatch); XCTAssertFalse(store.busy)
        try await waitForDiff(store)
        // Changing the selected file keeps the old title paired with the old content until ready.
        store.select(try XCTUnwrap(store.snapshot?.files.first { $0.path == "other.txt" }))
        XCTAssertEqual(store.previewFile?.path, "first.txt")
        try await waitForDiff(store)
        XCTAssertEqual(store.previewFile?.path, "other.txt")
    }
}
