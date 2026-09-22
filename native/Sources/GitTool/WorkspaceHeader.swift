// Copyright (c) 2026 zhiyu
// SPDX-License-Identifier: LicenseRef-Sprig-NC-SA-1.0

import AppKit
import SwiftUI

struct WorkspaceHeader: View {
    @ObservedObject var store: RepositoryStore

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 1100
            HStack(spacing: 12) {
                repositories(compact: compact).frame(maxWidth: .infinity, alignment: .leading)
                if store.snapshot != nil { navigation.frame(width: 248) }
                actions(compact: compact).frame(maxWidth: .infinity, alignment: .trailing)
            }.padding(.horizontal, 16).frame(height: 62)
        }.frame(height: 62).background(Palette.toolbar).overlay(alignment: .bottom) { Divider() }
    }

    private func repositories(compact: Bool) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high)
                .frame(width: 26, height: 26).accessibilityHidden(true).padding(.trailing, 4)
            Menu {
                Button("打开仓库…", action: store.chooseRepository)
                if !store.recent.isEmpty {
                    Divider()
                    ForEach(store.recent, id: \.self) { path in
                        Button(visiblePath(path)) { store.open(URL(fileURLWithPath: path)) }
                    }
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    Text(store.snapshot?.root.lastPathComponent ?? "Sprig").lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: compact ? 76 : 140)
                }
            }.menuStyle(.borderlessButton).menuIndicator(.visible).fixedSize()
                .modifier(ControlSurface(tone: .subtle, height: 34))
                .help("切换或打开仓库").accessibilityLabel("仓库选择")
            if store.snapshot != nil {
                Button { store.loadAuxiliary(); store.showBranches.toggle() } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "arrow.triangle.branch").foregroundStyle(Palette.blue)
                        Text(store.branchTitle).lineLimit(1).truncationMode(.middle).frame(maxWidth: compact ? 76 : 140)
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                    }
                }.buttonStyle(SprigButtonStyle(tone: store.showBranches ? .selected : .subtle, height: 34)).fixedSize()
                    .help("查看、创建与切换分支").accessibilityLabel("当前分支：" + store.branchTitle)
                    .popover(isPresented: $store.showBranches) { BranchPopover(store: store) }
            }
        }.disabled(store.blockingBusy).allowsHitTesting(!store.busy)
    }

    private var navigation: some View {
        HStack(spacing: 6) {
            ForEach(WorkspacePage.allCases) { page in
                Button { store.page = page } label: {
                    Text(page.rawValue).font(.system(size: 13, weight: store.page == page ? .semibold : .regular))
                        .foregroundStyle(store.page == page ? .primary : .secondary)
                        .frame(maxWidth: .infinity).frame(height: 36).contentShape(Rectangle())
                }.buttonStyle(SprigButtonStyle(height: 36, horizontalPadding: 5))
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(store.page == page ? Palette.blue : .clear).frame(height: 2).padding(.horizontal, 7).allowsHitTesting(false)
                    }
                    .accessibilityLabel(page.rawValue).accessibilityValue(store.page == page ? "当前页面" : "")
            }
        }.accessibilityElement(children: .contain).accessibilityLabel("工作区页面")
    }

    private func actions(compact: Bool) -> some View {
        HStack(spacing: 4) {
            if store.snapshot != nil {
                syncButton("获取", symbol: "arrow.down.to.line", compact: compact, help: "获取远端更新 · Fetch") {
                    store.runOperation("获取远端更新") { try await $0.fetch() }
                }
                syncButton("拉取", symbol: "arrow.down", compact: compact, help: "更新项目：快进拉取 · Pull") {
                    store.runOperation("快进拉取") { try await $0.pull() }
                }
                syncButton("推送", symbol: "arrow.up", compact: false, help: "推送当前提交", action: store.openPush)
                Rectangle().fill(Palette.border).frame(width: 1, height: 18).padding(.horizontal, 5)
            }
            ToolbarIconButton(title: "设置", symbol: "gearshape", tooltip: "设置 · ⌘,") { store.sheet = WorkspaceSheet(kind: .settings) }
        }.disabled(store.blockingBusy).allowsHitTesting(!store.busy)
    }

    private func syncButton(_ title: String, symbol: String, compact: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                if !compact { Text(title) }
            }.frame(minWidth: compact ? 18 : 42).frame(height: 32).contentShape(Rectangle())
        }.buttonStyle(SprigButtonStyle(horizontalPadding: 7)).help(help).accessibilityLabel(help)
    }
}

/// Operation feedback lives in the permanent footer so index writes cannot move the workspace.
struct WorkspaceActivity: View {
    @ObservedObject var store: RepositoryStore
    var body: some View {
        HStack(spacing: 7) {
            if store.blockingBusy {
                ProgressView().controlSize(.mini)
                Text(store.busyTitle).lineLimit(1)
                if let start = store.aiStartedAt {
                    TimelineView(.periodic(from: start, by: 1)) { context in
                        Text("\(Int(context.date.timeIntervalSince(start))) 秒").monospacedDigit()
                    }
                    Button("取消", action: store.cancelAI)
                }
            }
            if store.updatingIndex { DelayedActivity(label: store.busyTitle).id(store.busyTitle) }
            if store.pendingPushOID != nil && store.synchronizedPushSession == nil && !store.busy {
                Button("继续推送", action: store.retryPush).help("仅重试推送，不重复提交")
            }
        }
    }
}

struct RefreshControl: View {
    @ObservedObject var store: RepositoryStore
    var showLabel = true
    var body: some View {
        HStack(spacing: 3) {
            ToolbarIconButton(title: "刷新本地更改", symbol: "arrow.triangle.2.circlepath", size: 30,
                              tooltip: "刷新本地更改 · ⌘R（不拉取远端）", action: store.manualRefresh)
                .accessibilityIdentifier("workspace.refresh")
                .disabled(store.manualRefreshState == .refreshing)
                .overlay { if store.manualRefreshState == .refreshing { DelayedActivity(label: "").frame(width: 30, height: 30) } }
            if showLabel {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(label(at: context.date)).font(.system(size: 10)).foregroundStyle(store.manualRefreshState == .failed ? Color.orange : .secondary)
                        .lineLimit(1).frame(width: 74, alignment: .leading)
                }.help("手动刷新本地文件、暂存状态与分支；远端更新请使用顶部的获取或拉取。")
            }
        }.fixedSize()
    }
    private func label(at date: Date) -> String {
        switch store.manualRefreshState {
        case .idle: return "本地更改"
        case .refreshing: return "正在刷新…"
        case .failed: return "刷新失败"
        case .updated(let completed):
            let minutes = max(0, Int(date.timeIntervalSince(completed) / 60))
            return minutes == 0 ? "已刷新 · 刚刚" : minutes < 60 ? "已刷新 · \(minutes)分" : "已刷新 · \(minutes / 60)时"
        }
    }
}
