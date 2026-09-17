// Copyright (c) 2026 zhiyu
// SPDX-License-Identifier: LicenseRef-Sprig-NC-SA-1.0

import AppKit
import SwiftUI
import CryptoKit
import GitCore

enum WorkspacePage: String, CaseIterable, Identifiable { case changes = "提交", history = "历史", stashes = "储藏", console = "控制台"; var id: String { rawValue } }
struct WorkspaceSheet: Identifiable {
    let id = UUID()
    let kind: SheetKind
}
enum SheetKind {
    case settings
    case commit(CommitPreparation, Bool)
    case push(String)
    case newBranch(String?)
    case newTag(String)
    case stash
    case aiConfirm(AIContext, AIIntent)
    case aiResult(AIContext, String, AIIntent)
    case report(String, String)
}
struct OperationLog: Identifiable { let id = UUID(); let date = Date(); let title: String; let output: String; let failed: Bool }

extension RepositoryStore {
    var trackedFiles: [ChangedFile] { files.filter { !$0.untracked } }
    var untrackedFiles: [ChangedFile] { files.filter(\.untracked) }
    var hasCommitContent: Bool { synchronizedPushSession == nil && snapshot != nil && ((snapshot?.stagedCount ?? 0) > 0 || amend) && !(snapshot?.files.contains(where: \.conflict) ?? false) && snapshot?.operation == nil }
    var canCommit: Bool { !busy && hasCommitContent }
    func draftKey(_ path: String) -> String { "Sprig.draft." + SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined() }
    func saveDraft() { if let root = repository?.root.path { UserDefaults.standard.set(commitMessage, forKey: draftKey(root)) } }
    func log(_ title: String, _ output: String, failed: Bool = false) {
        let regex = try? NSRegularExpression(pattern: "(https?://)[^\\s/@]+@")
        let clean = regex?.stringByReplacingMatches(in: output, range: NSRange(output.startIndex..., in: output), withTemplate: "$1[已隐藏]@") ?? output
        console.insert(OperationLog(title: title, output: String(clean.prefix(30_000)), failed: failed), at: 0)
        console = Array(console.prefix(40))
    }
    func runOperation(_ title: String, indexPaths: Set<String> = [], _ action: @escaping (GitRepository) async throws -> String) {
        guard !busy, let repository else { return }
        indexUpdatePaths = indexPaths
        if !indexPaths.isEmpty { suspendRefreshForIndexWrite() }
        busy = true; busyTitle = title; error = nil
        if indexPaths.isEmpty { notice = nil }
        operationTask = Task {
            do {
                let output = try await action(repository); log(title, output)
                if indexPaths.isEmpty { notice = output.isEmpty ? title + "完成" : output }
            }
            catch { self.error = error.localizedDescription; log(title, error.localizedDescription, failed: true) }
            reloadPushSession()
            // Keep writes serialized until checkboxes reflect the actual index.
            if !indexPaths.isEmpty {
                do { try await refreshAfterIndexWrite(repository) }
                catch { self.error = "刷新暂存状态失败，请刷新后重试。\n" + error.localizedDescription }
            }
            busy = false; busyTitle = ""; indexUpdatePaths = []
            if indexPaths.isEmpty { needsRefresh = false; refresh() }
            else if needsRefresh { needsRefresh = false; scheduleRefresh() }
            if page == .history { loadHistory() }
        }
    }
    func confirm(_ title: String, message: String, button: String = "确认", action: @escaping () -> Void) {
        let token = repositoryToken
        let verifiedAction = { if token == self.repositoryToken { action() } else { self.error = "当前仓库已切换，请在新仓库重新确认操作。" } }
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message; alert.alertStyle = .warning
        alert.addButton(withTitle: button); alert.addButton(withTitle: "取消")
        if let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.canBecomeMain }) {
            alert.beginSheetModal(for: window) { response in if response == .alertFirstButtonReturn { verifiedAction() } }
        } else if alert.runModal() == .alertFirstButtonReturn { verifiedAction() }
    }
    func stageFiles(_ values: [ChangedFile]) { guard !values.isEmpty else { return }; runOperation("暂存 \(values.count) 个文件", indexPaths: Set(values.map(\.path))) { try await $0.stage(values); return "已暂存 \(values.count) 个文件" } }
    func unstageFiles(_ values: [ChangedFile]) { guard !values.isEmpty else { return }; runOperation("取消暂存", indexPaths: Set(values.map(\.path))) { try await $0.unstage(values); return "已取消暂存，工作区修改已保留" } }
    func toggleStage(_ file: ChangedFile) { file.hasStaged ? unstageFiles([file]) : stageFiles([file]) }
    func toggleGroup(_ values: [ChangedFile]) {
        if values.allSatisfy(\.hasStaged) { unstageFiles(values) }
        else if values.count > 20 { confirm("暂存 \(values.count) 个文件？", message: "将这些文件的当前内容加入暂存区。请确认包含的新增文件符合本次提交范围。", button: "全部暂存") { self.stageFiles(values) } }
        else { stageFiles(values) }
    }
    func discardSelected() {
        guard let file = selected, !file.untracked, file.hasWorking, !busy, let repository else { return }
        let token = repositoryToken
        Task {
            do {
                let patch = try await repository.discardPatch(for: file)
                guard token == repositoryToken else { return }
                confirm("恢复工作区文件？", message: "\(file.path)\n\n未暂存的修改将恢复到暂存区版本，已有暂存内容保留。此操作无法在 Sprig 中撤销。", button: "恢复文件") {
                    self.runOperation("恢复文件") { try await $0.discardWorking(file, expectedPatch: patch); return "已恢复 " + file.path }
                }
            } catch { self.error = error.localizedDescription }
        }
    }
    func moveFile(_ delta: Int) {
        guard !files.isEmpty else { return }
        let current = files.firstIndex { $0.path == selectedPath } ?? 0
        select(files[min(max(0, current + delta), files.count - 1)])
    }
    func navigateHunk(_ delta: Int) { NotificationCenter.default.post(name: .sprigNavigateHunk, object: delta) }
    func loadAuxiliary() {
        guard let repository else { return }; auxiliaryToken = UUID(); let token = auxiliaryToken
        Task {
            do {
                let loadedRefs = try await repository.refs(), loadedStashes = try await repository.stashes()
                guard token == auxiliaryToken else { return }
                refs = loadedRefs; stashes = loadedStashes
            } catch { guard token == auxiliaryToken else { return }; log("读取分支与储藏", error.localizedDescription, failed: true) }
        }
    }
    func switchTo(_ ref: GitRef) {
        showBranches = false
        if ref.kind == .tag { confirm("检出标签 \(ref.name)？", message: "将进入分离 HEAD 状态。后续工作建议先创建本地分支。", button: "检出标签") { self.runOperation("检出标签") { try await $0.switchRef(ref); return "已检出标签 " + ref.name } } }
        else { runOperation("切换分支") { try await $0.switchRef(ref); return "已切换到 " + ref.name } }
    }
    func integrate(_ operation: String, revision: String, label: String) {
        showBranches = false
        confirm("\(label)？", message: "当前分支：\(branchTitle)\n来源：\(revision)\n\n仅在工作区干净时执行；如出现冲突，会保留现场供处理。", button: label) { self.runOperation(label) { try await $0.integrate(operation, revision: revision) } }
    }
    func loadHistory(more: Bool = false) {
        guard let repository else { return }; historyToken = UUID(); let token = historyToken
        let skip = more ? history.count : 0, all = historyAll, query = historyQuery, author = historyAuthor
        historyLoading = true
        Task {
            do {
                let commits = try await repository.history(skip: skip, all: all, query: query, author: author)
                guard token == historyToken else { return }
                historyMore = commits.count == 50
                if more { let existing = Set(history.map(\.oid)); history += commits.filter { !existing.contains($0.oid) } }
                else { history = commits; if let first = commits.first { selectCommit(first) } else { selectedCommit = nil; historyFiles = []; historyDocument = nil } }
                historyLoading = false
            } catch { guard token == historyToken else { return }; historyLoading = false; self.error = error.localizedDescription }
        }
    }
    func selectCommit(_ commit: GitCommit) {
        guard let repository else { return }; selectedCommit = commit; historyFiles = []; historyDocument = nil; detailToken = UUID(); let token = detailToken
        Task {
            do { let values = try await repository.commitFiles(commit); guard token == detailToken else { return }; historyFiles = values; if let first = values.first { selectHistoryFile(first) } }
            catch { guard token == detailToken else { return }; self.error = error.localizedDescription }
        }
    }
    func selectHistoryFile(_ file: CommitFile) {
        guard let repository, let commit = selectedCommit else { return }; selectedHistoryFile = file; historyDocument = nil; detailToken = UUID(); let token = detailToken
        Task { do { let diff = try await repository.commitDiff(commit, file: file); guard token == detailToken else { return }; historyDocument = diff } catch { guard token == detailToken else { return }; self.error = error.localizedDescription } }
    }
    func selectStash(_ stash: GitStash) {
        guard let repository else { return }; selectedStash = stash; stashDocument = nil; detailToken = UUID(); let token = detailToken
        Task { do { let diff = try await repository.stashDiff(stash); guard token == detailToken else { return }; stashDocument = diff } catch { guard token == detailToken else { return }; self.error = error.localizedDescription } }
    }
    func prepareCommit(push: Bool) {
        guard canCommit, let repository else { return }
        guard !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { error = "请填写提交说明，或使用 AI 生成。"; return }
        busy = true; busyTitle = "准备提交范围"
        Task {
            do { let preparation = try await repository.prepareCommit(amend: amend); sheet = WorkspaceSheet(kind: .commit(preparation, push)) }
            catch { self.error = error.localizedDescription }
            busy = false; busyTitle = ""
        }
    }
    func performCommit(_ preparation: CommitPreparation, push: Bool) {
        guard !busy else { return }; sheet = nil
        let message = commitMessage; var options = settings.commitOptions; options.amend = amend
        runOperation(options.amend ? "修正上次提交" : "提交") { repo in
            let result = try await repo.commit(preparation, message: message, options: options)
            await MainActor.run {
                self.messageHistory.removeAll { $0 == message }; self.messageHistory.insert(message, at: 0); self.messageHistory = Array(self.messageHistory.prefix(20))
                UserDefaults.standard.set(self.messageHistory, forKey: "Sprig.messageHistory")
                self.commitMessage = ""; self.amend = false; self.aiSource = nil
                if push { self.pendingPushOID = result.oid; self.sheet = WorkspaceSheet(kind: .push(result.oid)) }
            }
            return "提交完成：\(result.oid.prefix(8))\n" + result.output
        }
    }
    func openPush() {
        guard !busy, let repository else { return }
        if synchronizedPushSession != nil { retryPush(); return }
        let token = repositoryToken
        Task { do { let oid = try await repository.headOID(); guard token == repositoryToken else { return }; guard oid != "(initial)" else { error = "当前仓库还没有提交。"; return }; sheet = WorkspaceSheet(kind: .push(oid)) } catch { self.error = error.localizedDescription } }
    }
    func performPush(oid: String, destination: PushDestination, autoSync: Bool = true, strategy: PushStrategy = .merge) {
        sheet = nil; pendingPushOID = oid; pendingPushTarget = destination
        savePushPreference(autoSync: autoSync, strategy: strategy)
        runOperation("推送") { repo in
            let output: String
            if autoSync {
                output = try await repo.synchronizedPush(to: destination, expectedOID: oid, strategy: strategy) { title in
                    await MainActor.run { self.busyTitle = title }
                }
            } else { output = try await repo.push(to: destination, expectedOID: oid) }
            await MainActor.run { self.pendingPushOID = nil; self.pendingPushTarget = nil }
            return autoSync ? output : "推送完成 → \(destination.remote)/\(destination.branch)\n" + output
        }
    }
    func retryPush() {
        if let session = synchronizedPushSession {
            if session.needsRestoreReview {
                confirm("已核对本地修改的恢复结果？", message: "请确认工作区和暂存区包含需要保留的修改。继续后不会重复套用储藏；自动储藏副本仍会保留供核对。", button: "恢复已核对，继续") { self.resumePush(restorationReviewed: true) }
            } else { resumePush() }
            return
        }
        guard let oid = pendingPushOID else { return }
        sheet = WorkspaceSheet(kind: .push(oid))
    }
    func reloadPushSession() {
        do {
            synchronizedPushSession = try repository?.pushSession()
            if let session = synchronizedPushSession { pendingPushOID = session.expectedOID; pendingPushTarget = session.destination }
        } catch { self.error = "读取同步恢复记录失败：" + error.localizedDescription }
    }
    func pushPreferenceKey(_ suffix: String) -> String { draftKey(repository?.root.path ?? "") + ".push." + suffix }
    var autoSyncPreference: Bool { UserDefaults.standard.object(forKey: pushPreferenceKey("autoSync")) as? Bool ?? true }
    var pushStrategyPreference: PushStrategy { PushStrategy(rawValue: UserDefaults.standard.string(forKey: pushPreferenceKey("strategy")) ?? "") ?? .merge }
    func savePushPreference(autoSync: Bool, strategy: PushStrategy) {
        UserDefaults.standard.set(autoSync, forKey: pushPreferenceKey("autoSync"))
        UserDefaults.standard.set(strategy.rawValue, forKey: pushPreferenceKey("strategy"))
    }
    func resumePush(restorationReviewed: Bool = false) {
        runOperation("继续同步并推送") { repo in
            let output = try await repo.resumeSynchronizedPush(restorationReviewed: restorationReviewed) { title in await MainActor.run { self.busyTitle = title } }
            await MainActor.run { self.pendingPushOID = nil; self.pendingPushTarget = nil }
            return output
        }
    }
    func cancelPush() {
        confirm("取消此次同步推送？", message: "正在进行的 Merge / Rebase 会中止，并尝试恢复自动储藏。已完成的提交和合并会保留；不会重置或覆盖工作区。", button: "取消同步") {
            self.runOperation("取消同步推送") { repo in
                let output = try await repo.cancelSynchronizedPush()
                await MainActor.run { self.pendingPushOID = nil; self.pendingPushTarget = nil }
                return output
            }
        }
    }
    func markResolved(_ file: ChangedFile) {
        confirm("标记 \(file.name) 为已解决？", message: "请先在编辑器中解决冲突并保存。此操作会将文件当前内容加入暂存区；删除文件则记录删除结果。", button: "标记为已解决") {
            self.runOperation("标记冲突已解决", indexPaths: [file.path]) { try await $0.markResolved(file); return "已标记解决：" + file.path }
        }
    }
    func loadPreviousMessage() {
        guard let repository else { return }
        let token = repositoryToken
        Task { do { if let commit = try await repository.history(limit: 1, all: false).first, token == repositoryToken { commitMessage = commit.message } } catch { self.error = error.localizedDescription } }
    }
    func localChecks() {
        guard !busy, let repository else { return }; busy = true; busyTitle = "检查暂存内容"
        Task {
            do {
                let preparation = try await repository.prepareCommit(amend: amend)
                var report = preparation.checkOutput.isEmpty ? "空白检查：通过。" : "空白检查：\n" + preparation.checkOutput
                if settings.checkTODO {
                    let todo = preparation.patch.components(separatedBy: "\n").filter { $0.hasPrefix("+") && !$0.hasPrefix("+++") && ($0.localizedCaseInsensitiveContains("TODO") || $0.contains("FIXME")) }
                    report += "\n\n新增 TODO / FIXME：\(todo.count) 处\n" + todo.prefix(20).joined(separator: "\n")
                }
                report += "\n\nGit hooks 会在真实提交时执行。此检查未运行编译、单元测试或 IDE 静态分析。"
                sheet = WorkspaceSheet(kind: .report("提交检查", report))
            } catch { self.error = error.localizedDescription }
            busy = false; busyTitle = ""
        }
    }
    func prepareAI(_ intent: AIIntent) {
        guard !busy, let repository else { return }
        guard !settings.ai.baseURL.isEmpty, !settings.ai.model.isEmpty else { sheet = WorkspaceSheet(kind: .settings); notice = "请先配置 AI 接口地址、模型和 API Key。"; return }
        error = nil; notice = nil
        busy = true; busyTitle = "准备 AI 读取范围"
        Task {
            do { let context = try await repository.aiContext(configuration: settings.ai); sheet = WorkspaceSheet(kind: .aiConfirm(context, intent)) }
            catch { self.error = error.localizedDescription }
            busy = false; busyTitle = ""
        }
    }
    func generateAI(_ context: AIContext, intent: AIIntent) {
        guard !busy, context.canGenerate, let repository else { return }
        error = nil; notice = nil; sheet = nil; busy = true; busyTitle = "AI 正在核对暂存内容"
        aiStartedAt = Date(); aiRequestID = UUID(); let requestID = aiRequestID
        let configuration = settings.ai
        operationTask = Task {
            do {
                guard context.stamp == (try await repository.stamp()) else { throw GitError.message("暂存内容已变化，请重新生成。") }
                guard requestID == aiRequestID else { return }
                busyTitle = "AI 正在读取密钥 · 如有系统提示请授权"
                let endpoint = try configuration.endpoint().absoluteString, key = try await KeychainStore.read(endpoint: endpoint)
                try Task.checkCancellation()
                guard requestID == aiRequestID else { return }
                busyTitle = intent == .commit ? "AI 正在生成提交说明 · 最长等待 90 秒" : "AI 正在检查暂存内容 · 最长等待 90 秒"
                let result = try await AIClient().generate(context: context, configuration: configuration, key: key, intent: intent)
                try Task.checkCancellation()
                guard requestID == aiRequestID else { return }
                sheet = WorkspaceSheet(kind: .aiResult(context, result, intent))
            } catch { if !Task.isCancelled, requestID == aiRequestID { self.error = error.localizedDescription } }
            guard requestID == aiRequestID else { return }
            aiStartedAt = nil; operationTask = nil; busy = false; busyTitle = ""
            if needsRefresh { needsRefresh = false; refresh() }
        }
    }
    func useAIDraft(_ text: String, context: AIContext) {
        guard let repository else { return }
        Task {
            do {
                guard context.stamp == (try await repository.stamp()) else { throw GitError.message("生成后暂存内容已改变。请重新生成说明，当前草稿已保留。") }
                commitMessage = text; aiSource = context.stamp; sheet = nil
            } catch { sheet = nil; self.error = error.localizedDescription }
        }
    }
    func cancelAI() {
        guard aiStartedAt != nil else { return }
        aiRequestID = UUID(); operationTask?.cancel(); operationTask = nil
        aiStartedAt = nil; busy = false; busyTitle = ""; notice = "已取消 AI 生成，原提交草稿已保留。"
        if needsRefresh { needsRefresh = false; refresh() }
    }
    func exportPatch() {
        guard let raw = document?.raw, !raw.isEmpty else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "changes.patch"
        panel.begin { response in
            if response == .OK, let url = panel.url { do { try Data(raw.utf8).write(to: url) } catch { Task { @MainActor in self.error = error.localizedDescription } } }
        }
    }
}
extension Notification.Name { static let sprigNavigateHunk = Notification.Name("Sprig.navigateHunk") }
