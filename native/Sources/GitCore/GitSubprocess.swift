// Copyright (c) 2026 zhiyu
// SPDX-License-Identifier: LicenseRef-Sprig-NC-SA-1.0

import Foundation
import Darwin

/// A dedicated process group owns Git and its transport/hooks. Keep the leader
/// waitable until the pipes are closed, so its PID cannot be reused while we
/// signal the group. All methods run on the command's background worker.
final class GitSubprocess {
    let pid: pid_t
    private var descriptors: [Int32]
    private var reaped = false

    init(executable: String, arguments: [String], environment: [String: String], directory: URL) throws {
        var output: [Int32] = [-1, -1], errors: [Int32] = [-1, -1]
        guard pipe(&output) == 0 else { throw Self.systemError() }
        guard pipe(&errors) == 0 else {
            output.forEach { close($0) }
            throw Self.systemError()
        }
        var transferred = false
        defer {
            close(output[1]); close(errors[1])
            if !transferred { close(output[0]); close(errors[0]) }
        }
        for fd in [output[0], errors[0]] {
            guard fcntl(fd, F_SETFL, O_NONBLOCK) != -1 else { throw Self.systemError() }
        }
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        try Self.check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try Self.check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        // The _np spelling also builds with the macOS 13–15 SDKs used by CI.
        try Self.check(posix_spawn_file_actions_addchdir_np(&actions, directory.path))
        try Self.check(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
        try Self.check(posix_spawn_file_actions_adddup2(&actions, output[1], STDOUT_FILENO))
        try Self.check(posix_spawn_file_actions_adddup2(&actions, errors[1], STDERR_FILENO))
        // CLOEXEC_DEFAULT also prevents concurrent commands inheriting our pipes.
        try Self.check(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)))
        try Self.check(posix_spawnattr_setpgroup(&attributes, 0))
        var defaults = sigset_t(), mask = sigset_t()
        sigemptyset(&defaults); sigemptyset(&mask)
        for signal in [SIGINT, SIGTERM, SIGHUP, SIGPIPE, SIGCHLD] { sigaddset(&defaults, signal) }
        try Self.check(posix_spawnattr_setsigdefault(&attributes, &defaults))
        try Self.check(posix_spawnattr_setsigmask(&attributes, &mask))
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup($0.key + "=" + $0.value) } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var child: pid_t = 0
        try Self.check(posix_spawn(&child, executable, &actions, &attributes, argv, envp))
        pid = child; descriptors = [output[0], errors[0]]; transferred = true
    }

    var hasOpenPipes: Bool { descriptors.contains { $0 >= 0 } }

    /// Reads a bounded amount per pipe per tick so cancellation and the other
    /// stream cannot be starved by a continuously writing child.
    func read(_ stream: Int) throws -> Data {
        guard descriptors[stream] >= 0 else { return Data() }
        var output = Data(), buffer = [UInt8](repeating: 0, count: 32_768)
        for _ in 0..<8 {
            let count = Darwin.read(descriptors[stream], &buffer, buffer.count)
            if count > 0 { output.append(contentsOf: buffer.prefix(count)) }
            else if count == 0 { close(descriptors[stream]); descriptors[stream] = -1; break }
            else if errno == EAGAIN || errno == EWOULDBLOCK { break }
            else if errno != EINTR { throw Self.systemError() }
        }
        return output
    }

    func exitCode() throws -> Int32? {
        var info = siginfo_t()
        if waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) != 0 {
            if errno == EINTR { return nil }
            throw Self.systemError()
        }
        guard info.si_pid == pid else { return nil }
        return info.si_code == CLD_EXITED ? info.si_status : 128 + info.si_status
    }

    func signalGroup(_ signal: Int32) { if !reaped { kill(-pid, signal) } }

    func poll() {
        var fds = descriptors.map { pollfd(fd: $0, events: Int16(POLLIN | POLLHUP), revents: 0) }
        _ = Darwin.poll(&fds, nfds_t(fds.count), 20)
    }

    func finish() {
        guard !reaped else { return }
        for fd in descriptors where fd >= 0 { close(fd) }
        descriptors = [-1, -1]
        var status: Int32 = 0
        var result: pid_t
        repeat { result = waitpid(pid, &status, WNOHANG) } while result < 0 && errno == EINTR
        reaped = true
        if result == 0 {
            // SIGKILL has already been sent. Reap off-worker if the kernel has
            // not delivered it yet; never block the caller on a pipe or waitpid.
            let child = pid
            DispatchQueue.global().async {
                var status: Int32 = 0
                while waitpid(child, &status, 0) < 0 && errno == EINTR { }
            }
        }
    }

    deinit {
        if !reaped { signalGroup(SIGKILL); finish() }
    }
    private static func check(_ code: Int32) throws {
        if code != 0 { throw GitError.message("无法启动 Git：" + String(cString: strerror(code))) }
    }
    private static func systemError() -> GitError { .message("Git 进程读写失败：" + String(cString: strerror(errno))) }
}
