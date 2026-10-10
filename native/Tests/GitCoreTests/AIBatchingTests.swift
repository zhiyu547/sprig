// Copyright (c) 2026 zhiyu
// SPDX-License-Identifier: LicenseRef-Sprig-NC-SA-1.0

import XCTest
@testable import GitCore

/// A local transport boundary that records all requests, including URLSession body streams.
private final class BatchHTTPRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [[String: String]] = []
    var failAt: Int?
    var truncateAt: Int?
    var emptyReasoningAt: Int?
    var waitAt: Int?
    var verbose = false
    var requests: [[String: String]] { lock.lock(); defer { lock.unlock() }; return messages }

    func reply(_ request: URLRequest) -> (Int, Data)? {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 8192)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let inputs = body?["messages"] as? [[String: String]] ?? []
        let message = ["system": inputs.first?["content"] ?? "", "user": inputs.last?["content"] ?? "",
                       "thinking": (body?["enable_thinking"] as? Bool).map { $0 ? "on" : "off" } ?? "default",
                       "deepseekThinking": (body?["thinking"] as? [String: String])?["type"] ?? "default"]
        lock.lock(); messages.append(message); let count = messages.count; lock.unlock()
        if waitAt == count { return nil }
        if failAt == count { return (503, Data("mock unavailable".utf8)) }
        // Reproduce DeepSeek's default thinking mode consuming the entire 4096-token budget.
        let deepSeekThinkingExhausted = body?["model"] as? String == "deepseek-flash" && message["deepseekThinking"] != "disabled"
        if emptyReasoningAt == count || deepSeekThinkingExhausted {
            return (200, try! JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "length", "message": ["content": NSNull(), "reasoning_content": "private-analysis"]]], "usage": ["completion_tokens": 4096, "completion_tokens_details": ["reasoning_tokens": 4096]]]))
        }
        let user = message["user"]!
        let text: String
        if user.contains("<staged_diff>") {
            text = "- fact-\(count): 添加筛选\n" + (verbose ? String(repeating: ".", count: 9000) : "")
        } else {
            // Preserve the evidence markers through hierarchical synthesis.
            let regex = try! NSRegularExpression(pattern: "fact-[0-9]+")
            let facts = regex.matches(in: user, range: NSRange(user.startIndex..., in: user)).compactMap { Range($0.range, in: user).map { String(user[$0]) } }
            text = "feat(tasks): 添加筛选\n\n" + facts.map { "- \($0)" }.joined(separator: "\n")
        }
        return (200, try! JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": truncateAt == count ? "length" : "stop", "message": ["content": text]]]]))
    }
}
private final class BatchHTTPProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var recorders: [String: BatchHTTPRecorder] = [:]
    static func register(_ recorder: BatchHTTPRecorder, at host: String) { lock.lock(); recorders[host] = recorder; lock.unlock() }
    static func remove(_ host: String) { lock.lock(); recorders.removeValue(forKey: host); lock.unlock() }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let recorder = Self.recorders[request.url!.host!]; Self.lock.unlock()
        guard let (status, data) = recorder?.reply(request) else { return }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
private actor BatchProgress {
    var titles: [String] = []
    func append(_ title: String) { titles.append(title) }
}
final class AIBatchingTests: XCTestCase {
    private func context(bytes: Int = 230_000) -> AIContext {
        let patch = "diff --git a/tasks.swift b/tasks.swift\n--- a/tasks.swift\n+++ b/tasks.swift\n@@ -0,0 +1,9000 @@\n" + String(repeating: "+// 添加筛选 🌱\n", count: bytes / 20)
        return AIContext(stamp: .init(head: "fixture", branch: "refs/heads/main", indexHash: "stamp"), included: ["tasks.swift"], excluded: [".env（排除）"], patch: patch, whitespaceResult: "未执行测试")
    }
    private func withTransport(_ recorder: BatchHTTPRecorder, qwen: Bool = false, host requestedHost: String? = nil, run: (URLSession, AIConfiguration) async throws -> Void) async throws {
        let host = requestedHost ?? UUID().uuidString.lowercased() + (qwen ? ".cn-beijing.maas.aliyuncs.com" : ".invalid")
        BatchHTTPProtocol.register(recorder, at: host)
        let settings = URLSessionConfiguration.ephemeral; settings.protocolClasses = [BatchHTTPProtocol.self]
        let session = URLSession(configuration: settings)
        defer { session.invalidateAndCancel(); BatchHTTPProtocol.remove(host) }
        var config = AIConfiguration(); config.baseURL = "https://" + host + "/v1"; config.model = qwen ? "qwen3.8-flash" : "fixture"
        try await run(session, config)
    }
    func testSplittingKeepsEveryByteAndContinuationForHugeUnicodeLine() throws {
        let original = "diff --git a/中文.swift b/中文.swift\n@@ -1 +1 @@\n+" + String(repeating: "中文🌱e\u{301}", count: 40_000) + "\n-last\n+tail-without-newline"
        let batches = AIBatching.split(original)
        XCTAssertGreaterThan(batches.count, 2)
        XCTAssertEqual(batches.map(\.patch).joined(), original)
        XCTAssertTrue(batches.allSatisfy { $0.patch.utf8.count <= AIBatching.batchBytes && !$0.patch.isEmpty })
        XCTAssertTrue(batches.dropFirst().allSatisfy { $0.continuation.contains("中文.swift") && $0.continuation.contains("@@ -1 +1 @@") })
        XCTAssertFalse(batches.map(\.patch).joined().contains("�"))
        for size in [95_999, 96_000, 96_001] {
            let text = String(repeating: "x", count: size)
            XCTAssertEqual(AIBatching.split(text).map(\.patch).joined(), text)
        }
        XCTAssertTrue(AIBatching.split("").isEmpty)
    }
    func testLargeCommitSendsAllPartsThenSynthesizesConciseDraft() async throws {
        let context = context(), recorder = BatchHTTPRecorder(), progress = BatchProgress()
        try await withTransport(recorder) { session, config in
            let output = try await AIClient().generate(context: context, configuration: config, key: "", intent: .commit, session: session) { await progress.append($0) }
            XCTAssertTrue(output.hasPrefix("feat(tasks):"))
            for index in 1...context.batches.count { XCTAssertTrue(output.contains("fact-\(index)")) }
        }
        let requests = recorder.requests
        XCTAssertEqual(requests.count, context.batches.count + 1)
        let sentPatches = requests.dropLast().map { request -> String in
            let user = request["user"]!
            return String(user.components(separatedBy: "<staged_diff>\n")[1].components(separatedBy: "\n</staged_diff>")[0])
        }
        XCTAssertEqual(sentPatches.joined(), context.patch)
        XCTAssertTrue(requests.last!["system"]!.contains("标题 + 空行 + 改动列表"))
        XCTAssertFalse(requests.last!["user"]!.contains("<staged_diff>"))
        let titles = await progress.titles
        XCTAssertTrue(titles.contains("AI 正在分析 2/\(context.batches.count) 段"))
        XCTAssertEqual(titles.last, "AI 正在汇总提交说明")
    }
    func testVerboseIntermediateResultsAreBoundedAndKeepEveryBatchInSynthesis() async throws {
        let context = context(bytes: 1_350_000), recorder = BatchHTTPRecorder(); recorder.verbose = true
        try await withTransport(recorder) { session, config in
            let result = try await AIClient().generate(context: context, configuration: config, key: "", intent: .commit, session: session)
            for index in 1...context.batches.count { XCTAssertTrue(result.contains("fact-\(index)")) }
        }
        XCTAssertGreaterThan(recorder.requests.count, context.batches.count + 1)
        XCTAssertTrue(recorder.requests.allSatisfy { $0["user"]!.utf8.count < 100_000 })
    }
    func testReviewRetainsAllBatchReportsAndExplainsCrossBatchLimit() async throws {
        let context = context(), recorder = BatchHTTPRecorder()
        try await withTransport(recorder) { session, config in
            let result = try await AIClient().generate(context: context, configuration: config, key: "", intent: .review, session: session)
            XCTAssertTrue(result.contains("跨段、跨文件"))
            for index in 1...context.batches.count { XCTAssertTrue(result.contains("fact-\(index)")) }
        }
        XCTAssertEqual(recorder.requests.count, context.batches.count)
        XCTAssertTrue(recorder.requests.allSatisfy { $0["system"]!.contains("审查给定暂存 diff") })
    }
    func testMiddleBatchErrorOrTruncationNeverProducesPartialDraft() async throws {
        for truncated in [false, true] {
            let recorder = BatchHTTPRecorder()
            if truncated { recorder.truncateAt = 2 } else { recorder.failAt = 2 }
            try await withTransport(recorder) { session, config in
                do {
                    _ = try await AIClient().generate(context: context(), configuration: config, key: "", intent: .commit, session: session)
                    XCTFail("A partial result must not be returned")
                } catch { XCTAssertTrue(error.localizedDescription.contains(truncated ? "截断" : "503")) }
            }
            XCTAssertEqual(recorder.requests.count, 2)
        }
    }
    func testSecondOfTwoBatchesReportsEmptyTruncationWithoutSynthesizingPartialDraft() async throws {
        let context = context(bytes: 130_000), recorder = BatchHTTPRecorder(); recorder.emptyReasoningAt = 2
        XCTAssertEqual(context.batches.count, 2)
        try await withTransport(recorder) { session, config in
            do {
                _ = try await AIClient().generate(context: context, configuration: config, key: "", intent: .commit, session: session)
                XCTFail("An incomplete analysis must not become a draft")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("2/2"))
                XCTAssertTrue(error.localizedDescription.contains("截断"))
                XCTAssertTrue(error.localizedDescription.contains("思考 Token：4096"))
                XCTAssertFalse(error.localizedDescription.contains("private-analysis"))
            }
        }
        XCTAssertEqual(recorder.requests.count, 2)
    }
    func testQwenCommitAnalysisAndSynthesisUseDirectOutputWhileReviewKeepsProviderDefault() async throws {
        for intent in [AIIntent.commit, .review] {
            let context = context(), recorder = BatchHTTPRecorder()
            try await withTransport(recorder, qwen: true) { session, config in
                let output = try await AIClient().generate(context: context, configuration: config, key: "", intent: intent, session: session)
                XCTAssertTrue(output.contains("fact-1"))
            }
            XCTAssertEqual(recorder.requests.count, context.batches.count + (intent == .commit ? 1 : 0))
            XCTAssertTrue(recorder.requests.allSatisfy { $0["thinking"] == (intent == .commit ? "off" : "default") })
        }
    }
    func testDeepSeekCommitAcrossFortyFiveFilesFinishesAllFourBatchesAndSynthesis() async throws {
        let files = (1...45).map { "module\($0).swift" }
        let patch = files.map { path in
            "diff --git a/\(path) b/\(path)\n--- a/\(path)\n+++ b/\(path)\n@@ -0,0 +1,368 @@\n" + String(repeating: "+// synthetic change\n", count: 368)
        }.joined()
        let context = AIContext(stamp: context().stamp, included: files, excluded: [], patch: patch, whitespaceResult: "未执行测试")
        XCTAssertEqual(context.included.count, 45)
        XCTAssertEqual(context.batches.count, 4)
        XCTAssertTrue((350_000...360_000).contains(patch.utf8.count))
        let recorder = BatchHTTPRecorder()
        try await withTransport(recorder, host: "api.deepseek.com") { session, config in
            var config = config; config.model = "deepseek-flash"
            let result = try await AIClient().generate(context: context, configuration: config, key: "", intent: .commit, session: session)
            XCTAssertTrue(result.hasPrefix("feat(tasks):"))
            for index in 1...4 { XCTAssertTrue(result.contains("fact-\(index)")) }
        }
        XCTAssertEqual(recorder.requests.count, 5)
        XCTAssertTrue(recorder.requests.allSatisfy { $0["deepseekThinking"] == "disabled" })
        let sentPatches = recorder.requests.prefix(4).map { request in
            String(request["user"]!.components(separatedBy: "<staged_diff>\n")[1].components(separatedBy: "\n</staged_diff>")[0])
        }
        XCTAssertEqual(sentPatches.joined(), patch)
    }
    func testCancellationBetweenBatchesSendsNoFurtherRequests() async throws {
        let recorder = BatchHTTPRecorder(), reachedSecond = expectation(description: "second batch progress")
        try await withTransport(recorder) { session, config in
            let task = Task {
                try await AIClient().generate(context: context(), configuration: config, key: "", intent: .commit, session: session) { title in
                    if title.contains("2/") { reachedSecond.fulfill(); try? await Task.sleep(nanoseconds: 5_000_000_000) }
                }
            }
            await fulfillment(of: [reachedSecond], timeout: 2)
            task.cancel()
            do { _ = try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        }
        XCTAssertEqual(recorder.requests.count, 1)
    }
    func testLaterBatchTimeoutStopsWithoutSynthesis() async throws {
        let recorder = BatchHTTPRecorder(); recorder.waitAt = 2
        try await withTransport(recorder) { session, config in
            do {
                _ = try await AIClient().generate(context: context(), configuration: config, key: "", intent: .commit, session: session, timeout: 0.2)
                XCTFail("Expected timeout")
            } catch { XCTAssertTrue(error.localizedDescription.contains("已停止等待")) }
        }
        XCTAssertEqual(recorder.requests.count, 2)
    }
    func testTotalBoundRejectsBeforeNetworkAndAcceptsExactBoundary() async throws {
        XCTAssertNoThrow(try AIBatching.validate(String(repeating: "a", count: 2_000_000)))
        let oversized = AIContext(stamp: context().stamp, included: ["generated.txt"], excluded: [], patch: String(repeating: "a", count: 2_000_001), whitespaceResult: "未执行测试")
        let recorder = BatchHTTPRecorder()
        try await withTransport(recorder) { session, config in
            do {
                _ = try await AIClient().generate(context: oversized, configuration: config, key: "", intent: .commit, session: session)
                XCTFail("Expected local size guard")
            } catch { XCTAssertTrue(error.localizedDescription.contains("2 MB")) }
        }
        XCTAssertTrue(recorder.requests.isEmpty)
    }
}
