// Copyright (c) 2026 zhiyu
// SPDX-License-Identifier: LicenseRef-Sprig-NC-SA-1.0

import Foundation
import CryptoKit
import Darwin

public struct IndexStamp: Equatable, Sendable {
    public let head: String
    public let branch: String
    public let indexHash: String
    public init(head: String, branch: String, indexHash: String) { self.head = head; self.branch = branch; self.indexHash = indexHash }
}
public struct CommitPreparation: Sendable {
    public let stamp: IndexStamp
    public let files: [ChangedFile]
    public let patch: String
    public let checkOutput: String
}
public struct CommitOptions: Sendable {
    public var amend = false
    public var signOff = false
    public var author = ""
    public var checkWhitespace = true
    public init(amend: Bool = false, signOff: Bool = false, author: String = "", checkWhitespace: Bool = true) {
        self.amend = amend; self.signOff = signOff; self.author = author; self.checkWhitespace = checkWhitespace
    }
}
public struct CommitOutcome: Sendable { public let oid: String; public let output: String }
public enum RefKind: String, Sendable { case local, remote, tag }
public struct GitRef: Identifiable, Sendable {
    public let fullName: String
    public let name: String
    public let oid: String
    public let kind: RefKind
    public let current: Bool
    public let upstream: String
    public var id: String { fullName }
}
public struct GitCommit: Identifiable, Sendable {
    public let oid: String
    public let parents: [String]
    public let author: String
    public let date: String
    public let subject: String
    public let body: String
    public let decorations: String
    public var id: String { oid }
    public var message: String { subject + (body.isEmpty ? "" : "\n\n" + body) }
}
public struct CommitFile: Identifiable, Sendable {
    public let path: String
    public let originalPath: String?
    public let status: String
    public var id: String { path }
}
public struct GitStash: Identifiable, Sendable {
    public let reference: String
    public let oid: String
    public let subject: String
    public var id: String { oid }
}
public struct PushDestination: Codable, Equatable, Sendable {
    public let remote: String
    public let branch: String
    public init(remote: String, branch: String) { self.remote = remote; self.branch = branch }
}

extension GitRepository {
    @discardableResult public func checked(_ args: [String], timeout: TimeInterval = 15) async throws -> String {
        let result = try await runner.run(args, at: root, timeout: timeout)
        guard result.code == 0 else { throw GitError.message(result.error.isEmpty ? result.text : result.error) }
        return result.text
    }
    public func headOID() async throws -> String {
        let result = try await runner.run(["rev-parse", "--verify", "HEAD"], at: root)
        if result.code != 0 { return "(initial)" }
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public func stamp() async throws -> IndexStamp {
        let head = try await headOID()
        let branchResult = try await runner.run(["symbolic-ref", "-q", "HEAD"], at: root)
        let index = gitDirectory.appendingPathComponent("index")
        let bytes = FileManager.default.fileExists(atPath: index.path) ? try Data(contentsOf: index, options: .mappedIfSafe) : Data()
        return IndexStamp(head: head, branch: branchResult.code == 0 ? branchResult.text.trimmingCharacters(in: .newlines) : "(detached)", indexHash: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    }
    public func prepareCommit(amend: Bool = false) async throws -> CommitPreparation {
        let before = try await stamp(), state = try await snapshot()
        guard state.operation == nil, !state.files.contains(where: \.conflict) else { throw GitError.message("仓库有冲突或正在进行的 Git 操作，请先处理后提交。") }
        let files = state.files.filter(\.hasStaged)
        guard !files.isEmpty || (amend && before.head != "(initial)") else { throw GitError.message("请先勾选需要提交的文件，或在外部编辑器中暂存内容。") }
        let patch = try await checked(["diff", "--cached", "--no-ext-diff", "--no-textconv", "--no-color", "--find-renames", "--unified=4"])
        let check = try await runner.run(["diff", "--cached", "--check"], at: root)
        guard before == (try await stamp()) else { throw GitError.message("读取期间暂存区发生变化，请刷新后重试。") }
        return CommitPreparation(stamp: before, files: files, patch: patch, checkOutput: check.text + check.error)
    }
    public func stage(_ files: [ChangedFile]) async throws {
        guard !files.isEmpty else { return }
        guard !files.contains(where: \.conflict) else { throw GitError.message("请先在编辑器中解决冲突并标记解决，再刷新。") }
        let paths = Array(Set(files.flatMap { [$0.path] + ($0.originalPath.map { [$0] } ?? []) }))
        _ = try await checked(["add", "--all", "--"] + paths, timeout: 60)
    }
    public func unstage(_ files: [ChangedFile]) async throws {
        guard !files.isEmpty else { return }
        let paths = Array(Set(files.flatMap { [$0.path] + ($0.originalPath.map { [$0] } ?? []) }))
        if try await headOID() == "(initial)" { _ = try await checked(["rm", "--cached", "-r", "--ignore-unmatch", "--"] + paths) }
        else { _ = try await checked(["restore", "--staged", "--"] + paths) }
    }
    public func discardPatch(for file: ChangedFile) async throws -> String {
        guard !file.untracked, !file.conflict, !file.submodule else { throw GitError.message("此操作仅恢复普通受跟踪文件的工作区修改。") }
        // Binary patches include the actual bytes, so an external binary edit
        // cannot pass review merely because the text says "Binary files differ".
        return try await checked(["diff", "--binary", "--no-ext-diff", "--no-textconv", "--no-color", "--", file.path])
    }
    public func discardWorking(_ file: ChangedFile, expectedPatch: String) async throws {
        guard !file.untracked, !file.conflict else { throw GitError.message("此操作仅恢复受跟踪文件的工作区修改。") }
        guard try await discardPatch(for: file) == expectedPatch else { throw GitError.message("文件已在外部变化，请重新查看差异。") }
        _ = try await checked(["restore", "--worktree", "--", file.path])
    }
    public func commit(_ preparation: CommitPreparation, message: String, options: CommitOptions) async throws -> CommitOutcome {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains("\0") else { throw GitError.message("提交说明不能为空，也不能包含 NUL 字符。") }
        if options.checkWhitespace && !preparation.checkOutput.isEmpty { throw GitError.message("暂存内容未通过空白检查：\n" + preparation.checkOutput) }
        let lock = gitDirectory.appendingPathComponent("index.lock")
        let descriptor = Darwin.open(lock.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        guard descriptor >= 0 else { throw GitError.message("暂存区正被其他 Git 操作使用，或没有写入权限。未执行提交。") }
        defer { Darwin.close(descriptor); Darwin.unlink(lock.path) }
        guard preparation.stamp == (try await stamp()) else { throw GitError.message("分支或暂存内容已改变。未执行提交，请重新检查提交范围。") }
        let state = try await snapshot()
        guard state.operation == nil, !state.files.contains(where: \.conflict) else { throw GitError.message("仓库正在执行其他 Git 操作。") }
        let temporaryIndex = gitDirectory.appendingPathComponent("sprig-index-" + UUID().uuidString)
        let messageFile = gitDirectory.appendingPathComponent("sprig-message-" + UUID().uuidString)
        let index = gitDirectory.appendingPathComponent("index")
        try FileManager.default.copyItem(at: index, to: temporaryIndex)
        var preserveIndex = false
        defer { if !preserveIndex { try? FileManager.default.removeItem(at: temporaryIndex) }; try? FileManager.default.removeItem(at: messageFile) }
        try Data(text.utf8).write(to: messageFile)
        var args = ["commit", "--file", messageFile.path]
        if options.amend { args.append("--amend") }
        if options.signOff { args.append("--signoff") }
        if !options.author.trimmingCharacters(in: .whitespaces).isEmpty { args += ["--author", options.author] }
        // Own the real index lock while Git and hooks work on a private copy. This
        // prevents another client from staging extra files between review and commit.
        var result: CommandResult?
        var executionError: Error?
        do { result = try await runner.run(args, at: root, timeout: 120, indexFile: temporaryIndex) }
        catch { executionError = error }
        if FileManager.default.fileExists(atPath: temporaryIndex.path) {
            guard Darwin.rename(temporaryIndex.path, index.path) == 0 else {
                preserveIndex = true
                throw GitError.message("Git 已执行，但同步暂存区失败。暂存副本保留在 \(temporaryIndex.path)。请先检查历史与暂存内容；不要重复提交。")
            }
        }
        if let executionError { throw GitError.message(executionError.localizedDescription + "\n提交结果需要核实，请先查看历史记录。") }
        guard let result, result.code == 0 else { throw GitError.message((result?.error ?? "") + (result?.text ?? "")) }
        return CommitOutcome(oid: try await headOID(), output: result.text + result.error)
    }

    public func refs() async throws -> [GitRef] {
        let output = try await checked(["for-each-ref", "--sort=-committerdate", "--format=%(refname)%00%(objectname)%00%(HEAD)%00%(upstream:short)%00%(symref)", "refs/heads", "refs/remotes", "refs/tags"])
        return output.split(separator: "\n").compactMap { row in
            let fields = row.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 5, fields[4].isEmpty else { return nil }
            let kind: RefKind = fields[0].hasPrefix("refs/heads/") ? .local : fields[0].hasPrefix("refs/remotes/") ? .remote : .tag
            let prefix = kind == .local ? "refs/heads/" : kind == .remote ? "refs/remotes/" : "refs/tags/"
            return GitRef(fullName: fields[0], name: String(fields[0].dropFirst(prefix.count)), oid: fields[1], kind: kind, current: fields[2] == "*", upstream: fields[3])
        }
    }
    public func requireClean() async throws {
        let state = try await snapshot()
        guard state.files.isEmpty, state.operation == nil else { throw GitError.message("请先提交或储藏当前修改，并处理正在进行的 Git 操作。") }
    }
    public func createBranch(_ name: String, start: String? = nil) async throws {
        guard !name.hasPrefix("-") else { throw GitError.message("分支名不能以 - 开头。") }
        _ = try await checked(["check-ref-format", "--branch", name])
        var args = ["switch", "-c", name]
        if let start { args.append(try await verifiedRevision(start)) }
        _ = try await checked(args)
    }
    public func switchRef(_ ref: GitRef, localName: String = "") async throws {
        let state = try await snapshot()
        guard state.operation == nil else { throw GitError.message("请先完成或中止当前 Git 操作。") }
        switch ref.kind {
        case .local: _ = try await checked(["switch", "--no-guess", "--", ref.name])
        case .remote:
            let name = localName.isEmpty ? ref.name.split(separator: "/").dropFirst().joined(separator: "/") : localName
            _ = try await checked(["check-ref-format", "--branch", name])
            _ = try await checked(["switch", "-c", name, "--track", ref.fullName])
        case .tag: _ = try await checked(["switch", "--detach", try await verifiedRevision(ref.fullName)])
        }
    }
    public func deleteBranch(_ ref: GitRef) async throws {
        guard ref.kind == .local, !ref.current else { throw GitError.message("只能删除非当前本地分支。") }
        _ = try await checked(["branch", "-d", "--", ref.name])
    }
    public func createTag(_ name: String, revision: String) async throws {
        guard !name.hasPrefix("-") else { throw GitError.message("标签名称无效。") }
        _ = try await checked(["check-ref-format", "refs/tags/" + name])
        _ = try await checked(["tag", name, try await verifiedRevision(revision)])
    }
    public func verifiedRevision(_ revision: String) async throws -> String {
        let value = try await checked(["rev-parse", "--verify", "--end-of-options", revision + "^{commit}"])
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public func history(limit: Int = 50, skip: Int = 0, all: Bool = true, query: String = "", author: String = "") async throws -> [GitCommit] {
        if try await headOID() == "(initial)" { return [] }
        var args = ["log", "-z", "--date=iso-strict", "--format=%H%x00%P%x00%an%x00%aI%x00%s%x00%b%x00%D", "--max-count=\(limit)", "--skip=\(skip)"]
        if all { args.append("--all") }
        if !query.isEmpty {
            if query.count >= 7, query.allSatisfy({ $0.isHexDigit }), let oid = try? await verifiedRevision(query) { args.removeAll { $0 == "--all" }; args += ["--no-walk", oid] }
            else { args += ["--fixed-strings", "--regexp-ignore-case", "--grep=" + query] }
        }
        if !author.isEmpty { args.append("--author=" + NSRegularExpression.escapedPattern(for: author)) }
        args.append("--")
        let data = try await checked(args)
        var fields = data.components(separatedBy: "\0")
        if fields.last == "" { fields.removeLast() }
        guard fields.count % 7 == 0 else { throw GitError.message("无法解析提交历史。") }
        var commits: [GitCommit] = []
        for i in stride(from: 0, to: fields.count, by: 7) {
            let oid = fields[i].trimmingCharacters(in: .newlines)
            let parents: [String] = fields[i + 1].split(separator: " ").map { String($0) }
            let body = fields[i + 5].trimmingCharacters(in: .newlines)
            let commit = GitCommit(oid: oid, parents: parents, author: fields[i + 2],
                                   date: fields[i + 3], subject: fields[i + 4],
                                   body: body, decorations: fields[i + 6])
            commits.append(commit)
        }
        return commits
    }
    public func commitFiles(_ commit: GitCommit) async throws -> [CommitFile] {
        let oid = try await verifiedRevision(commit.oid)
        let args = commit.parents.first.map { ["diff", "--name-status", "-z", "--find-renames", $0, oid, "--"] } ?? ["diff-tree", "--root", "--no-commit-id", "--name-status", "-z", "-r", oid, "--"]
        let output = try await checked(args), fields = output.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var index = 0, files: [CommitFile] = []
        while index + 1 < fields.count {
            let status = fields[index], first = fields[index+1]; index += 2
            if status.hasPrefix("R") || status.hasPrefix("C") {
                guard index < fields.count else { break }
                files.append(CommitFile(path: fields[index], originalPath: first, status: String(status.prefix(1)))); index += 1
            } else { files.append(CommitFile(path: first, originalPath: nil, status: status)) }
        }
        return files
    }
    public func commitDiff(_ commit: GitCommit, file: CommitFile) async throws -> DiffDocument {
        let oid = try await verifiedRevision(commit.oid)
        var args = ["diff", "--no-ext-diff", "--no-textconv", "--unified=4", "--find-renames"]
        if let parent = commit.parents.first { args += [parent, oid] }
        else { args = ["show", "--format=", "--root", "--no-ext-diff", "--no-textconv", "--unified=4", oid] }
        args += ["--", file.path]
        if let old = file.originalPath { args.append(old) }
        return DiffDocument.parse(try await checked(args), path: file.path)
    }
    public func remotes() async throws -> [String] { try await checked(["remote"]).split(separator: "\n").map(String.init) }
    public func pushSuggestion() async throws -> PushDestination {
        let state = try await snapshot(), names = try await remotes()
        let remote = try await runner.run(["config", "--get", "branch.\(state.branch).remote"], at: root)
        let merge = try await runner.run(["config", "--get", "branch.\(state.branch).merge"], at: root)
        let remoteName = remote.code == 0 ? remote.text.trimmingCharacters(in: .newlines) : names.first ?? ""
        let branch = merge.code == 0 ? merge.text.trimmingCharacters(in: .newlines).replacingOccurrences(of: "refs/heads/", with: "") : state.branch
        return PushDestination(remote: remoteName, branch: branch)
    }
    public func push(to destination: PushDestination, expectedOID: String) async throws -> String {
        guard try await headOID() == expectedOID else { throw GitError.message("当前提交已经改变，请重新确认推送内容。") }
        guard try await remotes().contains(destination.remote), !destination.remote.hasPrefix("-") else { throw GitError.message("请选择已有的远程仓库。") }
        _ = try await checked(["check-ref-format", "refs/heads/" + destination.branch])
        let state = try await snapshot()
        let output = try await checked(["push", "--porcelain", destination.remote, expectedOID + ":refs/heads/" + destination.branch], timeout: 120)
        if state.branch != "(detached)" {
            do {
                _ = try await checked(["config", "branch.\(state.branch).remote", destination.remote])
                _ = try await checked(["config", "branch.\(state.branch).merge", "refs/heads/" + destination.branch])
            } catch { return output + "\n远端推送已成功，但保存本地跟踪配置失败：" + error.localizedDescription }
        }
        return output
    }
    public func fetch() async throws -> String { try await checked(["fetch", "--all", "--prune"], timeout: 120) }
    public func pull() async throws -> String { try await requireClean(); return try await checked(["pull", "--ff-only"], timeout: 120) }
    public func stashes() async throws -> [GitStash] {
        let output = try await checked(["stash", "list", "--format=%gd%x00%H%x00%s"])
        return output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            return fields.count == 3 ? GitStash(reference: fields[0], oid: fields[1], subject: fields[2]) : nil
        }
    }
    public func stashSave(_ message: String, includeUntracked: Bool) async throws -> String {
        var args = ["stash", "push", "-m", message.isEmpty ? "Sprig stash" : message]
        if includeUntracked { args.append("--include-untracked") }
        return try await checked(args, timeout: 60)
    }
    public func stashDiff(_ stash: GitStash) async throws -> DiffDocument {
        DiffDocument.parse(try await checked(["stash", "show", "--patch", "--include-untracked", "--no-ext-diff", "--no-textconv", stash.oid]), path: stash.subject)
    }
    public func applyStash(_ stash: GitStash) async throws -> String {
        try await requireClean()
        return try await checked(["stash", "apply", "--index", stash.oid], timeout: 60)
    }
    public func dropStash(_ stash: GitStash) async throws -> String {
        if let session = try pushSession(), session.stashOID == stash.oid, !session.stashRestored {
            throw GitError.message("此储藏正在保护同步前的本地修改。请先完成或取消同步任务，再处理该储藏。")
        }
        guard try await verifiedRevision(stash.reference) == stash.oid else { throw GitError.message("储藏列表已变化，请刷新后重试。") }
        return try await checked(["stash", "drop", stash.reference])
    }
    public func integrate(_ operation: String, revision: String) async throws -> String {
        guard ["merge", "rebase", "cherry-pick", "revert"].contains(operation) else { throw GitError.message("不支持的操作。") }
        try await requireClean()
        let oid = try await verifiedRevision(revision)
        let args = operation == "merge" || operation == "revert" ? [operation, "--no-edit", oid] : [operation, oid]
        return try await checked(args, timeout: 120)
    }
    public func continueOperation(abort: Bool) async throws -> String {
        let state = try await snapshot()
        guard let operation = state.operation else { throw GitError.message("当前没有可继续或中止的操作。") }
        let name = operation.hasPrefix("Rebase") ? "rebase" : operation.hasPrefix("Cherry") ? "cherry-pick" : operation.hasPrefix("Revert") ? "revert" : "merge"
        return try await checked([name, abort ? "--abort" : "--continue"], timeout: 120)
    }
    public func identity() async throws -> (String, String) {
        let name = try await runner.run(["config", "--get", "user.name"], at: root), email = try await runner.run(["config", "--get", "user.email"], at: root)
        return (name.text.trimmingCharacters(in: .newlines), email.text.trimmingCharacters(in: .newlines))
    }
    public func saveIdentity(name: String, email: String) async throws {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty, email.contains("@"), !email.contains("\n") else { throw GitError.message("请输入作者名称和有效邮箱。") }
        _ = try await checked(["config", "--local", "user.name", name]); _ = try await checked(["config", "--local", "user.email", email])
    }
}
