// Copyright (c) 2026 zhiyu
// SPDX-License-Identifier: LicenseRef-Sprig-NC-SA-1.0

import Foundation
import Darwin

public enum PushStrategy: String, Codable, CaseIterable, Sendable {
    case merge, rebase
    public var title: String { self == .merge ? "Merge · 合并" : "Rebase · 变基" }
}
public enum PushPhase: String, Codable, Sendable { case ready, protecting, integrating, restoring, restoreConflict }

/// Stored in the worktree's Git directory, so recovery survives app restarts and
/// never confuses two worktrees. A stash is identified by OID, never stash@{0}.
public struct PushSession: Codable, Sendable {
    public var id = UUID().uuidString
    public let destination: PushDestination
    public let pushURL: String
    public let branchRef: String
    public var expectedOID: String
    public let strategy: PushStrategy
    public var phase: PushPhase = .ready
    public var stashOID: String?
    public var stashRestored = false
    public var stashMarker = ""
    public var integrationOID: String?
    public var integrationCommand: String?
    public var recoveryRef: String { "refs/sprig/push/" + id }
    public var needsRestoreReview: Bool { phase == .restoring || phase == .restoreConflict }
    public var status: String {
        switch phase {
        case .ready: return "待推送 → \(destination.remote)/\(destination.branch)"
        case .protecting: return "同步暂停 · 检查自动储藏"
        case .integrating: return "同步暂停 · \(strategy == .merge ? "Merge" : "Rebase") 待处理"
        case .restoring, .restoreConflict: return "同步暂停 · 请核对恢复的本地修改"
        }
    }
}

/// Separate from Git's index lock: serializes Sprig sync sessions without blocking
/// Git's own index writes. flock is released even after a process crash.
private final class PushLock {
    private let fd: Int32
    init(_ url: URL) throws {
        fd = Darwin.open(url.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw GitError.message("无法创建推送锁。") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(fd); throw GitError.message("另一个 Sprig 窗口正在同步此仓库。") }
    }
    deinit { flock(fd, LOCK_UN); Darwin.close(fd) }
}

extension GitRepository {
    private var pushSessionURL: URL { gitDirectory.appendingPathComponent("sprig-push.json") }
    public func pushSession() throws -> PushSession? {
        guard FileManager.default.fileExists(atPath: pushSessionURL.path) else { return nil }
        return try JSONDecoder().decode(PushSession.self, from: Data(contentsOf: pushSessionURL))
    }
    private func savePush(_ session: PushSession) throws {
        try JSONEncoder().encode(session).write(to: pushSessionURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pushSessionURL.path)
    }
    private func pushAddress(_ destination: PushDestination) async throws -> String {
        guard !destination.remote.hasPrefix("-"), try await remotes().contains(destination.remote) else { throw GitError.message("请选择已有的远程仓库。") }
        _ = try await checked(["check-ref-format", "refs/heads/" + destination.branch])
        let urls = try await checked(["remote", "get-url", "--push", "--all", destination.remote]).split(separator: "\n").map(String.init)
        guard urls.count == 1, let url = urls.first, !url.hasPrefix("-") else { throw GitError.message("自动同步需要唯一的推送地址；此远端配置了多个 push URL，请先调整配置。") }
        return url
    }
    private func validatePush(_ session: PushSession, checkHead: Bool = true) async throws {
        let current = try await stamp()
        guard current.branch == session.branchRef, !checkHead || current.head == session.expectedOID else {
            throw GitError.message("分支或提交已在外部改变。请取消此次待推送任务，再重新确认推送；当前代码和储藏均会保留。")
        }
        guard try await pushAddress(session.destination) == session.pushURL else { throw GitError.message("远程推送地址已改变，请取消此次任务并重新确认推送目标。") }
    }
    private func validateIntegration(_ session: PushSession) async throws {
        if session.integrationCommand == "rebase" {
            let directory = ["rebase-merge", "rebase-apply"].map { gitDirectory.appendingPathComponent($0) }.first { FileManager.default.fileExists(atPath: $0.path) }
            guard let directory,
                  (try? String(contentsOf: directory.appendingPathComponent("head-name")).trimmingCharacters(in: .newlines)) == session.branchRef,
                  (try? String(contentsOf: directory.appendingPathComponent("orig-head")).trimmingCharacters(in: .newlines)) == session.expectedOID else { throw GitError.message("当前 Rebase 与同步任务不一致，请先在外部处理。") }
        } else {
            try await validatePush(session)
            guard (try? String(contentsOf: gitDirectory.appendingPathComponent("MERGE_HEAD")).trimmingCharacters(in: .newlines)) == session.integrationOID else { throw GitError.message("当前 Merge 与同步任务不一致，请先在外部处理。") }
        }
    }
    private func isAncestor(_ a: String, _ b: String) async throws -> Bool {
        let result = try await runner.run(["merge-base", "--is-ancestor", a, b], at: root)
        guard result.code == 0 || result.code == 1 else { throw GitError.message(result.error) }
        return result.code == 0
    }
    private func fetchPushBranch(_ session: PushSession) async throws -> String? {
        let ref = "refs/heads/" + session.destination.branch
        let exists = try await runner.run(["ls-remote", "--exit-code", "--refs", session.pushURL, ref], at: root, timeout: 120)
        if exists.code == 2 { return nil } // Creating a new remote branch.
        guard exists.code == 0 else { throw GitError.message(exists.error + exists.text) }
        // Fetch from the PUSH URL, which may differ from the remote's fetch URL.
        // A private ref avoids racing with another client's FETCH_HEAD updates.
        _ = try await checked(["fetch", "--no-tags", "--no-write-fetch-head", session.pushURL, "+" + ref + ":" + session.recoveryRef], timeout: 120)
        return try await verifiedRevision(session.recoveryRef)
    }
    private func protectPushWork(_ session: inout PushSession) async throws {
        let state = try await snapshot()
        guard state.operation == nil, !state.files.contains(where: \.conflict) else { throw GitError.message("请先处理当前 Git 操作和冲突。") }
        guard !state.files.isEmpty else { return }
        guard !state.files.contains(where: \.submodule) else { throw GitError.message("检测到子模块修改，请先自行提交或储藏子模块内容，再继续推送。") }
        session.stashMarker = "Sprig auto-sync " + UUID().uuidString
        session.phase = .protecting; try savePush(session)
        _ = try await stashSave(session.stashMarker, includeUntracked: true)
        try await recoverPushStash(&session)
        try await requireClean()
    }
    private func protectIgnoredFiles(from localOID: String, to remoteOID: String) async throws {
        // Git checkout/rebase may overwrite ignored files. Stash -u deliberately
        // leaves them alone, so refuse only incoming paths that actually collide.
        let names = try await checked(["diff", "--name-only", "--no-renames", "-z", localOID, remoteOID, "--"]).split(separator: "\0").map(String.init)
        for start in stride(from: 0, to: names.count, by: 100) {
            let paths = Array(names[start..<min(start + 100, names.count)])
            let ignored = try await checked(["ls-files", "--others", "--ignored", "--exclude-standard", "--directory", "-z", "--"] + paths)
            guard ignored.isEmpty else { throw GitError.message("远端变更与本地被忽略的文件重叠，请先移走这些文件再继续同步：\n" + ignored.replacingOccurrences(of: "\0", with: "\n")) }
        }
    }
    private func recoverPushStash(_ session: inout PushSession) async throws {
        if session.stashOID == nil {
            session.stashOID = try await stashes().first { $0.subject.hasSuffix(": " + session.stashMarker) }?.oid
        }
        guard session.stashOID != nil else { throw GitError.message("未找到自动储藏。请检查储藏列表与工作区，再取消本次同步任务。") }
        session.phase = .ready; try savePush(session)
    }
    private func restorePushWork(_ session: inout PushSession) async throws {
        guard let oid = session.stashOID, !session.stashRestored else { return }
        try await requireClean()
        session.phase = .restoring; try savePush(session)
        do {
            _ = try await checked(["stash", "apply", "--index", oid], timeout: 120)
            session.stashRestored = true; session.phase = .ready; try savePush(session)
        } catch {
            session.phase = .restoreConflict; try savePush(session)
            throw GitError.message("恢复本地修改未完成，推送已暂停。自动储藏 \(oid.prefix(10)) 仍保留，请解决冲突并核对暂存区；完成后点击“恢复已核对，继续”。\n" + error.localizedDescription)
        }
    }
    private func removeRestoredStash(_ session: inout PushSession) async throws {
        guard session.stashRestored, let oid = session.stashOID else { return }
        if let stash = try await stashes().first(where: { $0.oid == oid }) { _ = try await dropStash(stash) }
        session.stashOID = nil; session.stashRestored = false; try savePush(session)
    }
    private func finishPush(_ session: inout PushSession) async throws {
        try await removeRestoredStash(&session)
        _ = try await checked(["update-ref", "-d", session.recoveryRef])
        try FileManager.default.removeItem(at: pushSessionURL)
    }
    public static func isPushRace(_ result: CommandResult) -> Bool {
        // Porcelain distinguishes client non-fast-forward rejection from server
        // hooks, protected branches, auth errors, and transport failures.
        result.code != 0 && result.text.split(separator: "\n").contains {
            $0.hasPrefix("!\t") && (($0.contains("[rejected]") && ($0.contains("(fetch first)") || $0.contains("(non-fast-forward)"))) || $0.hasSuffix("[remote rejected] (incorrect old value provided)"))
        }
    }

    public func synchronizedPush(to destination: PushDestination, expectedOID: String, strategy: PushStrategy,
                                 progress: @Sendable (String) async -> Void = { _ in }) async throws -> String {
        let lock = try PushLock(gitDirectory.appendingPathComponent("sprig-push.lock")); defer { withExtendedLifetime(lock) {} }
        guard try pushSession() == nil else { throw GitError.message("已有待完成的同步推送，请先继续或取消该任务。") }
        let current = try await stamp(), state = try await snapshot()
        guard current.head == expectedOID, current.head != "(initial)", current.branch != "(detached)" else { throw GitError.message("自动同步需要当前本地分支，且提交未改变。请重新确认推送。") }
        guard state.operation == nil, !state.files.contains(where: \.conflict) else { throw GitError.message("请先完成当前 Git 操作并解决冲突。") }
        let url = try await pushAddress(destination)
        var session = PushSession(destination: destination, pushURL: url, branchRef: current.branch, expectedOID: expectedOID, strategy: strategy)
        try savePush(session)
        return try await drivePush(&session, progress: progress)
    }

    public func resumeSynchronizedPush(restorationReviewed: Bool = false,
                                       progress: @Sendable (String) async -> Void = { _ in }) async throws -> String {
        let lock = try PushLock(gitDirectory.appendingPathComponent("sprig-push.lock")); defer { withExtendedLifetime(lock) {} }
        guard var session = try pushSession() else { throw GitError.message("当前没有待继续的同步推送。") }
        if session.phase == .protecting { try await recoverPushStash(&session) }
        if session.phase == .integrating {
            let state = try await snapshot()
            guard !state.files.contains(where: \.conflict) else { throw GitError.message("请先解决冲突文件，并右键选择“标记为已解决”。") }
            guard let operation = state.operation, let command = session.integrationCommand,
                  (command == "rebase" && operation.hasPrefix("Rebase")) || (command == "merge" && operation.hasPrefix("Merge")) else {
                throw GitError.message("Git 操作已在外部结束，请取消本次同步任务，核对代码后重新推送。自动储藏仍会保留。")
            }
            try await validateIntegration(session)
            await progress("继续 \(session.strategy.title)")
            _ = try await continueOperation(abort: false)
            session.expectedOID = try await headOID(); session.phase = .ready; try savePush(session)
        }
        try await validatePush(session)
        if session.needsRestoreReview {
            guard restorationReviewed else { throw GitError.message("请核对自动储藏是否完整恢复，再点击“恢复已核对，继续”；不会再次自动套用储藏。") }
            let state = try await snapshot()
            guard state.operation == nil, !state.files.contains(where: \.conflict) else { throw GitError.message("请先解决恢复过程中产生的冲突。") }
            // Keep this backup for manual recovery even after the session finishes.
            session.stashOID = nil; session.stashRestored = false; session.phase = .ready; try savePush(session)
        }
        if session.stashOID != nil && !session.stashRestored { try await restorePushWork(&session) }
        return try await drivePush(&session, progress: progress)
    }

    private func drivePush(_ session: inout PushSession, progress: @Sendable (String) async -> Void) async throws -> String {
        do {
            for attempt in 0..<3 {
                try await validatePush(session)
                let state = try await snapshot()
                guard state.operation == nil, !state.files.contains(where: \.conflict) else { throw GitError.message("请先处理当前 Git 操作或冲突。") }
                await progress(attempt == 0 ? "获取目标分支最新提交" : "远端再次更新 · 重新同步 \(attempt)/2")
                let remoteOID = try await fetchPushBranch(session)
                try await validatePush(session)
                if let remoteOID, try await !isAncestor(remoteOID, session.expectedOID) {
                    let fastForward = try await isAncestor(session.expectedOID, remoteOID)
                    let base = try await runner.run(["merge-base", session.expectedOID, remoteOID], at: root)
                    guard base.code == 0 else { throw GitError.message("本地与目标分支没有可用共同祖先；请检查目标分支或浅克隆范围，不会自动合并。") }
                    try await protectIgnoredFiles(from: session.expectedOID, to: remoteOID)
                    try await removeRestoredStash(&session)
                    await progress("保护尚未提交的修改")
                    try await protectPushWork(&session)
                    try await validatePush(session); try await requireClean()
                    session.integrationOID = remoteOID
                    session.integrationCommand = fastForward || session.strategy == .merge ? "merge" : "rebase"
                    session.phase = .integrating; try savePush(session)
                    await progress(fastForward ? "快进到远端最新提交" : "正在 \(session.strategy.title)")
                    let args = fastForward ? ["merge", "--no-overwrite-ignore", "--no-autostash", "--ff-only", remoteOID] : session.strategy == .merge ? ["merge", "--no-overwrite-ignore", "--no-autostash", "--no-edit", "--no-ff", remoteOID] : ["rebase", "--no-autostash", remoteOID]
                    do { _ = try await checked(args, timeout: 120) }
                    catch {
                        // An interrupted command (or hook/other client) may have
                        // changed HEAD. Never silently adopt an unverified commit.
                        if try await snapshot().operation == nil, try await headOID() == session.expectedOID {
                            session.phase = .ready; try savePush(session)
                        }
                        throw error
                    }
                    session.expectedOID = try await headOID(); session.phase = .ready; try savePush(session)
                    await progress("恢复本地修改与暂存状态")
                    try await restorePushWork(&session)
                }
                try await validatePush(session)
                await progress("推送到 \(session.destination.remote)/\(session.destination.branch)")
                let result = try await runner.run(["-c", "remote.\(session.destination.remote).mirror=false", "-c", "push.followTags=false", "push", "--porcelain", "--no-force", "--no-follow-tags", session.destination.remote, session.expectedOID + ":refs/heads/" + session.destination.branch], at: root, timeout: 120)
                if result.code == 0 {
                    var warning = ""
                    do {
                        let branch = String(session.branchRef.dropFirst("refs/heads/".count))
                        _ = try await checked(["config", "branch.\(branch).remote", session.destination.remote])
                        _ = try await checked(["config", "branch.\(branch).merge", "refs/heads/" + session.destination.branch])
                    } catch { warning = "\n保存本地跟踪配置失败：" + error.localizedDescription }
                    let message = "同步并推送完成 → \(session.destination.remote)/\(session.destination.branch) · \(session.expectedOID.prefix(8))"
                    do { try await finishPush(&session) }
                    catch { return message + "\n推送已成功；清理自动储藏或恢复记录失败，请核对后取消待推送任务。\n" + error.localizedDescription }
                    return message + warning
                }
                guard Self.isPushRace(result) else { throw GitError.message("推送失败，已保留本地提交，可单独重试。\n" + result.error + result.text) }
                if attempt == 2 { throw GitError.message("远端连续更新，已停止自动重试。已完成的合并和本地修改均保留，请稍后继续推送。") }
            }
            throw GitError.message("推送未完成。")
        } catch {
            if session.phase == .protecting { try? await recoverPushStash(&session) }
            if session.phase == .ready, session.stashOID != nil, !session.stashRestored {
                do { try await restorePushWork(&session) }
                catch { throw error }
            }
            if session.phase == .integrating {
                throw GitError.message("同步已暂停，尚未推送。请在编辑器解决冲突、右键标记已解决，然后继续；也可中止并恢复原修改。\n" + error.localizedDescription)
            }
            throw error
        }
    }

    public func cancelSynchronizedPush() async throws -> String {
        let lock = try PushLock(gitDirectory.appendingPathComponent("sprig-push.lock")); defer { withExtendedLifetime(lock) {} }
        guard var session = try pushSession() else { return "没有待取消的同步推送。" }
        let current = try await stamp(), state = try await snapshot()
        if session.phase == .integrating, state.operation != nil {
            guard current.branch == session.branchRef || (session.integrationCommand == "rebase" && current.branch == "(detached)"),
                  (session.integrationCommand == "rebase" && state.operation?.hasPrefix("Rebase") == true) || (session.integrationCommand == "merge" && state.operation?.hasPrefix("Merge") == true) else { throw GitError.message("当前 Git 操作与同步任务不一致，请先在外部处理。") }
            try await validateIntegration(session)
            _ = try await continueOperation(abort: true)
            session.expectedOID = try await headOID(); session.phase = .ready; try savePush(session)
        }
        if session.phase == .protecting { try? await recoverPushStash(&session) }
        let after = try await stamp(), afterState = try await snapshot()
        if after.branch == session.branchRef, after.head == session.expectedOID,
           !session.needsRestoreReview, session.stashOID != nil, !session.stashRestored,
           afterState.files.isEmpty, afterState.operation == nil {
            try await restorePushWork(&session)
        }
        let retained = session.stashOID != nil && !session.stashRestored
        try await finishPush(&session)
        return "已取消后续推送；已完成的提交与合并均保留。" + (retained ? "\n自动储藏仍在“储藏”页面，请手动核对恢复。" : "")
    }

    public func markResolved(_ file: ChangedFile) async throws {
        let state = try await snapshot()
        guard state.files.contains(where: { $0.path == file.path && $0.conflict }) else { throw GitError.message("此文件已没有未解决冲突，请刷新。") }
        _ = try await checked(["add", "--all", "--", file.path])
    }
}
