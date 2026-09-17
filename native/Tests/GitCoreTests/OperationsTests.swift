// Copyright (c) 2026 zhiyu
// SPDX-License-Identifier: LicenseRef-Sprig-NC-SA-1.0

import XCTest
@testable import GitCore

final class OperationsTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("sprig-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git(["init", "-b", "main"])
        try git(["config", "user.name", "Sprig Test"]); try git(["config", "user.email", "test@example.invalid"])
        try git(["config", "commit.gpgsign", "false"]); try git(["config", "core.autocrlf", "false"])
        try git(["config", "core.hooksPath", root.appendingPathComponent(".git/hooks").path])
    }
    override func tearDownWithError() throws { if let root { try FileManager.default.removeItem(at: root) } }
    func write(_ path: String, _ text: String) throws { try Data(text.utf8).write(to: root.appendingPathComponent(path)) }
    @discardableResult func git(_ args: [String], at directory: URL? = nil, accepted: Set<Int32> = [0]) throws -> String {
        let p = Process(), pipe = Pipe(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git"); p.currentDirectoryURL = directory ?? root; p.arguments = args
        var env = ProcessInfo.processInfo.environment; for key in env.keys where key.hasPrefix("GIT_") { env.removeValue(forKey: key) }; env["GIT_TERMINAL_PROMPT"] = "0"; env["GIT_CONFIG_NOSYSTEM"] = "1"; env["GIT_CONFIG_GLOBAL"] = "/dev/null"; p.environment = env
        p.standardOutput = pipe; p.standardError = pipe; try p.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self); guard accepted.contains(p.terminationStatus) else { throw GitError.message(text) }; return text.trimmingCharacters(in: .newlines)
    }
    func initial() throws { try write("service.txt", "base\n"); try git(["add", "."]); try git(["commit", "-m", "initial"]) }
    func hook(_ script: String) throws { try write(".git/hooks/pre-commit", "#!/bin/sh\n" + script); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent(".git/hooks/pre-commit").path) }
    func expectFailure(_ contains: String, _ action: () async throws -> Void) async { do { try await action(); XCTFail("Expected failure: " + contains) } catch { XCTAssertTrue(error.localizedDescription.contains(contains), error.localizedDescription) } }

    func testStageUnstageUnbornAndLiteralPaths() async throws {
        try write("[a]*.txt", "literal\n"); try write("ab.txt", "other\n")
        let repo = try await GitRepository.open(root), state = try await repo.snapshot(), file = try XCTUnwrap(state.files.first { $0.path == "[a]*.txt" })
        try await repo.stage([file]); let staged = try await repo.snapshot(); XCTAssertEqual(staged.stagedCount, 1)
        try await repo.unstage(staged.files.filter(\.hasStaged)); let unstaged = try await repo.snapshot(); XCTAssertEqual(unstaged.stagedCount, 0); XCTAssertEqual(unstaged.files.count, 2)
        try await repo.stage([file]); let prep = try await repo.prepareCommit(); let result = try await repo.commit(prep, message: "feat: first commit", options: .init())
        XCTAssertEqual(result.oid, try git(["rev-parse", "HEAD"])); XCTAssertEqual(try git(["ls-tree", "--name-only", "HEAD"]), "[a]*.txt")
    }
    func testPartialCommitPreservesWorkingChangesAndSignoff() async throws {
        try initial(); try write("service.txt", "base\nselected\n"); try git(["add", "service.txt"]); try write("service.txt", "base\nselected\nremaining\n")
        let repo = try await GitRepository.open(root), prep = try await repo.prepareCommit()
        XCTAssertTrue(prep.files.first?.hasWorking == true)
        _ = try await repo.commit(prep, message: "feat: selected\n\nDetails", options: .init(signOff: true))
        XCTAssertEqual(try git(["show", "HEAD:service.txt"]), "base\nselected")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("service.txt")), "base\nselected\nremaining\n")
        XCTAssertTrue(try git(["log", "-1", "--format=%B"]).contains("Signed-off-by: Sprig Test <test@example.invalid>"))
        let state = try await repo.snapshot(); XCTAssertEqual(state.stagedCount, 0); XCTAssertEqual(state.files.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".git/index.lock").path))
    }
    func testAmendMessageWithoutStagedChanges() async throws {
        try initial(); let repo = try await GitRepository.open(root), before = try await repo.headOID(), prep = try await repo.prepareCommit(amend: true)
        let result = try await repo.commit(prep, message: "fix: corrected initial", options: .init(amend: true))
        XCTAssertNotEqual(result.oid, before); XCTAssertEqual(try git(["rev-list", "--count", "HEAD"]), "1"); XCTAssertEqual(try git(["show", "HEAD:service.txt"]), "base")
    }
    func testStalePreparationAndExistingLockRefuseCommit() async throws {
        try initial(); try write("service.txt", "selected\n"); try git(["add", "."])
        let repo = try await GitRepository.open(root), prep = try await repo.prepareCommit(), head = try await repo.headOID()
        try write("extra.txt", "unexpected\n"); try git(["add", "extra.txt"])
        await expectFailure("已改变") { _ = try await repo.commit(prep, message: "test", options: .init()) }
        XCTAssertEqual(try git(["rev-parse", "HEAD"]), head)
        let fresh = try await repo.prepareCommit(); try write(".git/index.lock", "another process")
        await expectFailure("其他 Git 操作") { _ = try await repo.commit(fresh, message: "test", options: .init()) }
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(".git/index.lock")), "another process")
    }
    func testHookFailurePreservesHookStagedFixAndUnlocks() async throws {
        try initial(); try write("service.txt", "before hook\n"); try git(["add", "."])
        try hook("printf 'hook fix\\n' > service.txt\ngit add service.txt\nprintf 'hook rejected' >&2\nexit 1\n")
        let repo = try await GitRepository.open(root), prep = try await repo.prepareCommit(), head = try await repo.headOID()
        await expectFailure("hook rejected") { _ = try await repo.commit(prep, message: "rejected", options: .init()) }
        XCTAssertEqual(try git(["rev-parse", "HEAD"]), head); XCTAssertEqual(try git(["show", ":service.txt"]), "hook fix")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".git/index.lock").path))
    }
    func testOtherStagingIsLockedDuringCommit() async throws {
        try initial(); try write("service.txt", "selected\n"); try write("unrelated.txt", "unrelated\n"); try git(["add", "service.txt"])
        try hook("env -u GIT_INDEX_FILE git add unrelated.txt 2>.git/lock-evidence\nif [ $? -eq 0 ]; then exit 1; fi\nexit 0\n")
        let repo = try await GitRepository.open(root), prep = try await repo.prepareCommit()
        _ = try await repo.commit(prep, message: "feat: protected", options: .init())
        XCTAssertEqual(try git(["ls-tree", "--name-only", "HEAD"]), "service.txt")
        XCTAssertTrue(try String(contentsOf: root.appendingPathComponent(".git/lock-evidence")).contains("index.lock"))
    }
    func testWhitespaceCheckBlocksAndCanBeDisabled() async throws {
        try initial(); try write("service.txt", "trailing  \n"); try git(["add", "."])
        let repo = try await GitRepository.open(root), prep = try await repo.prepareCommit()
        XCTAssertFalse(prep.checkOutput.isEmpty)
        await expectFailure("空白检查") { _ = try await repo.commit(prep, message: "test", options: .init()) }
        _ = try await repo.commit(prep, message: "test", options: .init(checkWhitespace: false))
    }
    func testRefsHistoryRenameAndHashSearch() async throws {
        try initial(); let repo = try await GitRepository.open(root), initialOID = try await repo.headOID()
        try await repo.createBranch("feature/one"); try git(["mv", "service.txt", "新\n名字.txt"]); try git(["commit", "-m", "refactor: rename", "-m", "Detailed body"])
        try await repo.createTag("v0.2", revision: "HEAD")
        let refs = try await repo.refs(), main = try XCTUnwrap(refs.first { $0.name == "main" && $0.kind == .local })
        XCTAssertTrue(refs.contains { $0.name == "feature/one" && $0.current }); XCTAssertTrue(refs.contains { $0.name == "v0.2" && $0.kind == .tag })
        let history = try await repo.history(); XCTAssertEqual(history.count, 2); let commit = try XCTUnwrap(history.first { $0.subject == "refactor: rename" }); XCTAssertEqual(commit.body, "Detailed body")
        let files = try await repo.commitFiles(commit), file = try XCTUnwrap(files.first); XCTAssertEqual(file.originalPath, "service.txt"); XCTAssertEqual(file.path, "新\n名字.txt")
        let diff = try await repo.commitDiff(commit, file: file); XCTAssertTrue(diff.raw.contains("rename from"))
        let initialHistory = try await repo.history(query: String(initialOID.prefix(10))); XCTAssertEqual(initialHistory.map(\.oid), [initialOID])
        let originalFiles = try await repo.commitFiles(initialHistory[0]); XCTAssertEqual(originalFiles.count, 1)
        let originalDiff = try await repo.commitDiff(initialHistory[0], file: originalFiles[0]); XCTAssertTrue(originalDiff.raw.contains("+base"))
        try await repo.switchRef(main); let mainState = try await repo.snapshot(); XCTAssertEqual(mainState.branch, "main")
        let tag = try XCTUnwrap(refs.first { $0.kind == .tag }); try await repo.switchRef(tag); let tagState = try await repo.snapshot(); XCTAssertEqual(tagState.branch, "(detached)")
    }
    func testStashRetainsPartialIndexAndUntrackedFiles() async throws {
        try initial(); try write("service.txt", "selected\n"); try git(["add", "service.txt"]); try write("service.txt", "selected\nremaining\n"); try write("new.txt", "new\n")
        let repo = try await GitRepository.open(root); _ = try await repo.stashSave("partial fixture", includeUntracked: true)
        let clean = try await repo.snapshot(); XCTAssertTrue(clean.files.isEmpty, "Remaining: \(clean.files)")
        let stashes = try await repo.stashes(), stash = try XCTUnwrap(stashes.first), diff = try await repo.stashDiff(stash); XCTAssertTrue(diff.raw.contains("+new"))
        _ = try await repo.applyStash(stash); let state = try await repo.snapshot(); XCTAssertTrue(state.files.first { $0.path == "service.txt" }?.hasStaged == true); XCTAssertTrue(state.files.first { $0.path == "service.txt" }?.hasWorking == true); XCTAssertTrue(state.files.contains { $0.path == "new.txt" && $0.untracked })
        let retained = try await repo.stashes(); XCTAssertEqual(retained.count, 1)
        _ = try await repo.stashSave("new stash", includeUntracked: true)
        await expectFailure("列表已变化") { _ = try await repo.dropStash(stash) }
    }
    func testPushFetchPullAndRejectedPushDoNotRecommit() async throws {
        try initial(); let repo = try await GitRepository.open(root), remote = root.appendingPathComponent(".git/remote.git")
        try git(["init", "--bare", remote.path]); try git(["remote", "add", "origin", remote.path])
        let head = try await repo.headOID(); _ = try await repo.push(to: .init(remote: "origin", branch: "main"), expectedOID: head)
        XCTAssertEqual(try git(["rev-parse", "refs/heads/main"], at: remote), head)
        let clone = root.appendingPathComponent(".git/other"); try git(["clone", "-b", "main", remote.path, clone.path]); try git(["config", "user.name", "Other"], at: clone); try git(["config", "user.email", "other@example.invalid"], at: clone)
        try Data("remote\n".utf8).write(to: clone.appendingPathComponent("remote.txt")); try git(["add", "."], at: clone); try git(["commit", "-m", "remote"], at: clone); try git(["push"], at: clone)
        _ = try await repo.fetch(); _ = try await repo.pull(); XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("remote.txt").path))
        try Data("remote2\n".utf8).write(to: clone.appendingPathComponent("remote.txt")); try git(["commit", "-am", "remote 2"], at: clone); try git(["push"], at: clone)
        try write("service.txt", "local\n"); try git(["add", "service.txt"]); let prep = try await repo.prepareCommit(); let result = try await repo.commit(prep, message: "local", options: .init())
        let count = try git(["rev-list", "--count", "HEAD"])
        do { _ = try await repo.push(to: .init(remote: "origin", branch: "main"), expectedOID: result.oid); XCTFail("Expected non-fast-forward rejection") } catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
        XCTAssertEqual(try git(["rev-list", "--count", "HEAD"]), count); XCTAssertEqual(try git(["rev-parse", "HEAD"]), result.oid)
    }
    func testDiscardRejectsExternalBinaryEditAndPreservesIndex() async throws {
        try Data([0, 1, 2]).write(to: root.appendingPathComponent("file.bin")); try git(["add", "."]); try git(["commit", "-m", "binary"])
        try Data([0, 3, 4]).write(to: root.appendingPathComponent("file.bin")); try git(["add", "file.bin"])
        try Data([0, 5, 6]).write(to: root.appendingPathComponent("file.bin"))
        let repo = try await GitRepository.open(root), state = try await repo.snapshot(), file = try XCTUnwrap(state.files.first)
        let patch = try await repo.discardPatch(for: file)
        try Data([0, 7, 8]).write(to: root.appendingPathComponent("file.bin"))
        await expectFailure("外部变化") { try await repo.discardWorking(file, expectedPatch: patch) }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("file.bin")), Data([0, 7, 8]))
        let fresh = try await repo.discardPatch(for: file); try await repo.discardWorking(file, expectedPatch: fresh)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("file.bin")), Data([0, 3, 4]))
        let after = try await repo.snapshot(); XCTAssertEqual(after.stagedCount, 1); XCTAssertFalse(after.files[0].hasWorking)
    }
    func testMergeConflictCanAbortAndRevertCreatesCommit() async throws {
        try initial(); let repo = try await GitRepository.open(root)
        try await repo.createBranch("feature"); try write("service.txt", "feature\n"); try git(["commit", "-am", "feature change"])
        let source = try await repo.headOID(); try git(["switch", "main"]); try write("service.txt", "main\n"); try git(["commit", "-am", "main change"])
        do { _ = try await repo.integrate("merge", revision: source); XCTFail("Expected merge conflict") } catch { }
        let conflict = try await repo.snapshot(); XCTAssertEqual(conflict.operation, "Merge 进行中"); XCTAssertTrue(conflict.files.contains(where: \.conflict))
        _ = try await repo.continueOperation(abort: true); let clean = try await repo.snapshot(); XCTAssertTrue(clean.files.isEmpty); XCTAssertNil(clean.operation)
        let previous = try await repo.headOID(); _ = try await repo.integrate("revert", revision: previous)
        XCTAssertEqual(try git(["show", "HEAD:service.txt"]), "base"); XCTAssertNotEqual(try git(["rev-parse", "HEAD"]), previous)
    }
    func testSingleConfigurationRemainsGeneratableAfterRedaction() async throws {
        try write("application.yml", "server:\n  port: 8080\ndatabase:\n  password: old-example-secret-123456\n"); try git(["add", "."]); try git(["commit", "-m", "fixture"])
        try write("application.yml", "server:\n  port: 9090\ndatabase:\n  password: new-example-secret-654321\n"); try git(["add", "application.yml"])
        let repo = try await GitRepository.open(root), before = try await repo.stamp(), context = try await repo.aiContext(configuration: .init())
        XCTAssertTrue(context.canGenerate); XCTAssertEqual(context.included, ["application.yml"]); XCTAssertTrue(context.excluded.isEmpty); XCTAssertEqual(context.redacted.count, 1)
        XCTAssertTrue(context.patch.contains("+  port: 9090")); XCTAssertTrue(context.patch.contains("password: [REDACTED]"))
        var configuration = AIConfiguration(); configuration.baseURL = "https://fixture.invalid/v1"; configuration.model = "fixture"
        let request = try AIClient().request(context: context, configuration: configuration, key: "", intent: .commit), body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertFalse(body.contains("old-example-secret")); XCTAssertFalse(body.contains("new-example-secret")); XCTAssertTrue(body.contains("本地脱敏"))
        let after = try await repo.stamp(); XCTAssertEqual(before, after)
        XCTAssertTrue(try String(contentsOf: root.appendingPathComponent("application.yml")).contains("new-example-secret-654321"))
    }
    func testAIAllExcludedReturnsReasonsWithoutSending() async throws {
        try write(".env", "PASSWORD=local-only-secret\n"); try Data([0, 1, 2]).write(to: root.appendingPathComponent("binary.bin")); try git(["add", "."])
        let repo = try await GitRepository.open(root), context = try await repo.aiContext(configuration: .init())
        XCTAssertFalse(context.canGenerate); XCTAssertTrue(context.patch.isEmpty); XCTAssertEqual(context.excluded.count, 2)
        XCTAssertTrue(context.excluded.contains { $0.contains("匹配排除规则：.env") }); XCTAssertTrue(context.excluded.contains { $0.contains("二进制") })
        var configuration = AIConfiguration(); configuration.baseURL = "https://fixture.invalid/v1"; configuration.model = "fixture"
        XCTAssertThrowsError(try AIClient().request(context: context, configuration: configuration, key: "", intent: .commit))
    }
    func testExplicitConfigurationExclusionAndRenamedSecretRemainExcluded() async throws {
        try write(".env", "PASSWORD=never-send-this\n"); try git(["add", "."]); try git(["commit", "-m", "fixture"]); try git(["mv", ".env", "renamed.txt"])
        try write("application.yml", "server: 9090\n"); try git(["add", "."])
        var configuration = AIConfiguration(); configuration.exclusions += "\napplication.yml"
        let repo = try await GitRepository.open(root), context = try await repo.aiContext(configuration: configuration)
        XCTAssertFalse(context.canGenerate); XCTAssertEqual(context.excluded.count, 2); XCTAssertTrue(context.excluded.contains { $0.contains("renamed.txt") && $0.contains(".env") })
    }
    func testAIContextUsesOnlyStagedAndExcludesSensitiveContent() async throws {
        try initial(); try write("service.txt", "staged change\n"); try write(".env", "PASSWORD=supersecret0123456789  \n"); try write("config.txt", "api_key=longtestsecret0123456789\n"); try git(["add", "."]); try write("service.txt", "working change\n")
        let repo = try await GitRepository.open(root), context = try await repo.aiContext(configuration: .init())
        XCTAssertEqual(context.included, ["config.txt", "service.txt"]); XCTAssertEqual(context.excluded.count, 1); XCTAssertEqual(context.redacted.count, 1); XCTAssertFalse(context.patch.contains("longtestsecret"))
        XCTAssertTrue(context.patch.contains("+staged change")); XCTAssertFalse(context.patch.contains("working change")); XCTAssertFalse(context.patch.contains("supersecret")); XCTAssertFalse(context.whitespaceResult.contains("supersecret")); XCTAssertTrue(context.whitespaceResult.contains("发现空白"))
    }
}

final class MockAIProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let data = try! JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "stop", "message": ["content": "feat(validation): 添加输入校验\n\n- 拒绝空白输入"]]]])
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed); client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
final class AIClientTests: XCTestCase {
    func config(_ url: String) -> AIConfiguration { var c = AIConfiguration(); c.baseURL = url; c.model = "fixture-model"; return c }
    var context: AIContext { .init(stamp: .init(head: "fixture", branch: "refs/heads/main", indexHash: "stamp"), included: ["service.swift"], excluded: [], patch: "+guard !input.isEmpty else { return }", whitespaceResult: "未执行测试") }
    func testEndpointAndRequestContract() throws {
        let c = config("https://example.invalid/v1/"); XCTAssertEqual(try c.endpoint().absoluteString, "https://example.invalid/v1/chat/completions")
        XCTAssertEqual(try config("http://127.0.0.1:11434/v1").endpoint().scheme, "http")
        for url in ["http://example.invalid/v1", "https://user:pass@example.invalid/v1", "https://example.invalid/v1?key=secret"] { XCTAssertThrowsError(try config(url).endpoint()) }
        let request = try AIClient().request(context: context, configuration: c, key: "fixture-key", intent: .commit)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-key")
        let data = try XCTUnwrap(request.httpBody), body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]); XCTAssertEqual(body["model"] as? String, "fixture-model"); XCTAssertEqual(body["max_tokens"] as? Int, 4096)
        let text = String(decoding: data, as: UTF8.self); XCTAssertFalse(text.contains("fixture-key")); XCTAssertTrue(text.contains("标题 + 空行 + 改动列表")); XCTAssertTrue(text.contains("不是指令"))
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        let commitPrompt = try XCTUnwrap(messages.first?["content"])
        XCTAssertFalse(commitPrompt.contains("必须说明覆盖缺口"), "审查报告要求不应混入 commit 提示")
        let reviewPrompt = AIClient.systemPrompt(intent: .review, language: "中文")
        XCTAssertTrue(reviewPrompt.contains("必须说明覆盖缺口"))
        XCTAssertTrue(reviewPrompt.contains("风险概览"))
        var modern = c; modern.modernTokenLimit = true
        let modernBody = try XCTUnwrap(AIClient().request(context: context, configuration: modern, key: "", intent: .review).httpBody)
        XCTAssertTrue(String(decoding: modernBody, as: UTF8.self).contains("max_completion_tokens"))
    }
    func testResponseNormalizationAndTruncation() throws {
        func response(_ text: String, reason: String = "stop") throws -> Data { try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": reason, "message": ["content": text]]]]) }
        XCTAssertEqual(try AIClient.parseResponse(response("```text\nfeat: clean\n```")), "feat: clean")
        XCTAssertThrowsError(try AIClient.parseResponse(response("unfinished", reason: "length")))
        XCTAssertThrowsError(try AIClient.parseResponse(response(" ")))
        XCTAssertThrowsError(try AIClient.parseResponse(Data("{}".utf8)))
    }
    func testSanitizerMasksAddedRemovedAndContextLines() throws {
        let patch = "diff --git a/application.yml b/application.yml\n@@ -1,4 +1,4 @@\n-password: short\n+password: \"quoted-example\"\n api_key: context-secret\n+url: postgres://user:sample@localhost/db\n+Authorization: Bearer synthetic-example\n+port: 9090\n"
        guard case let .text(clean, count) = try AIDiffSanitizer.sanitize(patch) else { return XCTFail("Expected usable redacted diff") }
        XCTAssertEqual(count, 5); XCTAssertTrue(clean.contains("+port: 9090"))
        for value in ["short", "quoted-example", "context-secret", "user:sample", "synthetic-example"] { XCTAssertFalse(clean.contains(value)) }
    }
    func testSanitizerExcludesAmbiguousMultilineValuesAndPrivateKeys() throws {
        for body in ["+password: first\n+  continuation", "+secret: {\n+  nested: value", "+password: |\n+  multiline-example", "+password: \"unterminated\n+  multiline-example", "+secret:\n+  nested: example", "+-----BEGIN RSA PRIVATE KEY-----\n+private-material"] {
            guard case let .excluded(reason) = try AIDiffSanitizer.sanitize("@@ -0,0 +1,2 @@\n" + body) else { XCTFail("Expected exclusion"); continue }
            XCTAssertFalse(reason.isEmpty); XCTAssertFalse(reason.contains("example")); XCTAssertFalse(reason.contains("material"))
        }
    }
    func testGenerateThroughMockHTTPTransport() async throws {
        let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [MockAIProtocol.self]; let session = URLSession(configuration: c); defer { session.invalidateAndCancel() }
        let output = try await AIClient().generate(context: context, configuration: config("https://fixture.invalid/v1"), key: "", intent: .commit, session: session)
        XCTAssertEqual(output, "feat(validation): 添加输入校验\n\n- 拒绝空白输入")
    }
}
