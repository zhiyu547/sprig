// Copyright (c) 2026 zhiyu
// SPDX-License-Identifier: LicenseRef-Sprig-NC-SA-1.0

import XCTest
@testable import GitCore

// Deliberately model a synchronous OS call that does not observe task cancellation.
private func blockingCredential(_ gate: DispatchSemaphore) { gate.wait() }

final class DeadlineTests: XCTestCase {
    @MainActor func testBlockedCredentialWorkerDoesNotBlockMainActorOrTimeout() async throws {
        let gate = DispatchSemaphore(value: 0)
        let entered = expectation(description: "worker started")
        let start = Date()
        let task = Task {
            try await withDeadline(seconds: 0.12, message: "credential timeout") {
                entered.fulfill(); blockingCredential(gate); return "late credential"
            }
        }
        await fulfillment(of: [entered], timeout: 1)
        // Reaching here while the worker is blocked proves the main actor can respond.
        do { _ = try await task.value; XCTFail("Expected deadline") }
        catch { XCTAssertEqual(error.localizedDescription, "credential timeout") }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        gate.signal() // A late completion must not resume the continuation twice.
    }
    func testCancellationReturnsBeforeBlockedWorkerCompletes() async throws {
        let gate = DispatchSemaphore(value: 0), entered = expectation(description: "worker started")
        let task = Task { try await withDeadline(seconds: 30, message: "timeout") { entered.fulfill(); blockingCredential(gate); return "late" } }
        await fulfillment(of: [entered], timeout: 1)
        let start = Date(); task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5); gate.signal()
    }
    func testSuccessAndImmediateCancellationRace() async throws {
        let result = try await withDeadline(seconds: 1, message: "timeout") { 42 }
        XCTAssertEqual(result, 42)
        for _ in 0..<30 {
            let task = Task { try await withDeadline(seconds: 1, message: "timeout") { try await Task.sleep(nanoseconds: 50_000_000); return 1 } }
            task.cancel()
            do { _ = try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        }
    }
}

/// /headers delivers headers but never finishes its body; /silent sends nothing.
private final class WaitingAIProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.url!.path.contains("headers") {
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{".utf8))
        }
    }
    override func stopLoading() {}
}
extension AIClientTests {
    func testHardDeadlineCoversHeadersAndBody() async throws {
        for route in ["silent", "headers"] {
            let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [WaitingAIProtocol.self]
            let session = URLSession(configuration: c); defer { session.invalidateAndCancel() }
            let start = Date()
            do {
                _ = try await AIClient().generate(context: context, configuration: config("https://fixture.invalid/" + route), key: "", intent: .commit, session: session, timeout: 0.15)
                XCTFail("Expected deadline")
            } catch { XCTAssertTrue(error.localizedDescription.contains("已停止等待")) }
            XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        }
    }
    func testCancelWaitingHTTP() async throws {
        let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [WaitingAIProtocol.self]
        let session = URLSession(configuration: c); defer { session.invalidateAndCancel() }
        let task = Task { try await AIClient().generate(context: context, configuration: config("https://fixture.invalid/silent"), key: "", intent: .commit, session: session) }
        try await Task.sleep(nanoseconds: 50_000_000); let start = Date(); task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
    }
}
