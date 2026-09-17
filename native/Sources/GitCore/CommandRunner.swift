// Copyright (c) 2026 zhiyu
// SPDX-License-Identifier: LicenseRef-Sprig-NC-SA-1.0

import Foundation
import Darwin

public enum GitError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

private final class CommandState: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var reason: String?

    func attach(_ process: Process) {
        lock.lock(); self.process = process; let stopped = reason != nil; lock.unlock()
        if stopped && process.isRunning { process.terminate() }
    }
    func stop(_ reason: String) {
        lock.lock(); if self.reason == nil { self.reason = reason }; let process = process; lock.unlock()
        if let process, process.isRunning {
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
    }
    func failure() -> String? { lock.lock(); defer { lock.unlock() }; return reason }
}

private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    func append(_ data: Data, limit: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let remaining = max(0, limit - bytes.count)
        bytes.append(data.prefix(remaining))
        return data.count <= remaining
    }
    var data: Data { lock.lock(); defer { lock.unlock() }; return bytes }
}

public struct CommandResult: Sendable {
    public let data: Data
    public let error: String
    public let code: Int32
    public var text: String { String(decoding: data, as: UTF8.self) }
}

public struct CommandRunner: Sendable {
    public let executable: String
    public init(executable: String = "/usr/bin/git") { self.executable = executable }

    public func run(_ arguments: [String], at directory: URL, limit: Int = 4_000_000, timeout: TimeInterval = 15, indexFile: URL? = nil) async throws -> CommandResult {
        try Task.checkCancellation()
        let state = CommandState()
        return try await withTaskCancellationHandler(operation: {
            try await Task.detached(priority: .userInitiated) {
                try execute(arguments, at: directory, limit: limit, timeout: timeout, state: state, indexFile: indexFile)
            }.value
        }, onCancel: { state.stop("读取已取消") })
    }

    private func execute(_ arguments: [String], at directory: URL, limit: Int, timeout: TimeInterval, state: CommandState, indexFile: URL?) throws -> CommandResult {
        if let failure = state.failure() { throw GitError.message(failure) }
        let process = Process(), stdout = Pipe(), stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.currentDirectoryURL = directory
        // Stash uses internal magic pathspecs when removing saved untracked files.
        // It accepts no user paths here; literal mode would silently leave those files behind.
        let pathMode = arguments.first == "stash" ? [] : ["--literal-pathspecs"]
        process.arguments = ["--no-optional-locks"] + pathMode + ["-c", "core.fsmonitor=false", "-c", "color.ui=false"] + arguments
        var environment = ProcessInfo.processInfo.environment
        for key in ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_EXTERNAL_DIFF", "GIT_DIFF_OPTS", "GIT_LITERAL_PATHSPECS", "GIT_GLOB_PATHSPECS", "GIT_NOGLOB_PATHSPECS", "GIT_ICASE_PATHSPECS"] { environment.removeValue(forKey: key) }
        environment["LC_ALL"] = "C"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_EDITOR"] = "/usr/bin/true"
        environment["GIT_SEQUENCE_EDITOR"] = "/usr/bin/true"
        if let indexFile { environment["GIT_INDEX_FILE"] = indexFile.path }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout; process.standardError = stderr
        do { try process.run() } catch { throw GitError.message("无法启动 Git：\(error.localizedDescription)") }
        state.attach(process)
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { state.stop("Git 操作超过 \(Int(timeout)) 秒，已停止。请刷新确认仓库状态后重试。") }
        timer.resume()
        defer { timer.cancel() }
        let output = OutputBuffer(), errors = OutputBuffer(), group = DispatchGroup()
        for (pipe, buffer, bound) in [(stdout, output, limit), (stderr, errors, 64_000)] {
            group.enter()
            DispatchQueue.global().async {
                defer { try? pipe.fileHandleForReading.close(); group.leave() }
                while let chunk = try? pipe.fileHandleForReading.read(upToCount: 32_768), !chunk.isEmpty {
                    if !buffer.append(chunk, limit: bound) { state.stop("输出超过预览上限，已停止读取；请在外部工具中查看此内容。") }
                }
            }
        }
        process.waitUntilExit(); group.wait()
        if let failure = state.failure() { throw GitError.message(failure) }
        return CommandResult(data: output.data, error: String(decoding: errors.data, as: UTF8.self), code: process.terminationStatus)
    }
}
