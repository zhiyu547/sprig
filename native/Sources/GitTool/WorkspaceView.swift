// Copyright (c) 2026 zhiyu
// SPDX-License-Identifier: LicenseRef-Sprig-NC-SA-1.0

import SwiftUI
import AppKit
import GitCore

enum Palette {
    static let codeNS = NSColor(srgbRed: 0.09, green: 0.105, blue: 0.12, alpha: 1)
    static let code = Color(nsColor: codeNS)
    static let sidebar = Color(red: 0.125, green: 0.14, blue: 0.16)
    static let toolbar = Color(red: 0.14, green: 0.16, blue: 0.18)
    static let border = Color.white.opacity(0.09)
    static let blue = Color(red: 0.30, green: 0.55, blue: 0.98)
    static let mint = Color(red: 0.55, green: 0.85, blue: 0.69)
    static let newFile = Color(red: 0.96, green: 0.54, blue: 0.52)
}
func visiblePath(_ value: String) -> String { value.replacingOccurrences(of: "\n", with: "↵").replacingOccurrences(of: "\t", with: "⇥") }
func copyText(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }

/// Fast local reads/writes need no spinner flash. Longer operations retain feedback.
struct DelayedActivity: View {
    let label: String
    @State private var visible = false
    var body: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
        }.padding(6).background(Palette.sidebar, in: RoundedRectangle(cornerRadius: 5))
            .opacity(visible ? 1 : 0).allowsHitTesting(false).accessibilityHidden(!visible)
            .task {
                do { try await Task.sleep(nanoseconds: 180_000_000); visible = true }
                catch { }
            }
    }
}

struct WorkspaceView: View {
    @ObservedObject var store: RepositoryStore
    var body: some View {
        VStack(spacing: 0) {
            WorkspaceHeader(store: store)
            if store.opening { ProgressView("正在读取仓库…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if store.snapshot != nil {
                switch store.page {
                case .changes: NativeSplitView { ChangeSidebar(store: store) } right: { LiveDiffPane(store: store) }
                case .history: NativeSplitView { HistorySidebar(store: store) } right: { HistoryDetails(store: store) }
                case .stashes: NativeSplitView { StashSidebar(store: store) } right: { StashDetails(store: store) }
                case .console: console
                }
                footer
            } else { welcome }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Palette.code).preferredColorScheme(.dark)
            .overlay(alignment: .bottomTrailing) {
                // Feedback never inserts/removes space above the file list.
                Group {
                    if let error = store.error { banner(error, failed: true) }
                    else if let notice = store.notice { banner(notice, failed: false) }
                }.frame(maxWidth: 520).background(Palette.sidebar, in: RoundedRectangle(cornerRadius: 8))
                    .clipShape(RoundedRectangle(cornerRadius: 8)).shadow(color: .black.opacity(0.25), radius: 8)
                    .padding(.trailing, 16).padding(.bottom, 40)
            }
            .sheet(item: $store.sheet) { item in WorkspaceSheetView(store: store, sheet: item) }
            .onChange(of: store.page) { page in if page == .history { store.loadHistory() }; if page == .stashes { store.loadAuxiliary() } }
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                guard !store.busy, let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }; let directory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                    Task { @MainActor in store.open(directory ? url : url.deletingLastPathComponent()) }
                }; return true
            }
    }
    private func banner(_ value: String, failed: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: failed ? "exclamationmark.triangle" : "checkmark.circle").foregroundStyle(failed ? .orange : Palette.mint)
            Text(String(value.prefix(1200))).font(.system(size: 11)).lineLimit(3).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            Button { store.sheet = WorkspaceSheet(kind: .report(failed ? "操作提示" : "操作结果", value)) } label: { Image(systemName: "arrow.up.right.square") }.buttonStyle(.plain).help("查看完整信息")
            Button { store.error = nil; store.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("关闭提示")
        }.padding(10).background((failed ? Color.orange : Palette.mint).opacity(0.08))
    }
    private var welcome: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 106, height: 106)
            Text("Sprig").font(.system(size: 34, weight: .semibold))
            Text("让每一次提交，都清晰可见。").font(.system(size: 16)).foregroundStyle(.secondary)
            Button("打开 Git 仓库…", action: store.chooseRepository).buttonStyle(.borderedProminent).controlSize(.large).tint(Palette.blue)
            Text("也可以将本地仓库文件夹拖到这里").font(.system(size: 12)).foregroundStyle(.secondary)
            if !store.recent.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("最近打开").font(.system(size: 11)).foregroundStyle(.secondary)
                    ForEach(store.recent.prefix(4), id: \.self) { path in
                        Button { store.open(URL(fileURLWithPath: path)) } label: { HStack { Image(systemName: "folder"); Text(visiblePath((path as NSString).lastPathComponent)); Spacer(); Image(systemName: "arrow.up.left") } }.buttonStyle(.plain).help(path)
                    }
                }.padding(16).frame(width: 340).background(Palette.sidebar, in: RoundedRectangle(cornerRadius: 9)).padding(.top, 12)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var footer: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(store.watching ? Palette.mint : .secondary)
                Text(store.watching ? "自动刷新" : "手动刷新")
            }
            WorkspaceActivity(store: store)
            if let session = store.synchronizedPushSession {
                Text(session.status).foregroundStyle(.orange).lineLimit(1)
                Button(session.needsRestoreReview ? "恢复已核对，继续" : "继续同步并推送", action: store.retryPush).disabled(store.busy)
                Button("取消同步", action: store.cancelPush).disabled(store.busy)
            } else if let operation = store.snapshot?.operation {
                Text(operation).foregroundStyle(.orange)
                Button("继续") { store.runOperation("继续 Git 操作") { try await $0.continueOperation(abort: false) } }.disabled(store.blockingBusy).allowsHitTesting(!store.busy)
                Button("中止") { store.confirm("中止当前 Git 操作？", message: operation, button: "中止") { store.runOperation("中止 Git 操作") { try await $0.continueOperation(abort: true) } } }.disabled(store.blockingBusy).allowsHitTesting(!store.busy)
            }
            Spacer()
            if let upstream = store.snapshot?.upstream { Text("\(upstream)  ↑\(store.snapshot?.ahead ?? 0) ↓\(store.snapshot?.behind ?? 0)").lineLimit(1).help("本地已知远端状态，点击 Fetch 更新") }
            if let date = store.updatedAt { Text("\(date.formatted(date: .omitted, time: .standard)) · \(store.refreshMilliseconds) ms") }
        }.font(.system(size: 10)).foregroundStyle(.secondary).controlSize(.mini).padding(.horizontal, 16).frame(height: 28).background(Palette.sidebar.opacity(0.5)).overlay(alignment: .top) { Divider() }
    }
    private var console: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if store.console.isEmpty { Text("Git 操作的结果与错误会显示在这里。").foregroundStyle(.secondary) }
                ForEach(store.console) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { Text(item.title).fontWeight(.semibold); Spacer(); Text(item.date.formatted(date: .omitted, time: .standard)).foregroundStyle(.secondary) }.foregroundStyle(item.failed ? .orange : Palette.mint)
                        Text(item.output).textSelection(.enabled).font(.system(size: 12, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(14).background(Palette.sidebar, in: RoundedRectangle(cornerRadius: 7))
                }
            }.padding(20)
        }
    }
}

struct ChangeSidebar: View {
    @ObservedObject var store: RepositoryStore
    var body: some View {
        CommitSplitView {
            VStack(spacing: 0) {
                toolbar
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索更改文件", text: $store.query).textFieldStyle(.plain).accessibilityLabel("搜索更改文件")
                    if !store.query.isEmpty {
                        Button { store.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).help("清除搜索").accessibilityLabel("清除搜索")
                    }
                }.font(.system(size: 12)).padding(.horizontal, 10).frame(height: 32)
                    .background(Palette.code.opacity(0.65), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.border)).padding(.horizontal, 12)
                SelectionStrip(selection: $store.filter, options: [("全部", "all"), ("已暂存", "staged"), ("工作区", "working")])
                    .accessibilityLabel("文件筛选").padding(12)
                ScrollView {
                    LazyVStack(spacing: 4) {
                        group("更改", files: store.changedFiles, expanded: $store.trackedExpanded)
                        if !store.newFiles.isEmpty {
                            group("未进行版本管理的文件", files: store.newFiles, expanded: $store.untrackedExpanded)
                        }
                        if store.files.isEmpty { Text(store.snapshot?.files.isEmpty == true ? "工作区干净" : "没有匹配文件").font(.system(size: 12)).foregroundStyle(.secondary).padding(20) }
                    }.padding(.horizontal, 8).padding(.bottom, 10)
                }.frame(maxHeight: .infinity)
            }.background(Palette.sidebar)
        } editor: {
            CommitEditor(store: store)
        }.background(Palette.sidebar)
    }
    private var toolbar: some View {
        GeometryReader { geometry in
            HStack(spacing: 2) {
                RefreshControl(store: store, showLabel: geometry.size.width >= 320)
                Rectangle().fill(Palette.border).frame(width: 1, height: 16).padding(.horizontal, 4)
                ToolbarIconButton(title: "恢复当前文件未暂存的修改", symbol: "arrow.uturn.backward", size: 28, action: store.discardSelected)
                    .disabled(store.selected == nil || store.selected?.hasWorking != true || store.selected?.untracked == true)
                Menu {
                    if let selected = store.selected {
                        Button("暂存当前文件全部修改") { store.stageFiles([selected]) }
                        Button("取消暂存当前文件") { store.unstageFiles([selected]) }
                        Divider()
                    }
                    Button("暂存所有更改") { store.stageFiles(store.files.filter { !$0.untracked }) }
                    Button("取消全部暂存") { store.unstageFiles(store.snapshot?.files.filter(\.hasStaged) ?? []) }
                } label: { Image(systemName: "arrow.down.to.line").frame(width: 28, height: 28).contentShape(Rectangle()) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .modifier(ControlSurface(tone: .quiet, height: 28, horizontalPadding: 0))
                    .help("调整暂存范围").accessibilityLabel("调整暂存范围")
                ToolbarIconButton(title: "储藏当前修改", symbol: "archivebox", size: 28) { store.sheet = WorkspaceSheet(kind: .stash) }
                ToolbarIconButton(title: "显示／隐藏 Diff", symbol: store.showDiff ? "eye" : "eye.slash", size: 28) { store.showDiff.toggle() }
                Spacer(minLength: 0)
                Menu {
                    Button("在 Finder 中定位当前文件", action: store.revealFile).disabled(store.selected == nil)
                    Divider()
                    Button("展开所有分组") { store.trackedExpanded = true; store.untrackedExpanded = true }
                    Button("折叠所有分组") { store.trackedExpanded = false; store.untrackedExpanded = false }
                } label: { Image(systemName: "ellipsis").frame(width: 28, height: 28).contentShape(Rectangle()) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .modifier(ControlSurface(tone: .quiet, height: 28, horizontalPadding: 0))
                    .help("更多文件操作").accessibilityLabel("更多文件操作")
            }.padding(.horizontal, 10).frame(height: 46).disabled(store.blockingBusy).allowsHitTesting(!store.busy)
        }.frame(height: 46)
    }
    private func group(_ title: String, files: [ChangedFile], expanded: Binding<Bool>) -> some View {
        VStack(spacing: 3) {
            // Adjacent hit regions keep staging separate from disclosure.
            HStack(spacing: 0) {
                Button { expanded.wrappedValue.toggle() } label: {
                    Image(systemName: expanded.wrappedValue ? "chevron.down" : "chevron.right")
                        .frame(width: 28, height: 32).contentShape(Rectangle())
                }.buttonStyle(.plain).help("展开或折叠 " + title)
                    .accessibilityLabel("展开或折叠 " + title)
                    .accessibilityValue(expanded.wrappedValue ? "已展开" : "已折叠")
                Button { store.toggleGroup(files) } label: {
                    Image(systemName: !files.isEmpty && files.allSatisfy(\.hasStaged) ? "checkmark.square.fill" : files.contains(where: \.hasStaged) ? "minus.square.fill" : "square")
                        .font(.system(size: 16)).foregroundStyle(files.contains(where: \.hasStaged) ? Palette.blue : .secondary)
                        .frame(width: 22, height: 32).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(store.blockingBusy || files.isEmpty).allowsHitTesting(!store.busy)
                    .help("暂存或取消暂存此组文件").accessibilityLabel("暂存或取消暂存 " + title)
                Button { expanded.wrappedValue.toggle() } label: {
                    HStack(spacing: 7) {
                        Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text("\(files.count)").font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }.padding(.leading, 3).padding(.trailing, 8)
                        .frame(maxWidth: .infinity).frame(height: 32).contentShape(Rectangle())
                }.buttonStyle(.plain).help("展开或折叠 " + title)
                    .accessibilityLabel(title + "，\(files.count) 个文件")
                    .accessibilityValue(expanded.wrappedValue ? "已展开" : "已折叠")
            }.background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 5))
            if expanded.wrappedValue || !store.query.isEmpty { ForEach(files) { file in row(file) } }
        }
    }
    private func row(_ file: ChangedFile) -> some View {
        HStack(spacing: 5) {
            Button { store.toggleStage(file) } label: { Image(systemName: file.conflict ? "exclamationmark.triangle" : file.hasStaged && file.hasWorking ? "minus.square.fill" : file.hasStaged ? "checkmark.square.fill" : "square").font(.system(size: 16)).foregroundStyle(file.conflict ? .orange : file.hasStaged ? Palette.blue : .secondary).frame(width: 24, height: 40).contentShape(Rectangle()) }.buttonStyle(.plain).accessibilityLabel((file.hasStaged ? "取消暂存 " : "暂存 ") + file.name).disabled(store.blockingBusy || file.conflict).allowsHitTesting(!store.busy).help(file.hasStaged ? "取消暂存 " + file.path : "暂存 " + file.path)
            Button { store.select(file) } label: {
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 3) { Text(visiblePath(file.name)).font(.system(size: 13, weight: .medium)).foregroundStyle(file.isNewFile ? Palette.newFile : .primary).lineLimit(1).truncationMode(.middle); Text(visiblePath(file.parent)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
                    Spacer(minLength: 0); Text(file.hasStaged && file.hasWorking ? "部分" : file.badge).font(.system(size: 11)).foregroundStyle(file.conflict ? .orange : file.isNewFile ? Palette.newFile : Palette.blue)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).help(visiblePath(file.path) + " · " + file.scopeLabel)
        }.padding(.leading, 24).padding(.trailing, 12).frame(height: 46).background(store.selectedPath == file.path ? Palette.blue.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contextMenu {
                Button("查看差异") { store.select(file) }
                if file.conflict { Button("标记为已解决…") { store.markResolved(file) }.disabled(store.busy) }
                Button("暂存全部修改") { store.stageFiles([file]) }.disabled(store.blockingBusy || file.conflict).allowsHitTesting(!store.busy)
                Button("取消暂存") { store.unstageFiles([file]) }.disabled(store.blockingBusy || !file.hasStaged).allowsHitTesting(!store.busy)
                Button("复制路径") { copyText(file.path) }
                Button("在 Finder 中显示") { store.select(file); store.revealFile() }
            }
    }
}

struct CommitEditor: View {
    @ObservedObject var store: RepositoryStore
    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 5) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        Text("提交说明").fontWeight(.semibold).fixedSize()
                        amendControls
                    }.fixedSize()
                    amendControls.fixedSize()
                }
                Spacer(minLength: 2)
                ToolbarIconButton(title: "AI 生成提交说明", symbol: "sparkles", tone: .accent, size: 30, tooltip: "AI 生成提交说明 · 基于已暂存内容") {
                    store.prepareAI(.commit)
                }.accessibilityIdentifier("commit.generateAI")
                messageHistory
            }.font(.system(size: 11))
            editorField
            commitActions
        }.padding(12).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.code.opacity(0.25)).disabled(store.blockingBusy).allowsHitTesting(!store.busy)
    }
    private var amendControls: some View {
        HStack(spacing: 7) {
            Toggle("修正", isOn: $store.amend).toggleStyle(.checkbox).help("修正上次提交，创建新的提交 ID")
            Button("上次提交", action: store.loadPreviousMessage).buttonStyle(.plain).foregroundStyle(Palette.blue).help("载入上次提交说明")
        }
    }
    private var messageHistory: some View {
        Menu {
            ForEach(Array(store.messageHistory.enumerated()), id: \.offset) { _, message in
                Button(String(message.split(separator: "\n").first ?? "")) { store.commitMessage = message }
            }
        } label: {
            Image(systemName: "clock.arrow.circlepath").font(.system(size: 13))
        }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 28)
            .modifier(ControlSurface(tone: .quiet, height: 28, horizontalPadding: 0))
            .help("提交说明历史").accessibilityLabel("提交说明历史")
    }
    private var editorField: some View {
        ZStack(alignment: .topLeading) {
            if store.commitMessage.isEmpty {
                Text("提交摘要\n\n描述本次变更的内容与原因…").font(.system(size: 12)).foregroundStyle(.tertiary).padding(9).allowsHitTesting(false)
            }
            TextEditor(text: $store.commitMessage).font(.system(size: 13, design: .monospaced)).scrollContentBackground(.hidden).padding(5).accessibilityLabel("提交说明")
        }.background(Palette.code, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Palette.border)).frame(minHeight: 96, maxHeight: .infinity)
    }
    private var commitActions: some View {
        VStack(spacing: 8) {
            HStack {
                Label("\(store.snapshot?.stagedCount ?? 0) 个文件已暂存", systemImage: "checkmark.circle")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Menu {
                    Button("本地提交检查", action: store.localChecks)
                    Button("AI 审查暂存内容") { store.prepareAI(.review) }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark.shield")
                        Text("检查")
                    }
                }.menuStyle(.borderlessButton).menuIndicator(.visible).fixedSize()
                    .modifier(ControlSurface(tone: .quiet, height: 26, horizontalPadding: 6)).accessibilityLabel("提交前检查")
            }
            HStack(spacing: 8) {
                Button { store.prepareCommit(push: false) } label: {
                    Label("提交", systemImage: "checkmark").frame(maxWidth: .infinity)
                }.buttonStyle(SprigButtonStyle(tone: .primary, height: 36)).help("提交已暂存内容 · ⌘K")
                Button { store.prepareCommit(push: true) } label: {
                    Label("提交并推送…", systemImage: "arrow.up").lineLimit(1).frame(maxWidth: .infinity)
                }.buttonStyle(SprigButtonStyle(tone: .subtle, height: 36)).help("提交后推送到远端 · ⇧⌘K")
            }.disabled(!store.hasCommitContent || store.blockingBusy)
            Text(store.aiSource == nil ? "勾选文件加入暂存区 · 仅提交已暂存内容" : "AI 草稿基于生成时的暂存快照，请确认范围").font(.system(size: 9)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct DocumentPane: View {
    let document: DiffDocument?
    let identity: String
    let leftLabel: String
    let rightLabel: String
    @Binding var split: Bool
    @State private var synchronizer = ScrollSynchronizer()
    var body: some View {
        if let document, !document.lines.isEmpty {
            VStack(spacing: 0) {
                if let message = document.message { Text(message).font(.system(size: 11)).foregroundStyle(.orange).padding(8) }
                HStack(spacing: 0) { Text(split ? leftLabel : leftLabel + " → " + rightLabel).frame(maxWidth: .infinity, alignment: .leading); if split { Text(rightLabel).frame(maxWidth: .infinity, alignment: .leading) } }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 12).frame(height: 28).background(Palette.toolbar)
                if split { HStack(spacing: 1) { DiffTable(lines: document.pairs.map(\.left), side: "left", synchronizer: synchronizer, identity: identity + "left", revision: document.raw); DiffTable(lines: document.pairs.map(\.right), side: "right", synchronizer: synchronizer, identity: identity + "right", revision: document.raw) }.background(Palette.border) }
                else { DiffTable(lines: document.lines.map(Optional.some), side: "unified", synchronizer: synchronizer, identity: identity + "unified", revision: document.raw) }
            }.clipShape(RoundedRectangle(cornerRadius: 5)).overlay(RoundedRectangle(cornerRadius: 5).stroke(Palette.border))
        } else {
            ScrollView { VStack(spacing: 15) { Image(systemName: "doc.text.magnifyingglass").font(.system(size: 30)); Text(document?.message ?? "选择文件查看差异").font(.system(size: 13)).textSelection(.enabled) }.foregroundStyle(.secondary).multilineTextAlignment(.center).padding(30).frame(maxWidth: .infinity) }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
struct LiveDiffPane: View {
    @ObservedObject var store: RepositoryStore
    var body: some View {
        VStack(spacing: 0) {
            if let file = store.previewFile {
                HStack {
                    VStack(alignment: .leading, spacing: 4) { Text(visiblePath(file.name)).font(.system(size: 16, weight: .semibold)); Text(file.originalPath.map { visiblePath($0) + " → " + visiblePath(file.path) } ?? visiblePath(file.path)).font(.system(size: 11)).foregroundStyle(.secondary) }.lineLimit(1).truncationMode(.middle)
                    Spacer()
                    HStack(spacing: 2) {
                        ToolbarIconButton(title: "上一个文件", symbol: "chevron.up", size: 30) { store.moveFile(-1) }
                        Rectangle().fill(Palette.border).frame(width: 1, height: 13)
                        ToolbarIconButton(title: "下一个文件", symbol: "chevron.down", size: 30) { store.moveFile(1) }
                    }.padding(2).background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.border))
                    DiffModeControl(split: $store.split).padding(.leading, 4)
                }.padding(16)
                HStack(spacing: 9) {
                    Text("差异范围").foregroundStyle(.secondary)
                    SelectionStrip(selection: Binding(get: { store.previewScope }, set: store.changeScope), options: [("已暂存", DiffScope.staged), ("工作区", DiffScope.working)])
                        .frame(width: 150).accessibilityLabel("差异范围")
                    Text(file.scopeLabel).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if let document = store.document { Text("+\(document.additions)").foregroundStyle(Palette.mint); Text("−\(document.deletions)").foregroundStyle(Palette.newFile) }
                    Menu { Button("上一个变更块") { store.navigateHunk(-1) }; Button("下一个变更块") { store.navigateHunk(1) }; Divider(); Button("复制 Diff") { copyText(store.document?.raw ?? "") }; Button("导出补丁…", action: store.exportPatch); Button("在 Finder 中显示", action: store.revealFile) } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
                }.font(.system(size: 11)).padding(.horizontal, 16).padding(.bottom, 10)
                if !store.showDiff { VStack(spacing: 12) { Text("差异预览已隐藏"); Button("显示差异") { store.showDiff = true } }.frame(maxWidth: .infinity, maxHeight: .infinity) }
                else {
                    DocumentPane(document: store.document, identity: store.documentIdentity, leftLabel: store.previewScope == .staged ? "HEAD" : "暂存区", rightLabel: store.previewScope == .staged ? "暂存区" : "工作区", split: $store.split)
                        .overlay(alignment: .topTrailing) {
                            if store.loadingDiff {
                                DelayedActivity(label: "正在更新差异…").padding(8).id(store.selectedPath)
                            } else if let error = store.diffError {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("更新失败，保留上次预览").fontWeight(.semibold)
                                    Text(error).lineLimit(4).textSelection(.enabled)
                                    Button("重试", action: store.loadDiff)
                                }.font(.system(size: 12)).padding(12).frame(maxWidth: 400).background(Palette.sidebar, in: RoundedRectangle(cornerRadius: 6)).padding(8)
                            }
                        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(.horizontal, 12).padding(.bottom, 12)
                }
            } else { VStack(spacing: 18) { Image(systemName: "checkmark.circle").font(.system(size: 40)).foregroundStyle(Palette.mint); Text("工作区干净").font(.system(size: 23)); Text("修改代码后，这里会自动更新。").foregroundStyle(.secondary) }.frame(maxWidth: .infinity, maxHeight: .infinity) }
        }.background(Palette.code)
    }
}

struct HistorySidebar: View {
    @ObservedObject var store: RepositoryStore
    var body: some View {
        VStack(spacing: 10) {
            HStack { Text("提交历史").font(.system(size: 16, weight: .semibold)); Spacer(); if store.historyLoading { ProgressView().controlSize(.small) }; Button { store.loadHistory() } label: { Image(systemName: "arrow.clockwise") } }.padding(.horizontal, 13).padding(.top, 14)
            TextField("搜索说明或哈希，回车查询", text: $store.historyQuery).textFieldStyle(.roundedBorder).onSubmit { store.loadHistory() }.padding(.horizontal, 12)
            HStack { Toggle("所有分支", isOn: $store.historyAll).onChange(of: store.historyAll) { _ in store.loadHistory() }; TextField("作者", text: $store.historyAuthor).textFieldStyle(.roundedBorder).onSubmit { store.loadHistory() } }.font(.system(size: 11)).padding(.horizontal, 12)
            ScrollView {
                LazyVStack(spacing: 3) {
                    if store.history.isEmpty && !store.historyLoading { Text("没有匹配的提交").foregroundStyle(.secondary).padding(20) }
                    ForEach(store.history) { commit in
                        Button { store.selectCommit(commit) } label: {
                            HStack(alignment: .top, spacing: 9) {
                                Image(systemName: commit.parents.count > 1 ? "arrow.triangle.merge" : "circle.fill").font(.system(size: 10)).foregroundStyle(Palette.mint).padding(.top, 4)
                                VStack(alignment: .leading, spacing: 5) { Text(commit.subject).font(.system(size: 12, weight: .medium)).lineLimit(2); Text("\(commit.oid.prefix(7)) · \(commit.author)").font(.system(size: 10)).foregroundStyle(.secondary); if !commit.decorations.isEmpty { Text(commit.decorations).font(.system(size: 9)).foregroundStyle(Palette.blue).lineLimit(1) } }.frame(maxWidth: .infinity, alignment: .leading)
                            }.padding(10).contentShape(Rectangle()).background(store.selectedCommit?.oid == commit.oid ? Palette.blue.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 5))
                        }.buttonStyle(.plain).contextMenu { Button("复制提交哈希") { copyText(commit.oid) }; Button("复制提交说明") { copyText(commit.message) }; Button("Cherry-pick 到当前分支") { store.integrate("cherry-pick", revision: commit.oid, label: "Cherry-pick") }; Button("创建反向提交 Revert") { store.integrate("revert", revision: commit.oid, label: "Revert") }; Button("从此提交新建分支…") { store.sheet = WorkspaceSheet(kind: .newBranch(commit.oid)) }; Button("创建标签…") { store.sheet = WorkspaceSheet(kind: .newTag(commit.oid)) } }
                    }
                    if store.historyMore { Button("加载更多") { store.loadHistory(more: true) }.disabled(store.historyLoading).padding(10) }
                }.padding(.horizontal, 7)
            }
        }.background(Palette.sidebar)
    }
}
struct HistoryDetails: View {
    @ObservedObject var store: RepositoryStore
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let commit = store.selectedCommit {
                HStack { Text(commit.subject).font(.system(size: 17, weight: .semibold)).lineLimit(2); Spacer(); Button { copyText(commit.oid) } label: { Image(systemName: "doc.on.doc") }.help("复制提交哈希") }
                Text("\(commit.oid.prefix(12))  ·  \(commit.author)  ·  \(commit.date.prefix(19))").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                if !commit.body.isEmpty { ScrollView { Text(commit.body).font(.system(size: 12)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 90) }
                HStack {
                    Picker("提交中的文件", selection: Binding(get: { store.selectedHistoryFile?.path ?? "" }, set: { path in if let file = store.historyFiles.first(where: { $0.path == path }) { store.selectHistoryFile(file) } })) { ForEach(store.historyFiles) { Text($0.status + "  " + visiblePath($0.path)).tag($0.path) } }.labelsHidden()
                    Picker("历史差异视图", selection: $store.split) { Text("并排").tag(true); Text("统一").tag(false) }.labelsHidden().frame(width: 72)
                }
                if commit.parents.count > 1 { Text("合并提交：显示与第一个父提交的差异").font(.system(size: 10)).foregroundStyle(.secondary) }
                DocumentPane(document: store.historyDocument, identity: commit.oid + (store.selectedHistoryFile?.path ?? ""), leftLabel: commit.parents.first.map { String($0.prefix(7)) } ?? "空树", rightLabel: String(commit.oid.prefix(7)), split: $store.split)
            } else { Text("选择一条提交查看说明和文件差异").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
        }.padding(16).background(Palette.code)
    }
}
struct StashSidebar: View {
    @ObservedObject var store: RepositoryStore
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("储藏 Stash").font(.system(size: 16, weight: .semibold)); Spacer(); Button { store.sheet = WorkspaceSheet(kind: .stash) } label: { Image(systemName: "plus") }.disabled(store.blockingBusy).allowsHitTesting(!store.busy) }.padding(14)
            ScrollView { LazyVStack(spacing: 5) { if store.stashes.isEmpty { Text("还没有储藏").foregroundStyle(.secondary).padding(20) }; ForEach(store.stashes) { stash in Button { store.selectStash(stash) } label: { VStack(alignment: .leading, spacing: 5) { Text(stash.reference).font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.mint); Text(stash.subject).font(.system(size: 12)).lineLimit(3) }.frame(maxWidth: .infinity, alignment: .leading).padding(12).background(store.selectedStash?.oid == stash.oid ? Palette.blue.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 5)) }.buttonStyle(.plain) } }.padding(.horizontal, 7) }
        }.background(Palette.sidebar)
    }
}
struct StashDetails: View {
    @ObservedObject var store: RepositoryStore
    var body: some View {
        VStack(spacing: 12) {
            if let stash = store.selectedStash {
                HStack { Text(stash.subject).font(.system(size: 15, weight: .semibold)).lineLimit(2); Spacer(); Button("恢复") { store.confirm("恢复此储藏？", message: stash.subject + "\n\n恢复文件与暂存状态，保留储藏记录。", button: "恢复") { store.runOperation("恢复储藏") { try await $0.applyStash(stash) } } }; Button("删除") { store.confirm("删除此储藏记录？", message: stash.reference + "\n" + stash.subject + "\n此操作无法在 Sprig 中撤销。", button: "删除") { store.runOperation("删除储藏") { try await $0.dropStash(stash) } } } }.disabled(store.blockingBusy).allowsHitTesting(!store.busy)
                DocumentPane(document: store.stashDocument, identity: stash.oid, leftLabel: "储藏前", rightLabel: "储藏内容", split: $store.split)
            } else { Text("选择储藏查看差异，或将当前修改存放到 Stash").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
        }.padding(16).background(Palette.code)
    }
}
