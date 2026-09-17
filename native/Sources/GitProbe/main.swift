// Copyright (c) 2026 zhiyu
// SPDX-License-Identifier: LicenseRef-Sprig-NC-SA-1.0

import Foundation
import GitCore

@main struct GitProbe {
    static func main() async {
        do {
            guard CommandLine.arguments.count > 1 else { throw GitError.message("Usage: GitProbe <repository> [path] [staged|working] | GitProbe <repository> --ai-check") }
            let start = Date()
            let repo = try await GitRepository.open(URL(fileURLWithPath: CommandLine.arguments[1]))
            if CommandLine.arguments.contains("--ai-check") {
                let context = try await repo.aiContext(configuration: AIConfiguration())
                let report: [String: Any] = ["canGenerate": context.canGenerate, "included": context.included, "excluded": context.excluded, "redacted": context.redacted, "sanitizedPatchBytes": context.patch.utf8.count]
                print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
                return
            }
            let state = try await repo.snapshot()
            var report: [String: Any] = ["root": repo.root.path, "branch": state.branch, "head": state.head, "files": state.files.map { ["path": $0.path, "status": $0.scopeLabel, "staged": $0.hasStaged, "working": $0.hasWorking] as [String: Any] }, "statusMilliseconds": Int(Date().timeIntervalSince(start) * 1000)]
            if CommandLine.arguments.count > 2, let file = state.files.first(where: { $0.path == CommandLine.arguments[2] }) {
                let scope = CommandLine.arguments.count > 3 && CommandLine.arguments[3] == "staged" ? DiffScope.staged : .working
                let diffStart = Date(), diff = try await repo.diff(for: file, scope: scope)
                report["diff"] = ["additions": diff.additions, "deletions": diff.deletions, "rows": diff.lines.count, "message": diff.message ?? "", "milliseconds": Int(Date().timeIntervalSince(diffStart) * 1000)]
            }
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self))
        } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
    }
}
