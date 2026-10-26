// Copyright (c) 2026 zhiyu
// SPDX-License-Identifier: LicenseRef-Sprig-NC-SA-1.0

import Foundation
import GitCore

extension RepositoryStore {
    func runNetworkOperation(_ title: String, cancellable: Bool = true,
                             _ action: @escaping @MainActor (GitRepository, GitNetworkOperation) async throws -> String) {
        guard !busy, repository != nil else { return }
        let id = UUID()
        let operation = GitNetworkOperation { [weak self] progress in
            Task { @MainActor [weak self] in
                guard let self, self.networkOperationID == id, !self.networkCancelling else { return }
                self.networkProgress = progress
            }
        }
        networkOperationID = id; networkOperation = operation
        networkStartedAt = Date(); networkProgress = ""; networkCancelling = false; networkCanCancel = cancellable
        runOperation(title) { repo in
            defer { self.finishNetworkOperation() }
            do { return try await action(repo, operation) }
            catch is CancellationError {
                return "已取消网络操作，本地提交与同步恢复记录已保留。远端可能已接收推送，请核对远端状态后继续。"
            }
        }
    }

    func cancelNetworkOperation() {
        guard busy, networkCanCancel, let networkOperation, !networkCancelling else { return }
        networkCancelling = true
        networkProgress = "正在停止；等待本地整合或恢复安全结束"
        // Do not cancel operationTask: local merge/stash recovery must finish.
        networkOperation.cancel()
    }

    func networkStage(_ title: String) {
        busyTitle = title
        if !networkCancelling { networkProgress = "" }
    }

    private func finishNetworkOperation() {
        networkOperationID = nil; networkOperation = nil; networkStartedAt = nil
        networkProgress = ""; networkCancelling = false; networkCanCancel = false
    }
}
