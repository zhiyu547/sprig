// Copyright (c) 2026 zhiyu
// SPDX-License-Identifier: LicenseRef-Sprig-NC-SA-1.0

import Foundation

/// Returns promptly even if an OS credential call cannot cooperate with cancellation.
/// The abandoned worker cannot deliver a late value to the caller.
public func withDeadline<Value: Sendable>(seconds: TimeInterval, message: String,
    operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
    let completion = DeadlineCompletion<Value>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            completion.install(continuation)
            let worker = Task.detached {
                do { try Task.checkCancellation(); completion.finish(.success(try await operation())) }
                catch { completion.finish(.failure(error)) }
            }
            let timer = Task.detached {
                do {
                    try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                    completion.finish(.failure(GitError.message(message)))
                } catch { /* The operation or caller finished first. */ }
            }
            completion.attach([worker, timer])
        }
    } onCancel: { completion.finish(.failure(CancellationError())) }
}

private final class DeadlineCompletion<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var result: Result<Value, Error>?
    private var tasks: [Task<Void, Never>] = []

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if let result { lock.unlock(); continuation.resume(with: result) }
        else { self.continuation = continuation; lock.unlock() }
    }
    func attach(_ tasks: [Task<Void, Never>]) {
        lock.lock()
        if result != nil { lock.unlock(); tasks.forEach { $0.cancel() } }
        else { self.tasks = tasks; lock.unlock() }
    }
    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation, tasks = self.tasks
        self.continuation = nil; self.tasks = []
        lock.unlock()
        tasks.forEach { $0.cancel() }
        continuation?.resume(with: result)
    }
}
