// Copyright (c) 2026 zhiyu
// SPDX-License-Identifier: LicenseRef-Sprig-NC-SA-1.0

import XCTest
@testable import GitCore

extension OperationsTests {
    private func syncFixture() throws -> (URL, URL) {
        try initial()
        try write("draft.txt", "base draft\n"); try git(["add", "."]); try git(["commit", "-m", "draft base"])
        let remote = root.appendingPathComponent(".git/sync-remote.git"), other = root.appendingPathComponent(".git/sync-other")
        try git(["init", "--bare", remote.path]); try git(["remote", "add", "origin", remote.path]); try git(["push", "-u", "origin", "main"])
        try git(["clone", "-b", "main", remote.path, other.path])
        try git(["config", "user.name", "Colleague"], at: other); try git(["config", "user.email", "colleague@example.invalid"], at: other)
        return (remote, other)
    }
    private func remoteCommit(_ other: URL, path: String = "remote.txt", text: String = "remote work\n") throws {
        try Data(text.utf8).write(to: other.appendingPathComponent(path)); try git(["add", "."], at: other)
        try git(["commit", "-m", "colleague change"], at: other); try git(["push"], at: other)
    }
    private func localCommit(_ path: String = "local.txt", text: String = "local work\n") throws {
        try write(path, text); try git(["add", path]); try git(["commit", "-m", "local feature"])
    }
    private func sync(_ repo: GitRepository, strategy: PushStrategy = .merge, branch: String = "main") async throws -> String {
        try await repo.synchronizedPush(to: .init(remote: "origin", branch: branch), expectedOID: repo.headOID(), strategy: strategy)
    }
    func testSyncMergePreservesPartialIndexAndUntrackedFiles() async throws {
        let (remote, other) = try syncFixture(); try remoteCommit(other); try localCommit()
        let localOID = try git(["rev-parse", "HEAD"])
        try write("draft.txt", "selected draft\n"); try git(["add", "draft.txt"])
        try write("draft.txt", "selected draft\nremaining draft\n"); try write("new draft.txt", "untracked\n")
        let beforeIndex = try git(["diff", "--cached"]), beforeWorking = try git(["diff"])
        let repo = try await GitRepository.open(root)
        _ = try await sync(repo)
        XCTAssertEqual(try git(["rev-parse", "HEAD"]), try git(["rev-parse", "main"], at: remote))
        XCTAssertEqual(try git(["rev-parse", "HEAD^1"]), localOID)
        XCTAssertEqual(try git(["show", "HEAD:draft.txt"]), "base draft")
        XCTAssertEqual(try git(["diff", "--cached"]), beforeIndex); XCTAssertEqual(try git(["diff"]), beforeWorking)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("new draft.txt")), "untracked\n")
        XCTAssertEqual(try git(["stash", "list"]), ""); XCTAssertNil(try repo.pushSession())
    }
    func testSyncRebaseReplaysLocalCommitAndFastForwardDoesNotAddMerge() async throws {
        let (remote, other) = try syncFixture(); try remoteCommit(other); try localCommit()
        let localOID = try git(["rev-parse", "HEAD"]), repo = try await GitRepository.open(root)
        _ = try await sync(repo, strategy: .rebase)
        XCTAssertNotEqual(try git(["rev-parse", "HEAD"]), localOID)
        XCTAssertEqual(try git(["rev-list", "--count", "HEAD"]), "4")
        XCTAssertEqual(try git(["rev-list", "--merges", "HEAD"]), "")
        try git(["pull", "--ff-only"], at: other); try remoteCommit(other, path: "next.txt")
        try write("draft.txt", "unsaved local draft\n")
        _ = try await sync(repo)
        XCTAssertEqual(try git(["rev-parse", "HEAD"]), try git(["rev-parse", "main"], at: remote))
        XCTAssertEqual(try git(["rev-list", "--count", "HEAD"]), "5")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("draft.txt")), "unsaved local draft\n")
    }
    func testSyncMergeConflictSurvivesReopenAndContinuesWithoutRecommit() async throws {
        let (remote, other) = try syncFixture()
        try remoteCommit(other, path: "service.txt", text: "their version\n"); try localCommit("service.txt", text: "our version\n")
        let remoteOID = try git(["rev-parse", "main"], at: remote)
        try write("draft.txt", "my draft\n"); try git(["add", "draft.txt"])
        let repo = try await GitRepository.open(root)
        await expectFailure("同步已暂停") { _ = try await self.sync(repo) }
        XCTAssertEqual(try repo.pushSession()?.phase, .integrating)
        let savedStashes = try await repo.stashes(), protectedStash = try XCTUnwrap(savedStashes.first)
        await expectFailure("正在保护") { _ = try await repo.dropStash(protectedStash) }
        XCTAssertEqual(try git(["rev-parse", "main"], at: remote), remoteOID)
        let reopened = try await GitRepository.open(root)
        try write("service.txt", "both versions resolved\n")
        let state = try await reopened.snapshot(), file = try XCTUnwrap(state.files.first(where: \.conflict))
        try await reopened.markResolved(file)
        _ = try await reopened.resumeSynchronizedPush()
        XCTAssertEqual(try git(["rev-parse", "HEAD"]), try git(["rev-parse", "main"], at: remote))
        XCTAssertEqual(try git(["show", ":draft.txt"]), "my draft")
        XCTAssertEqual(try git(["show", "HEAD:draft.txt"]), "base draft")
        XCTAssertEqual(try git(["log", "--format=%s", "--grep=local feature"]).split(separator: "\n").count, 1)
        XCTAssertNil(try reopened.pushSession())
    }
    func testSyncRebaseConflictCanContinueFromDetachedHEAD() async throws {
        let (remote, other) = try syncFixture()
        try remoteCommit(other, path: "service.txt", text: "their version\n"); try localCommit("service.txt", text: "our version\n")
        let repo = try await GitRepository.open(root)
        await expectFailure("同步已暂停") { _ = try await self.sync(repo, strategy: .rebase) }
        let state = try await repo.snapshot(); XCTAssertTrue(state.operation?.hasPrefix("Rebase") == true)
        try write("service.txt", "resolved\n"); try await repo.markResolved(XCTUnwrap(state.files.first(where: \.conflict)))
        _ = try await repo.resumeSynchronizedPush()
        XCTAssertEqual(try git(["rev-parse", "HEAD"]), try git(["rev-parse", "main"], at: remote))
        XCTAssertEqual(try git(["rev-list", "--merges", "HEAD"]), "")
    }
    func testSyncAbortRestoresDraftsForMergeAndRebase() async throws {
        let (remote, other) = try syncFixture()
        try remoteCommit(other, path: "service.txt", text: "their version\n"); try localCommit("service.txt", text: "our version\n")
        let original = try git(["rev-parse", "HEAD"]), remoteOID = try git(["rev-parse", "main"], at: remote)
        try write("draft.txt", "selected\n"); try git(["add", "draft.txt"]); try write("draft.txt", "selected\nworking\n"); try write("extra.txt", "untracked\n")
        let index = try git(["diff", "--cached"]), working = try git(["diff"])
        let repo = try await GitRepository.open(root)
        for strategy in PushStrategy.allCases {
            await expectFailure("同步已暂停") { _ = try await self.sync(repo, strategy: strategy) }
            _ = try await repo.cancelSynchronizedPush()
            XCTAssertEqual(try git(["rev-parse", "HEAD"]), original)
            XCTAssertEqual(try git(["diff", "--cached"]), index); XCTAssertEqual(try git(["diff"]), working)
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("extra.txt")), "untracked\n")
            XCTAssertEqual(try git(["rev-parse", "main"], at: remote), remoteOID)
            XCTAssertNil(try repo.pushSession()); XCTAssertEqual(try git(["stash", "list"]), "")
        }
    }
    func testSyncRestoreConflictPausesBeforePushAndRetainsBackup() async throws {
        let (remote, other) = try syncFixture()
        try remoteCommit(other, path: "draft.txt", text: "their draft\n"); try localCommit()
        let remoteOID = try git(["rev-parse", "main"], at: remote)
        try write("draft.txt", "my conflicting draft\n")
        let repo = try await GitRepository.open(root)
        await expectFailure("恢复本地修改未完成") { _ = try await self.sync(repo) }
        XCTAssertEqual(try repo.pushSession()?.phase, .restoreConflict)
        XCTAssertEqual(try git(["rev-parse", "main"], at: remote), remoteOID)
        let backup = try XCTUnwrap(repo.pushSession()?.stashOID)
        await expectFailure("请核对") { _ = try await repo.resumeSynchronizedPush() }
        try write("draft.txt", "both drafts resolved\n")
        let state = try await repo.snapshot(); if let file = state.files.first(where: \.conflict) { try await repo.markResolved(file) }
        _ = try await repo.resumeSynchronizedPush(restorationReviewed: true)
        XCTAssertEqual(try git(["show", "HEAD:draft.txt"]), "their draft") // Uncommitted draft must never leak into the push.
        XCTAssertEqual(try git(["show", ":draft.txt"]), "both drafts resolved")
        XCTAssertTrue(try git(["stash", "list", "--format=%H"]).contains(backup))
        XCTAssertNil(try repo.pushSession())
    }
    func testSyncUsesPushURLAndSelectedBranchInsteadOfUpstream() async throws {
        let (fetchRemote, _) = try syncFixture()
        let pushRemote = root.appendingPathComponent(".git/push-only.git")
        try git(["clone", "--bare", fetchRemote.path, pushRemote.path])
        let other = root.appendingPathComponent(".git/push-other")
        try git(["clone", "-b", "main", pushRemote.path, other.path]); try git(["config", "user.name", "Push Colleague"], at: other); try git(["config", "user.email", "push@example.invalid"], at: other)
        try git(["switch", "-c", "team"], at: other); try git(["push", "-u", "origin", "team"], at: other)
        try remoteCommit(other); try localCommit()
        try git(["remote", "set-url", "--push", "origin", pushRemote.path])
        let repo = try await GitRepository.open(root)
        _ = try await sync(repo, branch: "team")
        XCTAssertEqual(try git(["rev-parse", "HEAD"]), try git(["rev-parse", "team"], at: pushRemote))
        XCTAssertTrue(try git(["ls-tree", "--name-only", "HEAD"]).contains("remote.txt"))
        XCTAssertEqual(try git(["rev-list", "--count", "main"], at: fetchRemote), "2")
    }
    func testSyncRetriesOnlyConcurrentRemoteUpdate() async throws {
        let (remote, other) = try syncFixture(); try localCommit()
        let script = "#!/bin/sh\nif [ ! -e .git/raced ]; then\n touch .git/raced\n printf 'raced\\n' > '\(other.path)/raced.txt'\n git -C '\(other.path)' add raced.txt\n git -C '\(other.path)' commit -m raced >/dev/null\n git -C '\(other.path)' push >/dev/null 2>&1\nfi\n"
        try write(".git/hooks/pre-push", script); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent(".git/hooks/pre-push").path)
        let repo = try await GitRepository.open(root); _ = try await sync(repo)
        XCTAssertEqual(try git(["rev-parse", "HEAD"]), try git(["rev-parse", "main"], at: remote))
        XCTAssertTrue(try git(["ls-tree", "--name-only", "HEAD"]).contains("raced.txt"))
        XCTAssertEqual(try git(["log", "--format=%s", "--grep=local feature"]).split(separator: "\n").count, 1)
    }
    func testSyncServerRejectionRetainsUpdatedHEADForRetry() async throws {
        let (remote, other) = try syncFixture(); try remoteCommit(other); try localCommit()
        let hook = remote.appendingPathComponent("hooks/pre-receive")
        try Data("#!/bin/sh\necho branch-protection >&2\nexit 1\n".utf8).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        let repo = try await GitRepository.open(root)
        await expectFailure("branch-protection") { _ = try await self.sync(repo) }
        let integrated = try git(["rev-parse", "HEAD"])
        XCTAssertEqual(try repo.pushSession()?.expectedOID, integrated)
        XCTAssertEqual(try repo.pushSession()?.phase, .ready)
        try FileManager.default.removeItem(at: hook)
        _ = try await repo.resumeSynchronizedPush()
        XCTAssertEqual(try git(["rev-parse", "HEAD"]), integrated)
        XCTAssertEqual(try git(["rev-parse", "main"], at: remote), integrated)
    }
    func testSyncRetriesAreBoundedAndNewBranchCanBeCreated() async throws {
        let (_, other) = try syncFixture(); try localCommit()
        let repo = try await GitRepository.open(root)
        _ = try await sync(repo, branch: "new-team")
        let script = "#!/bin/sh\necho run >> .git/push-attempts\necho update >> '\(other.path)/races.txt'\ngit -C '\(other.path)' add races.txt\ngit -C '\(other.path)' commit -m race >/dev/null\ngit -C '\(other.path)' push >/dev/null 2>&1\n"
        try write(".git/hooks/pre-push", script); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent(".git/hooks/pre-push").path)
        await expectFailure("远端连续更新") { _ = try await self.sync(repo) }
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(".git/push-attempts")).split(separator: "\n").count, 3)
        XCTAssertEqual(try repo.pushSession()?.phase, .ready)
        let head = try git(["rev-parse", "HEAD"])
        _ = try await repo.cancelSynchronizedPush(); XCTAssertEqual(try git(["rev-parse", "HEAD"]), head)
    }
    func testPushRejectionClassificationDoesNotRetryAuthOrHooks() {
        func result(_ text: String) -> CommandResult { CommandResult(data: Data(text.utf8), error: "", code: 1) }
        XCTAssertTrue(GitRepository.isPushRace(result("!\tHEAD:refs/heads/main\t[rejected] (fetch first)\n")))
        XCTAssertTrue(GitRepository.isPushRace(result("!\tHEAD:refs/heads/main\t[rejected] (non-fast-forward)\n")))
        XCTAssertFalse(GitRepository.isPushRace(result("!\tHEAD:refs/heads/main\t[remote rejected] (hook declined)\n")))
        XCTAssertTrue(GitRepository.isPushRace(result("!\tHEAD:refs/heads/main\t[remote rejected] (incorrect old value provided)\n")))
        XCTAssertFalse(GitRepository.isPushRace(result("fatal: Authentication failed")))
    }
    func testSyncRejectsChangedHeadAndMultiplePushURLsBeforeMutation() async throws {
        let (remote, _) = try syncFixture(), before = try git(["rev-parse", "HEAD"])
        try localCommit(); let repo = try await GitRepository.open(root)
        await expectFailure("提交未改变") { _ = try await repo.synchronizedPush(to: .init(remote: "origin", branch: "main"), expectedOID: before, strategy: .merge) }
        XCTAssertNil(try repo.pushSession())
        try git(["remote", "set-url", "--push", "origin", remote.path]); try git(["remote", "set-url", "--add", "--push", "origin", remote.path + ".another"])
        await expectFailure("多个 push URL") { _ = try await self.sync(repo) }
        XCTAssertNil(try repo.pushSession()); XCTAssertEqual(try git(["rev-parse", "main"], at: remote), before)
    }
    func testSyncRecoveryDoesNotApplyStashTwiceAfterInterruptedRestore() async throws {
        let (_, other) = try syncFixture(); try remoteCommit(other, path: "service.txt", text: "their\n"); try localCommit("service.txt", text: "ours\n")
        try write("draft.txt", "draft to protect\n")
        let repo = try await GitRepository.open(root)
        await expectFailure("同步已暂停") { _ = try await self.sync(repo) }
        var session = try XCTUnwrap(repo.pushSession())
        _ = try await repo.continueOperation(abort: true)
        _ = try await repo.checked(["stash", "apply", "--index", XCTUnwrap(session.stashOID)])
        // Simulate termination after stash apply but before the success record.
        session.phase = .restoring
        try JSONEncoder().encode(session).write(to: repo.gitDirectory.appendingPathComponent("sprig-push.json"), options: .atomic)
        let before = try git(["diff"])
        await expectFailure("请核对") { _ = try await repo.resumeSynchronizedPush() }
        XCTAssertEqual(try git(["diff"]), before)
        _ = try await repo.cancelSynchronizedPush()
        XCTAssertEqual(try git(["diff"]), before); XCTAssertFalse(try git(["stash", "list"]).isEmpty)
    }
    func testSyncDoesNotOverwriteIgnoredFiles() async throws {
        let (_, other) = try syncFixture()
        try localCommit(".gitignore", text: "local-cache.txt\n")
        try write("local-cache.txt", "irreplaceable local cache\n")
        try remoteCommit(other, path: "local-cache.txt", text: "tracked remote file\n")
        let repo = try await GitRepository.open(root), before = try await repo.headOID()
        for strategy in PushStrategy.allCases {
            await expectFailure("被忽略的文件重叠") { _ = try await self.sync(repo, strategy: strategy) }
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("local-cache.txt")), "irreplaceable local cache\n")
            XCTAssertEqual(try git(["rev-parse", "HEAD"]), before)
            _ = try await repo.cancelSynchronizedPush()
        }
    }
    func testSyncDoesNotAdoptUnexpectedHeadAfterIntegrationFailure() async throws {
        let (remote, other) = try syncFixture(); try remoteCommit(other); try localCommit()
        let before = try git(["rev-parse", "HEAD"]), remoteBefore = try git(["rev-parse", "main"], at: remote)
        try write(".git/hooks/pre-rebase", "#!/bin/sh\necho hook > hook-change.txt\ngit add hook-change.txt\ngit commit -m 'external hook commit' >/dev/null\nexit 1\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent(".git/hooks/pre-rebase").path)
        let repo = try await GitRepository.open(root)
        await expectFailure("同步已暂停") { _ = try await self.sync(repo, strategy: .rebase) }
        XCTAssertNotEqual(try git(["rev-parse", "HEAD"]), before)
        XCTAssertEqual(try repo.pushSession()?.expectedOID, before)
        XCTAssertEqual(try repo.pushSession()?.phase, .integrating)
        XCTAssertEqual(try git(["rev-parse", "main"], at: remote), remoteBefore)
        _ = try await repo.cancelSynchronizedPush()
        XCTAssertEqual(try git(["log", "-1", "--format=%s"]), "external hook commit")
    }
}
