// Copyright (c) 2026 zhiyu
// SPDX-License-Identifier: LicenseRef-Sprig-NC-SA-1.0

import XCTest
@testable import GitTool
@testable import GitCore

final class RefreshTests: XCTestCase {
    private func git(_ root: URL, _ arguments: [String]) throws {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.currentDirectoryURL = root
        process.arguments = ["-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false"] + arguments
        process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw GitError.message(String(decoding: output, as: UTF8.self)) }
    }

    @MainActor private func waitForRead(_ store: RepositoryStore) async throws {
        let deadline = Date().addingTimeInterval(5)
        while (store.refreshing || store.loadingDiff || store.manualRefreshState == .refreshing), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(store.refreshing); XCTAssertFalse(store.loadingDiff)
        XCTAssertNil(store.error); XCTAssertNil(store.diffError)
    }

    @MainActor func testManualRefreshReadsExternalChangesWithoutFileWatcher() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sprig-refresh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = RepositoryStore()
        defer { store.stop(); try? FileManager.default.removeItem(at: root) }
        func write(_ path: String, _ text: String) throws { try Data(text.utf8).write(to: root.appendingPathComponent(path)) }
        try git(root, ["init", "-b", "main"])
        try git(root, ["config", "user.name", "Refresh Test"]); try git(root, ["config", "user.email", "refresh@example.invalid"])
        try write("tracked.txt", "base\n"); try write("removed.txt", "remove me\n")
        try git(root, ["add", "."]); try git(root, ["commit", "-m", "base"])
        try write("tracked.txt", "before refresh\n")
        // Assign directly: open() would install a watcher and could mask a broken manual refresh.
        let repo = try await GitRepository.open(root)
        store.commitMessage = "Keep my draft"
        store.repository = repo; store.snapshot = try await repo.snapshot()
        store.select(try XCTUnwrap(store.snapshot?.files.first))
        try await waitForRead(store)
        XCTAssertFalse(store.watching)
        XCTAssertTrue(store.document?.raw.contains("+before refresh") == true)

        try write("tracked.txt", "after manual refresh\n")
        try write("new.txt", "new file\n")
        try FileManager.default.removeItem(at: root.appendingPathComponent("removed.txt"))
        try git(root, ["add", "tracked.txt"])
        try git(root, ["checkout", "-b", "feature/refresh"])
        XCTAssertEqual(store.snapshot?.files.count, 1)
        XCTAssertEqual(store.snapshot?.branch, "main")
        XCTAssertTrue(store.document?.raw.contains("+before refresh") == true)

        store.manualRefresh()
        try await waitForRead(store)
        XCTAssertNotNil(store.updatedAt)
        XCTAssertEqual(store.snapshot?.branch, "feature/refresh")
        XCTAssertEqual(store.snapshot?.files.map(\.path), ["new.txt", "removed.txt", "tracked.txt"])
        XCTAssertEqual(store.newFiles.map(\.path), ["new.txt"])
        XCTAssertEqual(store.snapshot?.stagedCount, 1)
        XCTAssertEqual(store.selectedPath, "tracked.txt")
        XCTAssertEqual(store.previewScope, .staged)
        XCTAssertTrue(store.document?.raw.contains("+after manual refresh") == true)
        XCTAssertEqual(store.commitMessage, "Keep my draft")
        guard case .updated = store.manualRefreshState else { return XCTFail("Manual refresh must acknowledge a completed read") }
        let acknowledgement = store.manualRefreshState
        store.refresh()
        try await waitForRead(store)
        XCTAssertEqual(store.manualRefreshState, acknowledgement, "Background reads must not replace manual feedback")

        // A manual click during an existing scan must wait for the follow-up read.
        store.refresh(); store.manualRefresh()
        XCTAssertEqual(store.manualRefreshState, .refreshing)
        try await waitForRead(store)
        guard case .updated = store.manualRefreshState else { return XCTFail("Queued manual refresh did not complete") }
        XCTAssertNotEqual(store.manualRefreshState, acknowledgement)

        store.manualRefresh(); store.cancelRead()
        XCTAssertEqual(store.manualRefreshState, .idle)

        try FileManager.default.removeItem(at: root.appendingPathComponent(".git"))
        store.manualRefresh()
        let deadline = Date().addingTimeInterval(5)
        while store.refreshing, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(store.refreshing)
        XCTAssertEqual(store.manualRefreshState, .failed)
        XCTAssertNotNil(store.error)
        XCTAssertEqual(store.snapshot?.branch, "feature/refresh", "Failure must retain the last successful snapshot")
    }
}
