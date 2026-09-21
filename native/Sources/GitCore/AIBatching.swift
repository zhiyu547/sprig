// Copyright (c) 2026 zhiyu
// SPDX-License-Identifier: LicenseRef-Sprig-NC-SA-1.0

import Foundation

public struct AIInputBatch: Sendable {
    public let patch: String
    public let continuation: String
}

/// Bounds each model input without dropping bytes from the sanitized diff.
/// Continuation metadata is separate so joining the patches reproduces the input.
public enum AIBatching {
    public static let maximumPatchBytes = 2_000_000
    public static let batchBytes = 96_000
    static let summaryBytes = 16_000

    public static func validate(_ patch: String) throws {
        guard patch.utf8.count <= maximumPatchBytes else {
            throw GitError.message("过滤后的暂存文本超过 2 MB。请排除生成文件或缩小提交范围；尚未发送给 AI。")
        }
    }

    public static func split(_ patch: String) -> [AIInputBatch] {
        let bytes = Array(patch.utf8)
        var start = 0, fileHeader = "", hunkHeader = "", result: [AIInputBatch] = []
        while start < bytes.count {
            var end = min(start + batchBytes, bytes.count)
            if end < bytes.count {
                // Prefer a line boundary; unusually long lines still remain valid UTF-8.
                if let newline = bytes[start..<end].lastIndex(of: 10) { end = newline + 1 }
                else { while end > start && bytes[end] & 0xC0 == 0x80 { end -= 1 } }
            }
            let text = String(decoding: bytes[start..<end], as: UTF8.self)
            let continuation = start == 0 || text.hasPrefix("diff --git ") ? "" :
                "续接上一段差异（以下仅用于定位，不是重复变更）：\n" + fileHeader + "\n" + hunkHeader +
                (bytes[start - 1] == 10 ? "" : "\n本段起始位置在同一长行内。")
            result.append(AIInputBatch(patch: text, continuation: continuation))
            for line in text.split(separator: "\n") {
                if line.hasPrefix("diff --git ") { fileHeader = String(line); hunkHeader = "" }
                else if line.hasPrefix("@@ ") { hunkHeader = String(line) }
            }
            start = end
        }
        return result
    }

    /// Keep each intermediate answer intact when packing a synthesis request.
    static func summaryGroups(_ summaries: [String]) -> [[String]] {
        var groups: [[String]] = [], current: [String] = [], count = 0
        for summary in summaries {
            let size = summary.utf8.count + 100
            if count + size > batchBytes && !current.isEmpty { groups.append(current); current = []; count = 0 }
            current.append(summary); count += size
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }
}
