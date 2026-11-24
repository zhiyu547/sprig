// Copyright (c) 2026 zhiyu
// SPDX-License-Identifier: LicenseRef-Sprig-NC-SA-1.0

import XCTest
@testable import GitTool
@testable import GitCore

final class PushFlowTests: XCTestCase {
    private func git(_ args: [String], at directory: URL) async throws -> String {
        let result = try await CommandRunner().run(args, at: directory)
        guard result.code == 0 else { throw GitError.message(result.error + result.text) }
        return result.text.trimmingCharacters(in: .newlines)
    }

    private func setup(_ folder: URL) async throws -> (GitRepository, URL) {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let root = folder.appendingPathComponent("work"), remote = folder.appendingPathComponent("remote.git")
        let other = folder.appendingPathComponent("other")
        _ = try await git(["init", "-b", "main", root.path], at: folder)
        _ = try await git(["init", "--bare", "-b", "main", remote.path], at: folder)
        let repo = try await GitRepository.open(root)
        let config = [
            ["user.name", "Sprig Fixture"], ["user.email", "fixture@example.invalid"],
            ["commit.gpgsign", "false"], ["core.hooksPath", "/dev/null"],
            ["core.autocrlf", "false"], ["core.attributesFile", "/dev/null"],
            ["push.default", "simple"], ["remote.pushDefault", "origin"]
        ]
        for args in config {
            try await repo.checked(["config"] + args)
        }
        try await repo.checked(["commit", "--allow-empty", "-m", "base"])
        try await repo.checked(["remote", "add", "origin", remote.path])
        try await repo.checked(["push", "--set-upstream", "origin", "main"])
        _ = try await git(["clone", "--branch", "main", remote.path, other.path], at: folder)
        try Data("colleague change\n".utf8).write(to: other.appendingPathComponent("remote.txt"))
        _ = try await git(["add", "remote.txt"], at: other)
        _ = try await git(["-c", "user.name=Other", "-c", "user.email=other@example.invalid", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "commit", "-m", "remote change"], at: other)
        _ = try await git(["push", "origin", "main"], at: other)
        return (repo, remote)
    }

    @MainActor private func waitForOperation(_ store: RepositoryStore) async throws {
        let deadline = Date().addingTimeInterval(8)
        repeat { try await Task.sleep(nanoseconds: 20_000_000) } while store.busy && Date() < deadline
        XCTAssertFalse(store.busy, "Operation did not finish")
    }

    @MainActor func testPushMergesTrackedBranchWithoutConfirmation() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sprig-tracked-push-" + UUID().uuidString)
        let store = RepositoryStore()
        defer { store.stop(); try? FileManager.default.removeItem(at: folder) }
        let (repo, remote) = try await setup(folder)
        try await repo.checked(["commit", "--allow-empty", "-m", "local change"])
        let localBefore = try await repo.headOID()
        let remoteBefore = try await git(["rev-parse", "refs/heads/main"], at: remote)
        store.repository = repo; store.snapshot = try await repo.snapshot()
        store.openPush()
        try await waitForOperation(store)
        XCTAssertNil(store.sheet, "A configured upstream should not require a second push action")
        XCTAssertNil(store.error)
        let parents = try await git(["show", "-s", "--format=%P", "refs/heads/main"], at: remote)
        XCTAssertEqual(parents, localBefore + " " + remoteBefore)
        XCTAssertNil(try repo.pushSession())
    }

    @MainActor func testCommitAndPushTransfersBinaryEvenIfItsDiffExceedsPreviewLimit() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sprig-binary-push-" + UUID().uuidString)
        let store = RepositoryStore()
        defer { store.stop(); try? FileManager.default.removeItem(at: folder) }
        let (repo, remote) = try await setup(folder)
        let path = "packed asset.dat"
        let file = repo.root.appendingPathComponent(path)
        // The binary marker comes after Git's text detection window.
        var staged = Data(repeating: 88, count: 9_000)
        staged.append(0); staged.append(Data(repeating: 255, count: 4_200_000)); staged.append(10)
        try staged.write(to: file)
        store.repository = repo; store.snapshot = try await repo.snapshot()
        store.toggleStage(try XCTUnwrap(store.snapshot?.files.first { $0.path == path }))
        let stage = try XCTUnwrap(store.operationTask)
        await stage.value
        XCTAssertEqual(store.snapshot?.stagedCount, 1)
        // Preserve an unstaged edit after the selected bytes enter the index.
        var working = staged; working.append(0); try working.write(to: file)
        store.commitMessage = "feat: add binary asset"
        let draftKey = store.draftKey(repo.root.path)
        let oldHistory = UserDefaults.standard.object(forKey: "Sprig.messageHistory")
        defer {
            UserDefaults.standard.removeObject(forKey: draftKey)
            UserDefaults.standard.set(oldHistory, forKey: "Sprig.messageHistory")
        }
        store.prepareCommit(push: true)
        try await waitForOperation(store)
        guard case let .commit(preparation, push)? = store.sheet?.kind else {
            return XCTFail(store.error ?? "Expected the commit confirmation to list the binary file")
        }
        XCTAssertEqual(preparation.files.map(\.path), [path]); XCTAssertTrue(preparation.patch.isEmpty)
        store.performCommit(preparation, push: push)
        try await waitForOperation(store)
        XCTAssertNil(store.error); XCTAssertNil(store.sheet)
        let blob = try await CommandRunner().run(["cat-file", "blob", "main:" + path], at: remote, limit: staged.count + 1)
        XCTAssertEqual(blob.code, 0); XCTAssertTrue(blob.data == staged)
        XCTAssertTrue(try Data(contentsOf: file) == working)
        let branch = try await repo.headOID()
        let pushed = try await git(["rev-parse", "refs/heads/main"], at: remote)
        XCTAssertEqual(branch, pushed)
    }

    @MainActor func testPushAsksForTargetWhenNoUpstreamOrPushRemoteDiffers() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sprig-push-target-" + UUID().uuidString)
        let store = RepositoryStore()
        defer { store.stop(); try? FileManager.default.removeItem(at: folder) }
        let (repo, remote) = try await setup(folder)
        store.repository = repo; store.snapshot = try await repo.snapshot()
        let localBefore = try await repo.headOID()
        let remoteBefore = try await git(["rev-parse", "refs/heads/main"], at: remote)
        store.openPush(chooseTarget: true)
        try await waitForOperation(store)
        guard case .push(localBefore)? = store.sheet?.kind else { return XCTFail("User must be able to choose a different target") }
        store.sheet = nil
        try await repo.checked(["branch", "--unset-upstream"])
        store.openPush()
        try await waitForOperation(store)
        guard case .push(localBefore)? = store.sheet?.kind else { return XCTFail("Untracked branch must ask for a destination") }
        store.sheet = nil
        try await repo.checked(["branch", "--set-upstream-to=origin/main"])
        try await repo.checked(["remote", "add", "fork", folder.appendingPathComponent("different-push-target.git").path])
        try await repo.checked(["config", "branch.main.pushRemote", "fork"])
        store.openPush()
        try await waitForOperation(store)
        guard case .push(localBefore)? = store.sheet?.kind else { return XCTFail("A different configured push remote must ask for a destination") }
        let remoteAfter = try await git(["rev-parse", "refs/heads/main"], at: remote)
        XCTAssertEqual(remoteAfter, remoteBefore)
    }

    func testAutomaticPushStopsIfReviewedRemoteURLChanges() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sprig-changed-push-target-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let (repo, remote) = try await setup(folder)
        let stamp = try await repo.stamp()
        let confirmed = try await repo.trackedPushTarget(for: stamp.branch)
        let target = try XCTUnwrap(confirmed)
        let remoteBefore = try await git(["rev-parse", "refs/heads/main"], at: remote)
        let alternate = folder.appendingPathComponent("alternate.git")
        _ = try await git(["clone", "--bare", remote.path, alternate.path], at: folder)
        try await repo.checked(["remote", "set-url", "--push", "origin", alternate.path])
        do {
            _ = try await repo.synchronizedPush(to: target.destination, expectedOID: stamp.head, strategy: .merge, requiring: target)
            XCTFail("Automatic push should require a new selection when the reviewed URL changes")
        } catch { XCTAssertTrue(error.localizedDescription.contains("推送地址已改变"), error.localizedDescription) }
        XCTAssertNil(try repo.pushSession())
        let localAfter = try await repo.headOID()
        let alternateAfter = try await git(["rev-parse", "refs/heads/main"], at: alternate)
        XCTAssertEqual(localAfter, stamp.head); XCTAssertEqual(alternateAfter, remoteBefore)
    }
}
