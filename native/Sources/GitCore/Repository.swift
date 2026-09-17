// Copyright (c) 2026 zhiyu
// SPDX-License-Identifier: LicenseRef-Sprig-NC-SA-1.0

import Foundation
import Darwin

public enum DiffScope: String, CaseIterable, Identifiable, Sendable {
    case staged, working
    public var id: String { rawValue }
    public var title: String { self == .staged ? "已暂存" : "工作区" }
}

public struct ChangedFile: Identifiable, Equatable, Sendable {
    public let path: String
    public let originalPath: String?
    public let index: Character
    public let worktree: Character
    public let untracked: Bool
    public let conflict: Bool
    public let submodule: Bool
    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }
    public var parent: String { let value = (path as NSString).deletingLastPathComponent; return value.isEmpty ? "/" : value }
    public var hasStaged: Bool { !untracked && !conflict && index != "." }
    public var hasWorking: Bool { untracked || conflict || worktree != "." }
    public var badge: String {
        if conflict { return "冲突" }; if untracked { return "新" }; if submodule { return "子模块" }
        if index == "R" || worktree == "R" { return "R" }; if index == "D" || worktree == "D" { return "D" }
        if index == "A" { return "A" }; return "M"
    }
    public var scopeLabel: String { conflict ? "未解决冲突" : hasStaged && hasWorking ? "部分暂存" : hasStaged ? "已暂存" : untracked ? "未跟踪" : "未暂存" }
}

public struct RepositorySnapshot: Sendable {
    public let root: URL
    public let gitDirectory: URL
    public let commonDirectory: URL
    public var branch = ""
    public var head = ""
    public var upstream: String?
    public var ahead: Int?
    public var behind: Int?
    public var operation: String?
    public var files: [ChangedFile] = []
    public var stagedCount: Int { files.filter(\.hasStaged).count }
    public var workingCount: Int { files.filter(\.hasWorking).count }
}

public enum StatusParser {
    public static func parse(_ data: Data, root: URL, gitDirectory: URL, commonDirectory: URL) throws -> RepositorySnapshot {
        var snapshot = RepositorySnapshot(root: root, gitDirectory: gitDirectory, commonDirectory: commonDirectory)
        let records = data.split(separator: 0, omittingEmptySubsequences: true)
        var cursor = 0
        func decode(_ data: Data.SubSequence) throws -> String {
            guard let value = String(data: Data(data), encoding: .utf8) else { throw GitError.message("仓库包含非 UTF-8 路径，当前样机无法可靠显示。") }
            return value
        }
        while cursor < records.count {
            let line = try decode(records[cursor]); cursor += 1
            if line.hasPrefix("# ") {
                let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
                guard fields.count == 3 else { continue }
                switch fields[1] {
                case "branch.head": snapshot.branch = String(fields[2])
                case "branch.oid": snapshot.head = String(fields[2])
                case "branch.upstream": snapshot.upstream = String(fields[2])
                case "branch.ab":
                    let counts = fields[2].split(separator: " ")
                    if counts.count == 2 { snapshot.ahead = Int(counts[0].dropFirst()); snapshot.behind = Int(counts[1].dropFirst()) }
                default: break
                }
                continue
            }
            if line.hasPrefix("? ") {
                snapshot.files.append(ChangedFile(path: String(line.dropFirst(2)), originalPath: nil, index: "?", worktree: "?", untracked: true, conflict: false, submodule: false)); continue
            }
            let kind = line.first
            guard kind == "1" || kind == "2" || kind == "u" else { continue }
            let fieldCount = kind == "1" ? 8 : kind == "2" ? 9 : 10
            let fields = line.split(separator: " ", maxSplits: fieldCount, omittingEmptySubsequences: false)
            guard fields.count == fieldCount + 1, fields[1].count == 2 else { throw GitError.message("无法解析 Git 状态，请重新刷新。") }
            var original: String?
            if kind == "2" {
                guard cursor < records.count else { throw GitError.message("Git 重命名记录不完整。") }
                original = try decode(records[cursor]); cursor += 1
            }
            let xy = Array(fields[1])
            snapshot.files.append(ChangedFile(path: String(fields[fieldCount]), originalPath: original, index: xy[0], worktree: xy[1], untracked: false, conflict: kind == "u", submodule: fields[2].hasPrefix("S")))
        }
        snapshot.files.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return snapshot
    }
}

public struct GitRepository: Sendable {
    public let root: URL
    public let gitDirectory: URL
    public let commonDirectory: URL
    public let runner: CommandRunner
    private static func line(_ text: String) -> String { text.hasSuffix("\n") ? String(text.dropLast()) : text }

    public static func open(_ directory: URL, executable: String = "/usr/bin/git") async throws -> GitRepository {
        let runner = CommandRunner(executable: executable)
        func read(_ args: [String], at path: URL) async throws -> String {
            let result = try await runner.run(args, at: path)
            guard result.code == 0 else { throw GitError.message(result.error.isEmpty ? "所选目录不是可读取的 Git 工作区。" : result.error) }
            return line(result.text)
        }
        let rootPath = try await read(["rev-parse", "--show-toplevel"], at: directory)
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        let gitPath = try await read(["rev-parse", "--absolute-git-dir"], at: root)
        let commonPath = try await read(["rev-parse", "--path-format=absolute", "--git-common-dir"], at: root)
        return GitRepository(root: root, gitDirectory: URL(fileURLWithPath: gitPath), commonDirectory: URL(fileURLWithPath: commonPath), runner: runner)
    }

    public func snapshot() async throws -> RepositorySnapshot {
        let result = try await runner.run(["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all", "--ignore-submodules=none"], at: root, limit: 8_000_000)
        try Task.checkCancellation()
        guard result.code == 0 else { throw GitError.message(result.error) }
        var snapshot = try StatusParser.parse(result.data, root: root, gitDirectory: gitDirectory, commonDirectory: commonDirectory)
        for (path, label) in [("rebase-merge", "Rebase 进行中"), ("rebase-apply", "Rebase / Apply 进行中"), ("MERGE_HEAD", "Merge 进行中"), ("CHERRY_PICK_HEAD", "Cherry-pick 进行中"), ("REVERT_HEAD", "Revert 进行中")] {
            if FileManager.default.fileExists(atPath: gitDirectory.appendingPathComponent(path).path) { snapshot.operation = label; break }
        }
        return snapshot
    }

    public func diff(for file: ChangedFile, scope: DiffScope) async throws -> DiffDocument {
        if file.conflict { return .notice("此文件存在未解决的冲突。请在编辑器中处理并保存，然后右键文件选择“标记为已解决”。", path: file.path) }
        if file.untracked {
            guard scope == .working else { return .notice("此文件尚未暂存。", path: file.path) }
            return try await Task.detached(priority: .userInitiated) { try previewUntracked(file.path) }.value
        }
        var arguments = ["diff", "--no-ext-diff", "--no-textconv", "--no-color", "--unified=4", "--find-renames", "--src-prefix=a/", "--dst-prefix=b/", "--submodule=short"]
        if scope == .staged { arguments.append("--cached") }
        arguments += ["--", file.path]
        if scope == .staged, let original = file.originalPath { arguments.append(original) }
        let result = try await runner.run(arguments, at: root)
        try Task.checkCancellation()
        guard result.code == 0 else { throw GitError.message(result.error) }
        guard let patch = String(data: result.data, encoding: .utf8) else { return .notice("此差异不是 UTF-8 文本，当前不支持文本预览。", path: file.path) }
        return DiffDocument.parse(patch, path: file.path)
    }

    private func previewUntracked(_ path: String) throws -> DiffDocument {
        guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { throw GitError.message("文件路径无效。") }
        let url = root.appendingPathComponent(path)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
            return .addedText(try FileManager.default.destinationOfSymbolicLink(atPath: url.path), path: path, note: "符号链接目标（未跟随链接）")
        }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw GitError.message("文件已变化或无法读取，请刷新。") }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return .notice("此文件类型不支持文本预览。", path: path) }
        guard info.st_size <= 2_000_000 else { return .notice("文件超过 2 MB，已跳过预览以保持响应。", path: path) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data = try handle.read(upToCount: 2_000_001) ?? Data()
        guard data.count <= 2_000_000 else { return .notice("文件超过 2 MB，已跳过预览。", path: path) }
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else { return .notice("二进制或非 UTF-8 文件，已跳过文本预览。", path: path) }
        return .addedText(text, path: path)
    }
}
