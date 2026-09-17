// Copyright (c) 2026 zhiyu
// SPDX-License-Identifier: LicenseRef-Sprig-NC-SA-1.0

import Foundation

public enum LineKind: Sendable { case context, addition, deletion, hunk, note }
public struct DiffLine: Sendable {
    public let old: Int?
    public let new: Int?
    public let text: String
    public let kind: LineKind
    public init(old: Int? = nil, new: Int? = nil, text: String, kind: LineKind) { self.old = old; self.new = new; self.text = text; self.kind = kind }
}
public struct DiffPair: Sendable {
    public let left: DiffLine?
    public let right: DiffLine?
}
public struct DiffDocument: Sendable {
    public let path: String
    public let raw: String
    public let lines: [DiffLine]
    public let pairs: [DiffPair]
    public let message: String?
    public var additions: Int { lines.filter { $0.kind == .addition }.count }
    public var deletions: Int { lines.filter { $0.kind == .deletion }.count }

    public static func notice(_ message: String, path: String) -> Self { Self(path: path, raw: "", lines: [], pairs: [], message: message) }
    public static func addedText(_ text: String, path: String, note: String? = nil) -> Self {
        guard !text.isEmpty else { return .notice("新建空文件，没有文本内容。", path: path) }
        var parts = text.components(separatedBy: "\n")
        if text.hasSuffix("\n") { parts.removeLast() }
        guard parts.count <= 20_000 else { return .notice("超过 20,000 行，已跳过预览。", path: path) }
        var patch = "--- /dev/null\n+++ b/\(path)\n@@ -0,0 +1,\(parts.count) @@\n" + parts.map { "+" + $0 }.joined(separator: "\n") + "\n"
        if !text.hasSuffix("\n") { patch += "\\ No newline at end of file\n" }
        let document = parse(patch, path: path)
        return Self(path: path, raw: patch, lines: document.lines, pairs: document.pairs, message: note)
    }

    public static func parse(_ patch: String, path: String) -> Self {
        if patch.isEmpty { return .notice("当前范围没有文本差异。", path: path) }
        let regex = try! NSRegularExpression(pattern: "^@@ -(\\d+)(?:,\\d+)? \\+(\\d+)(?:,\\d+)? @@")
        var lines: [DiffLine] = [], old = 0, new = 0, inHunk = false, binary = false
        for text in patch.components(separatedBy: "\n") {
            if let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let a = Range(match.range(at: 1), in: text), let b = Range(match.range(at: 2), in: text) {
                old = Int(text[a]) ?? 0; new = Int(text[b]) ?? 0; inHunk = true
                lines.append(DiffLine(text: text, kind: .hunk)); continue
            }
            if text.hasPrefix("diff --git ") { inHunk = false }
            if text.hasPrefix("Binary files ") || text == "GIT binary patch" { binary = true }
            guard inHunk else { continue }
            switch text.first {
            case " ": lines.append(DiffLine(old: old, new: new, text: String(text.dropFirst()), kind: .context)); old += 1; new += 1
            case "-": lines.append(DiffLine(old: old, text: String(text.dropFirst()), kind: .deletion)); old += 1
            case "+": lines.append(DiffLine(new: new, text: String(text.dropFirst()), kind: .addition)); new += 1
            case "\\": lines.append(DiffLine(text: "文件末尾无换行", kind: .note))
            default: break
            }
            if lines.count > 20_000 { return .notice("差异超过 20,000 行，已跳过渲染。", path: path) }
        }
        if lines.isEmpty { return Self(path: path, raw: patch, lines: [], pairs: [], message: binary ? "二进制内容已变化，不显示文本差异。" : "文件路径或权限发生变化。\n\n" + patch) }
        var pairs: [DiffPair] = [], removed: [DiffLine] = [], added: [DiffLine] = []
        func flush() {
            for index in 0..<max(removed.count, added.count) { pairs.append(DiffPair(left: index < removed.count ? removed[index] : nil, right: index < added.count ? added[index] : nil)) }
            removed.removeAll(keepingCapacity: true); added.removeAll(keepingCapacity: true)
        }
        for line in lines {
            switch line.kind {
            case .deletion: if !added.isEmpty { flush() }; removed.append(line)
            case .addition: added.append(line)
            default: flush(); pairs.append(DiffPair(left: line, right: line))
            }
        }
        flush()
        return Self(path: path, raw: patch, lines: lines, pairs: pairs, message: nil)
    }
}
