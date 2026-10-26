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
    private var reason: Error?
    func stop(_ reason: Error) { lock.lock(); defer { lock.unlock() }; if self.reason == nil { self.reason = reason } }
    func failure() -> Error? { lock.lock(); defer { lock.unlock() }; return reason }
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
        try await runCommand(arguments, at: directory, limit: limit, timeout: timeout, indexFile: indexFile, network: nil)
    }

    public func runNetwork(_ arguments: [String], at directory: URL, operation: GitNetworkOperation = GitNetworkOperation()) async throws -> CommandResult {
        try await runCommand(arguments, at: directory, limit: 4_000_000, timeout: operation.maximumDuration, indexFile: nil, network: operation)
    }

    private func runCommand(_ arguments: [String], at directory: URL, limit: Int, timeout: TimeInterval, indexFile: URL?, network: GitNetworkOperation?) async throws -> CommandResult {
        try network?.checkCancellation()
        try Task.checkCancellation()
        let state = CommandState()
        return try await withTaskCancellationHandler(operation: {
            try await Task.detached(priority: .userInitiated) {
                try execute(arguments, at: directory, limit: limit, timeout: timeout, state: state, indexFile: indexFile, network: network)
            }.value
        }, onCancel: { state.stop(CancellationError()) })
    }

    private func execute(_ arguments: [String], at directory: URL, limit: Int, timeout: TimeInterval, state: CommandState, indexFile: URL?, network: GitNetworkOperation?) throws -> CommandResult {
        if let failure = state.failure() { throw failure }
        try network?.checkCancellation()
        // Stash uses internal magic pathspecs when removing saved untracked files.
        // It accepts no user paths here; literal mode would silently leave those files behind.
        let pathMode = arguments.first == "stash" ? [] : ["--literal-pathspecs"]
        let commandArguments = ["--no-optional-locks"] + pathMode + ["-c", "core.fsmonitor=false", "-c", "color.ui=false"] + arguments
        var environment = ProcessInfo.processInfo.environment
        for key in ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_EXTERNAL_DIFF", "GIT_DIFF_OPTS", "GIT_LITERAL_PATHSPECS", "GIT_GLOB_PATHSPECS", "GIT_NOGLOB_PATHSPECS", "GIT_ICASE_PATHSPECS"] { environment.removeValue(forKey: key) }
        environment["LC_ALL"] = "C"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_EDITOR"] = "/usr/bin/true"
        environment["GIT_SEQUENCE_EDITOR"] = "/usr/bin/true"
        if let indexFile { environment["GIT_INDEX_FILE"] = indexFile.path }
        let process = try GitSubprocess(executable: executable, arguments: commandArguments, environment: environment, directory: directory)
        defer { process.finish() }
        let start = ProcessInfo.processInfo.systemUptime
        var stoppedAt: TimeInterval?, exitedAt: TimeInterval?, code: Int32?
        var output = Data(), errors = Data()
        var lastOutput = start, lastProgress = start - 1
        var parser = GitProgressParser(), pendingProgress: String?
        while true {
            let now = ProcessInfo.processInfo.systemUptime
            if network?.isCancelled == true { state.stop(CancellationError()) }
            if let network, now - lastOutput >= network.idleTimeout {
                state.stop(GitError.message("Git 连续 \(Int(network.idleTimeout)) 秒没有输出，已停止。请检查连接并确认远端状态后重试。"))
            }
            if now - start >= timeout {
                let message = network == nil ? "Git 操作超过 \(Int(timeout)) 秒，已停止。请刷新确认仓库状态后重试。" : "Git 网络操作总时长超过 \(Int(timeout)) 秒，已停止。请确认远端状态后重试。"
                state.stop(GitError.message(message))
            }
            do {
                for stream in 0...1 {
                    let chunk = try process.read(stream)
                    if !chunk.isEmpty { lastOutput = now }
                    if stream == 1, network != nil {
                        // stderr is a rolling diagnostic log, not preview data.
                        errors.append(chunk)
                        if errors.count > 64_000 { errors.removeFirst(errors.count - 64_000) }
                        if let update = parser.append(chunk) { pendingProgress = update }
                        continue
                    }
                    let bound = stream == 0 ? limit : 64_000
                    let remaining = max(0, bound - (stream == 0 ? output.count : errors.count))
                    if stream == 0 { output.append(chunk.prefix(remaining)) }
                    else { errors.append(chunk.prefix(remaining)) }
                    if chunk.count > remaining { state.stop(GitError.message("输出超过预览上限，已停止读取；请在外部工具中查看此内容。")) }
                }
                code = try process.exitCode()
            } catch { state.stop(error) }
            if let pending = pendingProgress, now - lastProgress >= 0.25, state.failure() == nil {
                network?.progress(pending); lastProgress = now; pendingProgress = nil
            }
            if code != nil, exitedAt == nil { exitedAt = now }
            if let exitedAt, process.hasOpenPipes, now - exitedAt >= 0.5 {
                state.stop(GitError.message("Git 已结束，但子进程未关闭输出；已停止，请刷新确认仓库状态。"))
            }
            if state.failure() != nil {
                if stoppedAt == nil { stoppedAt = now; process.signalGroup(SIGTERM) }
                if let stoppedAt, now - stoppedAt >= 0.3 { process.signalGroup(SIGKILL) }
                // Keep the group leader waitable through escalation, even when
                // helpers have closed their pipes but may still be writing files.
                if let stoppedAt, now - stoppedAt >= 0.3, code != nil { break }
                if let stoppedAt, now - stoppedAt >= 1 { break }
            } else if code != nil, !process.hasOpenPipes { break }
            process.poll()
        }
        if let failure = state.failure() { throw failure }
        if let pendingProgress { network?.progress(pendingProgress) }
        return CommandResult(data: output, error: String(decoding: errors, as: UTF8.self), code: code ?? -1)
    }
}
