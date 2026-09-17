// Copyright (c) 2026 zhiyu
// SPDX-License-Identifier: LicenseRef-Sprig-NC-SA-1.0

import XCTest
@testable import GitCore

final class RepositoryTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("git-tool-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git("init", "-b", "main")
        try git("config", "user.name", "Git Tool Test")
        try git("config", "user.email", "test@example.invalid")
        try git("config", "commit.gpgsign", "false")
        try git("config", "core.autocrlf", "false")
    }
    override func tearDownWithError() throws { if let root { try FileManager.default.removeItem(at: root) } }
    private func write(_ path: String, _ content: String) throws { try Data(content.utf8).write(to: root.appendingPathComponent(path)) }
    @discardableResult private func git(_ args: String..., accepted: Set<Int32> = [0]) throws -> String { try command(args, accepted: accepted) }
    @discardableResult private func command(_ args: [String], accepted: Set<Int32> = [0]) throws -> String {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git"); process.currentDirectoryURL = root
        process.arguments = ["-c", "core.hooksPath=/dev/null"] + args
        process.standardOutput = pipe; process.standardError = pipe
        try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard accepted.contains(process.terminationStatus) else { throw GitError.message(text) }
        return text
    }
    private func initialCommit() throws { try git("add", "."); try git("commit", "-m", "fixture") }

    func testPartialStagingAndReadOnlyIndex() async throws {
        try write("service.txt", "baseline\n"); try initialCommit()
        try write("service.txt", "baseline\nselected change\n"); try git("add", "service.txt")
        try write("service.txt", "baseline\nselected change\nremaining change\n")
        let indexURL = root.appendingPathComponent(".git/index"), before = try Data(contentsOf: indexURL)
        let repo = try await GitRepository.open(root), snapshot = try await repo.snapshot()
        let file = try XCTUnwrap(snapshot.files.first)
        XCTAssertTrue(file.hasStaged && file.hasWorking)
        let staged = try await repo.diff(for: file, scope: .staged), working = try await repo.diff(for: file, scope: .working)
        XCTAssertTrue(staged.raw.contains("+selected change")); XCTAssertFalse(staged.raw.contains("remaining change"))
        XCTAssertTrue(working.raw.contains("+remaining change")); XCTAssertFalse(working.raw.contains("+selected change"))
        XCTAssertEqual(before, try Data(contentsOf: indexURL)); XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("service.txt")), "baseline\nselected change\nremaining change\n")
    }

    func testUnbornRepositoryUntrackedAndBinary() async throws {
        try write("新 文件.txt", "你好\n")
        try Data([0, 1, 2, 3]).write(to: root.appendingPathComponent("image.bin"))
        let repo = try await GitRepository.open(root), snapshot = try await repo.snapshot()
        XCTAssertEqual(snapshot.branch, "main"); XCTAssertEqual(snapshot.head, "(initial)")
        XCTAssertEqual(snapshot.files.count, 2)
        let text = try XCTUnwrap(snapshot.files.first { $0.path == "新 文件.txt" })
        let textDiff = try await repo.diff(for: text, scope: .working)
        XCTAssertEqual(textDiff.additions, 1)
        let binary = try XCTUnwrap(snapshot.files.first { $0.path == "image.bin" })
        let binaryDiff = try await repo.diff(for: binary, scope: .working)
        XCTAssertTrue(binaryDiff.message?.contains("二进制") == true)
        try git("add", "新 文件.txt")
        let stagedState = try await repo.snapshot(), stagedFile = try XCTUnwrap(stagedState.files.first { $0.path == "新 文件.txt" })
        let stagedDiff = try await repo.diff(for: stagedFile, scope: .staged)
        XCTAssertEqual(stagedDiff.additions, 1)
    }

    func testRenameAndSpecialPathAreLiteral() async throws {
        let original = "old name.txt", renamed = "new\nname.txt", literal = "[a]*.txt"
        try write(original, "rename me\n"); try write(literal, "original\n"); try write("a-other.txt", "unrelated\n"); try initialCommit()
        try git("mv", original, renamed)
        try write(literal, "literal change\n"); try write("a-other.txt", "do not include\n")
        let repo = try await GitRepository.open(root), state = try await repo.snapshot()
        let rename = try XCTUnwrap(state.files.first { $0.path == renamed })
        XCTAssertEqual(rename.originalPath, original); XCTAssertEqual(rename.index, "R")
        let renameDiff = try await repo.diff(for: rename, scope: .staged)
        XCTAssertTrue(renameDiff.raw.contains("rename from"))
        let file = try XCTUnwrap(state.files.first { $0.path == literal })
        let diff = try await repo.diff(for: file, scope: .working)
        XCTAssertTrue(diff.raw.contains("+literal change")); XCTAssertFalse(diff.raw.contains("do not include"))
    }

    func testDeletionDetachedHeadAndConflict() async throws {
        try write("conflict.txt", "base\n"); try write("deleted.txt", "delete me\n"); try initialCommit()
        try git("checkout", "-b", "other"); try write("conflict.txt", "other\n"); try git("commit", "-am", "other")
        try git("checkout", "main"); try write("conflict.txt", "main\n"); try git("commit", "-am", "main")
        try FileManager.default.removeItem(at: root.appendingPathComponent("deleted.txt"))
        let repo = try await GitRepository.open(root), before = try await repo.snapshot()
        let deleted = try XCTUnwrap(before.files.first { $0.path == "deleted.txt" })
        let deletion = try await repo.diff(for: deleted, scope: .working)
        XCTAssertEqual(deletion.deletions, 1)
        try command(["merge", "other"], accepted: [1])
        let state = try await repo.snapshot(), conflict = try XCTUnwrap(state.files.first { $0.path == "conflict.txt" })
        XCTAssertTrue(conflict.conflict); XCTAssertFalse(conflict.hasStaged); XCTAssertEqual(state.operation, "Merge 进行中")
        let conflictDiff = try await repo.diff(for: conflict, scope: .working)
        XCTAssertTrue(conflictDiff.message?.contains("冲突") == true)
        try git("merge", "--abort"); try git("checkout", "--detach")
        let detached = try await repo.snapshot(); XCTAssertEqual(detached.branch, "(detached)")
    }

    func testWorktreeAndLargeFileLimits() async throws {
        try write("base.txt", "base\n"); try initialCommit()
        let linked = root.appendingPathComponent("linked")
        try git("worktree", "add", "-b", "feature", linked.path)
        let repo = try await GitRepository.open(linked)
        XCTAssertNotEqual(repo.gitDirectory, repo.commonDirectory)
        try Data(repeating: 65, count: 2_000_001).write(to: linked.appendingPathComponent("large.txt"))
        let state = try await repo.snapshot(), file = try XCTUnwrap(state.files.first)
        let preview = try await repo.diff(for: file, scope: .working)
        XCTAssertTrue(preview.message?.contains("2 MB") == true)
    }

    func testUntrackedSymlinkIsNotFollowed() async throws {
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: "/etc/hosts")
        let repo = try await GitRepository.open(root), state = try await repo.snapshot()
        let file = try XCTUnwrap(state.files.first), diff = try await repo.diff(for: file, scope: .working)
        XCTAssertTrue(diff.raw.contains("+/etc/hosts")); XCTAssertEqual(diff.additions, 1)
    }

    func testDiffLineNumbersAndContextMarkers() throws {
        let diff = DiffDocument.parse("@@ -9,3 +9,4 @@\n context\n-old\n+new\n+++ literal plus\n tail\n\\ No newline at end of file\n", path: "test")
        XCTAssertEqual(diff.additions, 2); XCTAssertEqual(diff.deletions, 1)
        XCTAssertEqual(diff.lines.filter { $0.kind == .addition }.map(\.new), [10, 11])
        XCTAssertEqual(diff.lines.last?.kind, .note)
        XCTAssertTrue(diff.pairs.contains { $0.left?.text == "old" && $0.right?.text == "new" })
    }

    func testExternalDiffIsNeverExecutedAndOutputBounded() async throws {
        try write("file.txt", "old\n"); try initialCommit(); try write("file.txt", "new\n")
        try git("config", "diff.external", "/usr/bin/false")
        let repo = try await GitRepository.open(root), state = try await repo.snapshot(), file = try XCTUnwrap(state.files.first)
        let diff = try await repo.diff(for: file, scope: .working); XCTAssertTrue(diff.raw.contains("+new"))
        do { _ = try await repo.runner.run(["status", "--porcelain=v2"], at: root, limit: 4); XCTFail("Expected output limit") }
        catch { XCTAssertTrue(error.localizedDescription.contains("上限")) }
    }
}
