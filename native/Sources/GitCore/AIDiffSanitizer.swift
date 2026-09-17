// Copyright (c) 2026 zhiyu
// SPDX-License-Identifier: LicenseRef-Sprig-NC-SA-1.0

import Foundation

/// Produces the only version of a diff that is allowed into an AI context.
/// Ambiguous multiline values stay local rather than being partially masked.
enum AIDiffSanitizer {
    enum Result {
        case text(String, redactedLines: Int)
        case excluded(String)
    }
    static func sanitize(_ patch: String) throws -> Result {
        let privateKey = try NSRegularExpression(pattern: "(?i)-----BEGIN (?:[A-Z0-9 ]+ )?PRIVATE KEY-----")
        if privateKey.firstMatch(in: patch, range: NSRange(patch.startIndex..., in: patch)) != nil {
            return .excluded("包含私钥内容，未发送")
        }
        // Also mask short values. Length/entropy guesses should not decide whether
        // a password is sent. The rest of a matching line is intentionally omitted.
        let assignment = try NSRegularExpression(pattern: #"(?i)(?<![a-z0-9_])["']?(?:api[_-]?key|access[_-]?token|refresh[_-]?token|auth[_-]?token|client[_-]?secret|password|passwd|secret|private[_-]?key)["']?\s*[:=]"#)
        let credentialURL = try NSRegularExpression(pattern: #"(?i)[a-z][a-z0-9+.-]*://[^\s/@:]+:[^\s/@]+@"#)
        let authorization = try NSRegularExpression(pattern: #"(?i)\b(?:Bearer|Basic)\s+[a-z0-9+/_=.-]+"#)
        var count = 0
        var lines: [String] = []
        var inHunk = false
        var plainValueIndent: Int?
        for line in patch.components(separatedBy: "\n") {
            if line.hasPrefix("diff --git ") { inHunk = false; plainValueIndent = nil }
            if line.hasPrefix("@@ ") { inHunk = true; plainValueIndent = nil; lines.append(line); continue }
            guard inHunk, let marker = line.first, [" ", "+", "-"].contains(marker) else { lines.append(line); continue }
            var body = String(line.dropFirst())
            let indent = body.prefix { $0 == " " || $0 == "\t" }.count
            if let previousIndent = plainValueIndent, !body.trimmingCharacters(in: .whitespaces).isEmpty, indent > previousIndent {
                return .excluded("敏感字段可能有跨行续写，无法可靠脱敏")
            }
            plainValueIndent = nil
            var masked = false
            if let match = assignment.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)), let range = Range(match.range, in: body) {
                let value = body[range.upperBound...].trimmingCharacters(in: .whitespaces)
                // A block, folded scalar, or open quote can continue on following
                // lines. Without parsing the complete file, it cannot be masked safely.
                if value.isEmpty || ["|", ">", "#", "{", "[", "(", "\"\"\"", "'''"].contains(where: { value.hasPrefix($0) }) || value.hasSuffix("\\") {
                    return .excluded("包含多行或空值敏感字段，无法可靠脱敏")
                }
                if let quote = value.first, quote == "\"" || quote == "'" {
                    let tail = String(value.dropFirst())
                    let closing = try NSRegularExpression(pattern: quote == "\"" ? #"(?<!\\)""# : "'")
                    if closing.firstMatch(in: tail, range: NSRange(tail.startIndex..., in: tail)) == nil {
                        return .excluded("包含跨行敏感值，无法可靠脱敏")
                    }
                }
                if value.first != "\"" && value.first != "'" { plainValueIndent = indent }
                body = String(body[..<range.upperBound]) + " [REDACTED]"
                masked = true
            }
            for (regex, replacement) in [(credentialURL, "[REDACTED-URL-CREDENTIALS]@"), (authorization, "[REDACTED-AUTHORIZATION]")] {
                let range = NSRange(body.startIndex..., in: body)
                if regex.firstMatch(in: body, range: range) != nil {
                    body = regex.stringByReplacingMatches(in: body, range: range, withTemplate: replacement)
                    masked = true
                }
            }
            if masked { count += 1 }
            lines.append(String(marker) + body)
        }
        return .text(lines.joined(separator: "\n"), redactedLines: count)
    }
}
