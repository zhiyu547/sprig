// Copyright (c) 2026 zhiyu
// SPDX-License-Identifier: LicenseRef-Sprig-NC-SA-1.0

import XCTest
@testable import GitCore

final class CommandRunnerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("sprig-command-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func runner(_ body: String) throws -> CommandRunner {
        let script = root.appendingPathComponent("fake-git.py")
        try Data(("#!/usr/bin/python3\n" + body + "\n").utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return CommandRunner(executable: script.path)
    }

    // The child deliberately keeps both inherited pipes open after the parent
    // receives SIGTERM. Every fixture exits on its own within four seconds.
    private let childHoldingPipes = """
    import os, signal, time
    if os.fork() == 0:
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        with open('child-ready', 'w') as marker:
            marker.write('ready')
        os.write(2, b'child ready\\n')
        time.sleep(1.8)
        with open('orphan-write', 'w') as marker:
            marker.write('child survived cancellation')
        time.sleep(1.2)
        os._exit(0)
    time.sleep(3.5)
    """

    func testTimeoutDoesNotWaitForChildHoldingPipesAndStopsItsWrites() async throws {
        let command = try runner(childHoldingPipes)
        let started = Date()
        do {
            _ = try await command.run(["push"], at: root, timeout: 0.8)
            XCTFail("Expected the short operation deadline to stop the command")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("超过"), error.localizedDescription)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("child-ready").path), "Fixture must start its child before timing out")
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "A child holding a pipe must not extend the operation deadline indefinitely")
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("orphan-write").path), "Cancelled Git helpers must not continue writing after the operation ends")
    }

    func testTaskCancellationStopsChildAndReturnsWithoutWaitingForItsExit() async throws {
        let command = try runner(childHoldingPipes)
        let directory = root!
        let task = Task { try await command.run(["push"], at: directory, timeout: 10) }
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("child-ready").path), "Fixture must start its child before cancellation")
        let cancelledAt = Date()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch { }
        XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 1.2, "Cancellation must include bounded child-process cleanup")
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("orphan-write").path))
    }

    func testExitedParentCannotLeaveChildHoldingPipesOrWriting() async throws {
        let command = try runner(childHoldingPipes.replacingOccurrences(of: "time.sleep(3.5)", with: "os._exit(0)"))
        let started = Date()
        do {
            _ = try await command.run(["push"], at: root, timeout: 10)
            XCTFail("Expected unfinished helper cleanup to be reported")
        } catch { XCTAssertTrue(error.localizedDescription.contains("子进程"), error.localizedDescription) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("orphan-write").path))
    }

    func testDrainsBothPipesWithoutLosingOutputOrDeadlocking() async throws {
        let command = try runner("""
        import os, threading
        def write_all(fd, value, count):
            for _ in range(count):
                os.write(fd, value)
        output = threading.Thread(target=write_all, args=(1, b'O' * 8192, 256))
        errors = threading.Thread(target=write_all, args=(2, b'E' * 1000, 60))
        output.start()
        errors.start()
        output.join()
        errors.join()
        """)
        let result = try await command.run(["status"], at: root, timeout: 5)
        XCTAssertEqual(result.code, 0)
        XCTAssertEqual(result.data, Data(repeating: 79, count: 2_097_152))
        XCTAssertEqual(result.error, String(repeating: "E", count: 60_000))
    }

    func testPreviewOutputLimitStillRejectsOversizedContent() async throws {
        let command = try runner("import os\nos.write(1, b'x' * 8192)")
        do {
            _ = try await command.run(["diff"], at: root, limit: 1024, timeout: 5)
            XCTFail("Expected an oversized preview to be rejected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("预览上限"), error.localizedDescription)
        }
    }
}
