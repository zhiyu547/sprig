// Copyright (c) 2026 zhiyu
// SPDX-License-Identifier: LicenseRef-Sprig-NC-SA-1.0

import XCTest
@testable import GitCore

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ value: String) { lock.lock(); defer { lock.unlock() }; values.append(value) }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return values }
}

final class NetworkCommandTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("sprig-network-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func runner(_ body: String) throws -> CommandRunner {
        let path = root.appendingPathComponent("git-fixture.py")
        try Data(("#!/usr/bin/python3\n" + body).utf8).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        return CommandRunner(executable: path.path)
    }

    func testActiveTransferOutlivesIdleDeadlineAndReportsThrottledProgress() async throws {
        let command = try runner("""
        import os, time
        for i in range(11):
            os.write(2, ('Writing objects: %d%% (%d/10), 12.50 MiB | 2.00 MiB/s\\r' % (i * 10, i)).encode())
            time.sleep(0.12)
        os.write(1, b'push complete\\n')
        """)
        let recorder = ProgressRecorder()
        let operation = GitNetworkOperation(idleTimeout: 0.5, maximumDuration: 4, progress: { recorder.append($0) })
        let result = try await command.runNetwork(["push"], at: root, operation: operation)
        XCTAssertEqual(result.code, 0); XCTAssertEqual(result.text, "push complete\n")
        XCTAssertGreaterThan(recorder.all.count, 1); XCTAssertLessThanOrEqual(recorder.all.count, 8)
        XCTAssertTrue(recorder.all.last?.contains("100%") == true)
        XCTAssertTrue(recorder.all.last?.contains("12.50 MiB") == true)
        XCTAssertTrue(recorder.all.last?.contains("2.00 MiB/s") == true)
    }

    func testQuietTransportTimesOutAndActiveTransportStillHasMaximumDuration() async throws {
        for (body, expected) in [
            ("import time\ntime.sleep(3)", "没有输出"),
            ("import os, time\nfor _ in range(40):\n os.write(2, b'heartbeat\\n')\n time.sleep(0.05)", "总时长")
        ] {
            let command = try runner(body), started = Date()
            do {
                _ = try await command.runNetwork(["push"], at: root, operation: GitNetworkOperation(idleTimeout: 0.3, maximumDuration: 0.8))
                XCTFail("Expected deadline")
            } catch { XCTAssertTrue(error.localizedDescription.contains(expected), error.localizedDescription) }
            XCTAssertLessThan(Date().timeIntervalSince(started), 1.8)
        }
    }

    func testLongNetworkLogKeepsTailAndPorcelainWithoutAborting() async throws {
        let command = try runner("""
        import os, sys
        for _ in range(200):
            os.write(2, b'x' * 1000 + b'\\n')
        os.write(2, b'Writing objects: 100% (1/1), 1.00 MiB | 2.00 MiB/s, done.\\nserver-final-diagnostic\\n')
        os.write(1, b'!\\tHEAD:refs/heads/main\\t[rejected] (non-fast-forward)\\n')
        sys.exit(23)
        """)
        let recorder = ProgressRecorder()
        let result = try await command.runNetwork(["push"], at: root, operation: GitNetworkOperation(progress: { recorder.append($0) }))
        XCTAssertEqual(result.code, 23); XCTAssertTrue(GitRepository.isPushRace(result))
        XCTAssertLessThanOrEqual(result.error.utf8.count, 64_000)
        XCTAssertTrue(result.error.hasSuffix("server-final-diagnostic\n"))
        XCTAssertTrue(recorder.all.last?.contains("100%") == true)
    }

    func testNetworkCancellationBeforeLaunchAndDuringTransport() async throws {
        let command = try runner("""
        import os, time
        open('started', 'w').close()
        time.sleep(2)
        open('late-write', 'w').close()
        """)
        let operation = GitNetworkOperation(); operation.cancel()
        do { _ = try await command.runNetwork(["push"], at: root, operation: operation); XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("started").path))
        let running = GitNetworkOperation(), directory = root!
        let task = Task { try await command.runNetwork(["push"], at: directory, operation: running) }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("started").path) { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("started").path))
        running.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("late-write").path))
    }

    func testProgressParserHandlesChunkBoundariesAndRejectsArbitraryServerText() {
        var parser = GitProgressParser()
        XCTAssertNil(parser.append(Data("Writing obj".utf8)))
        XCTAssertEqual(parser.append(Data("ects: 25% (1/4), 8.00 MiB | 1.25 MiB/s\r".utf8)), "上传对象 · 25% · 8.00 MiB · 1.25 MiB/s")
        XCTAssertNil(parser.append(Data("remote: https://user:password@fixture.invalid/private\n".utf8)))
        XCTAssertNil(parser.append(Data("Writing objects: 50% (2/4) token=secret\r".utf8)))
        XCTAssertNil(parser.append(Data((String(repeating: "x", count: 100_000) + "Writing objects: 50% (2/4)\r").utf8)))
        XCTAssertEqual(parser.append(Data("remote: Resolving deltas: 100% (4/4), done.\n".utf8)), "远端解析增量 · 100%")
    }
}
