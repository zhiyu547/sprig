// Copyright (c) 2026 zhiyu
// SPDX-License-Identifier: LicenseRef-Sprig-NC-SA-1.0

import AppKit
import Combine
import Sparkle
import SwiftUI

struct UpdateConfiguration {
    let feedURL: URL
    let publicKey: String

    init?(info: [String: Any]) {
        guard let feed = info["SUFeedURL"] as? String,
              let url = URL(string: feed), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.fragment == nil,
              let key = info["SUPublicEDKey"] as? String,
              Data(base64Encoded: key)?.count == 32 else { return nil }
        feedURL = url; publicKey = key
    }
}

@MainActor final class UpdateInstallationGate {
    private var pending: (() -> Void)?
    func postpone(if blocked: Bool, install: @escaping () -> Void) -> Bool {
        guard blocked else { return false }
        pending = install
        return true
    }
    func resume(ifReady ready: Bool) {
        guard ready, let install = pending else { return }
        pending = nil
        install()
    }
}

@MainActor final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = AppUpdater()
    @Published private(set) var available = false
    @Published private(set) var canCheck = false
    @Published private(set) var automaticallyChecks = false
    @Published private(set) var lastChecked: Date?
    @Published private(set) var status = "开发构建未配置更新源。"
    private var controller: SPUStandardUpdaterController?
    private weak var store: RepositoryStore?
    private var subscriptions = Set<AnyCancellable>()
    private let installationGate = UpdateInstallationGate()

    func start(store: RepositoryStore) {
        guard controller == nil, Bundle.main.bundleURL.pathExtension == "app",
              UpdateConfiguration(info: Bundle.main.infoDictionary ?? [:]) != nil else { return }
        self.store = store
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates).receive(on: DispatchQueue.main).assign(to: &$canCheck)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates).receive(on: DispatchQueue.main).assign(to: &$automaticallyChecks)
        controller.updater.publisher(for: \.lastUpdateCheckDate).receive(on: DispatchQueue.main).assign(to: &$lastChecked)
        // Observe after the model's values have changed. Never terminate an active Git operation.
        store.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self else { return }
            self.installationGate.resume(ifReady: !self.isBusy)
        }.store(in: &subscriptions)
        do {
            try controller.updater.start()
            available = true; status = "从 GitHub 获取版本信息，安装前验证更新包签名。"
        } catch { status = "更新服务启动失败：\(error.localizedDescription)" }
    }

    private var isBusy: Bool {
        guard let store else { return false }
        return store.busy || store.aiStartedAt != nil || store.opening || store.sheet != nil
    }

    func check() {
        guard available, canCheck else { return }
        controller?.checkForUpdates(nil)
    }

    func setAutomaticallyChecks(_ enabled: Bool) {
        controller?.updater.automaticallyChecksForUpdates = enabled
    }

    @objc(updater:shouldPostponeRelaunchForUpdate:untilInvokingBlock:)
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard installationGate.postpone(if: isBusy, install: installHandler) else { return false }
        store?.notice = "更新已准备好，将在当前操作及对话框结束后安装。"
        return true
    }

    static func showLicense() {
        guard let url = Bundle.main.url(forResource: "LICENSE", withExtension: "txt", subdirectory: "Licenses") else { return }
        NSWorkspace.shared.open(url)
    }

    static func showThirdPartyNotices() {
        guard let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "txt", subdirectory: "Licenses") else { return }
        NSWorkspace.shared.open(url)
    }
}

struct AboutSprigView: View {
    @ObservedObject private var updater = AppUpdater.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 16) {
                Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                    .resizable().interpolation(.high).frame(width: 72, height: 72)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Sprig").font(.system(size: 26, weight: .semibold))
                    Text("轻量 Git 工作台").font(.callout).foregroundStyle(.secondary)
                    Text("版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版") · Build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            HStack {
                Toggle("自动检查更新", isOn: Binding(get: { updater.automaticallyChecks }, set: { updater.setAutomaticallyChecks($0) }))
                    .disabled(!updater.available)
                Spacer()
                Button("检查更新…") { updater.check() }.disabled(!updater.canCheck || !updater.available)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(updater.available ? "每天检查新版本，安装前由你确认。" : updater.status)
                if let date = updater.lastChecked {
                    Text("上次检查：\(date.formatted(date: .abbreviated, time: .shortened))")
                }
                Text("更新检查不上传仓库或 AI 配置。")
            }
            .font(.caption).foregroundStyle(.secondary)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Copyright © 2026 zhiyu").font(.caption)
                Text("源码公开 · 允许企业内部使用\n商业分发与对外商业服务须另行授权")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 16) {
                    Button("使用许可", action: AppUpdater.showLicense).buttonStyle(.link)
                    Button("第三方声明", action: AppUpdater.showThirdPartyNotices).buttonStyle(.link)
                    Link("项目主页", destination: URL(string: "https://github.com/zhiyu547/sprig")!)
                }.font(.caption)
            }
        }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
