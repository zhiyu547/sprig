// Copyright (c) 2026 zhiyu
// SPDX-License-Identifier: LicenseRef-Sprig-NC-SA-1.0

import SwiftUI
import GitCore

struct BranchPopover: View {
    @ObservedObject var store: RepositoryStore
    @State private var query = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("搜索分支和标签", text: $query).textFieldStyle(.roundedBorder)
            HStack {
                Button { store.showBranches = false; store.sheet = WorkspaceSheet(kind: .newBranch(nil)) } label: { Label("新建分支…", systemImage: "plus") }
                Spacer()
                Button { store.loadAuxiliary() } label: { Image(systemName: "arrow.clockwise") }.help("刷新分支")
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    group("本地", kind: .local)
                    group("远程", kind: .remote)
                    group("标签", kind: .tag)
                }
            }
        }.padding(16).frame(width: 400, height: 440).disabled(store.busy)
    }
    private func group(_ title: String, kind: RefKind) -> some View {
        let refs = store.refs.filter { $0.kind == kind && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) }
        return VStack(alignment: .leading, spacing: 6) {
            Text("\(title) · \(refs.count)").font(.caption).foregroundStyle(.secondary)
            ForEach(refs) { ref in
                Button { store.switchTo(ref) } label: {
                    HStack {
                        Image(systemName: ref.current ? "checkmark.circle.fill" : kind == .tag ? "tag" : "arrow.triangle.branch").foregroundStyle(ref.current ? Color.green : Color.secondary)
                        VStack(alignment: .leading, spacing: 2) { Text(ref.name).lineLimit(1); if !ref.upstream.isEmpty { Text(ref.upstream).font(.caption2).foregroundStyle(.secondary) } }
                        Spacer()
                    }.padding(7).frame(maxWidth: .infinity, alignment: .leading).background(ref.current ? Palette.blue.opacity(0.2) : .clear).clipShape(RoundedRectangle(cornerRadius: 6))
                }.buttonStyle(.plain).disabled(ref.current)
                .contextMenu {
                    Button("检出") { store.switchTo(ref) }.disabled(ref.current)
                    Button("基于此处新建分支…") { store.showBranches = false; store.sheet = WorkspaceSheet(kind: .newBranch(ref.oid)) }
                    Button("合并到当前分支…") { store.integrate("merge", revision: ref.oid, label: "合并 \(ref.name)") }.disabled(ref.current)
                    Button("将当前分支变基到此处…") { store.integrate("rebase", revision: ref.oid, label: "变基到 \(ref.name)") }.disabled(ref.current)
                    if kind == .local && !ref.current {
                        Divider()
                        Button("删除已合并分支…") {
                            store.showBranches = false
                            store.confirm("删除 \(ref.name)？", message: "仅删除本地分支。Git 会拒绝删除尚未合并的分支。", button: "删除分支") { store.runOperation("删除分支") { try await $0.deleteBranch(ref); return "已删除 " + ref.name } }
                        }
                    }
                }
            }
            if refs.isEmpty { Text("暂无\(title)记录").font(.caption).foregroundStyle(.tertiary) }
        }
    }
}

struct WorkspaceSheetView: View {
    @ObservedObject var store: RepositoryStore
    let sheet: WorkspaceSheet
    var body: some View {
        Group {
            switch sheet.kind {
            case .settings: SettingsSheet(store: store, settings: store.settings)
            case let .commit(preparation, push): CommitSheet(store: store, preparation: preparation, push: push)
            case let .push(oid): PushSheet(store: store, oid: oid)
            case let .newBranch(start): NameSheet(store: store, start: start, tag: false)
            case let .newTag(oid): NameSheet(store: store, start: oid, tag: true)
            case .stash: StashSheet(store: store)
            case let .aiConfirm(context, intent): AIConfirmSheet(store: store, context: context, intent: intent)
            case let .aiResult(context, text, intent): AIResultSheet(store: store, context: context, intent: intent, text: text)
            case let .report(title, body):
                SheetFrame(store: store, title: title) { ScrollView { Text(body).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(8) }.frame(height: 430) } actions: { Button("关闭") { store.sheet = nil }.keyboardShortcut(.defaultAction) }
            }
        }.preferredColorScheme(.dark)
    }
}

struct SheetFrame<Content: View, Actions: View>: View {
    @ObservedObject var store: RepositoryStore
    let title: String
    var canClose = true
    @ViewBuilder let content: () -> Content
    @ViewBuilder let actions: () -> Actions
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text(title).font(.title3.weight(.semibold)); Spacer(); Button { store.sheet = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).keyboardShortcut(.cancelAction).help("关闭").disabled(!canClose) }
            Divider()
            content()
            Divider()
            HStack { Spacer(); actions() }
        }.padding(24).frame(width: 620)
    }
}

struct SettingsSheet: View {
    @ObservedObject var store: RepositoryStore
    @ObservedObject var settings: AppSettings
    @State private var ai = AIConfiguration()
    @State private var key = ""
    @State private var keyChanged = false
    @State private var whitespace = true
    @State private var todo = true
    @State private var signOff = false
    @State private var author = ""
    @State private var name = ""
    @State private var email = ""
    @State private var feedback = ""
    @State private var savingIdentity = false
    @State private var savingKey = false
    var body: some View {
        SheetFrame(store: store, title: "Sprig 设置", canClose: !savingKey) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("AI 服务").font(.headline)
                    Text("兼容 Chat Completions 的服务，也可连接本机 Ollama。只在点击生成并确认范围后发送暂存差异。").font(.caption).foregroundStyle(.secondary)
                    labeled("API 地址") { TextField("https://服务地址/v1", text: $ai.baseURL).onChange(of: ai.baseURL) { _ in key = ""; keyChanged = false } }
                    labeled("模型名称") { TextField("填写服务商提供的模型 ID", text: $ai.model) }
                    labeled("API Key") { SecureField("留空保留该地址已有密钥", text: $key).onChange(of: key) { _ in keyChanged = true } }
                    Text("密钥存入 macOS 钥匙串。切换地址不会迁移密钥；本机免密服务可以不填。").font(.caption2).foregroundStyle(.secondary)
                    HStack {
                        Picker("输出语言", selection: $ai.language) { Text("中文").tag("中文"); Text("English").tag("English") }.frame(width: 240)
                        Spacer()
                        Button("删除此地址的密钥", action: deleteKey).disabled(ai.baseURL.isEmpty)
                    }
                    Toggle("使用 max_completion_tokens 参数", isOn: $ai.modernTokenLimit).font(.caption)
                    Text("默认使用 max_tokens；仅在服务商要求时切换。").font(.caption2).foregroundStyle(.secondary)
                    Text("AI 排除规则 · 每行一个文件路径片段").font(.caption)
                    TextEditor(text: $ai.exclusions).font(.system(size: 11, design: .monospaced)).frame(height: 72).overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
                    Divider()
                    Text("提交选项").font(.headline)
                    Toggle("空白检查失败时阻止提交", isOn: $whitespace)
                    Toggle("提交检查中列出新增 TODO / FIXME", isOn: $todo)
                    Toggle("添加 Signed-off-by", isOn: $signOff)
                    labeled("覆盖作者") { TextField("可选：Name <email@example.com>", text: $author) }
                    Text("Git hooks 在提交时正常执行。项目格式化、测试、依赖扫描可接入 pre-commit；Sprig 不会替项目配置执行任意命令。").font(.caption).foregroundStyle(.secondary)
                    if store.repository != nil {
                        Divider(); Text("当前仓库身份").font(.headline)
                        labeled("姓名") { TextField("Git user.name", text: $name) }
                        labeled("邮箱") { TextField("Git user.email", text: $email) }
                        Button(savingIdentity ? "保存中…" : "保存到当前仓库") {
                            guard let repo = store.repository else { return }; savingIdentity = true
                            Task { do { try await repo.saveIdentity(name: name, email: email); feedback = "已保存当前仓库身份" } catch { feedback = error.localizedDescription }; savingIdentity = false }
                        }.disabled(savingIdentity || store.busy)
                    }
                }.textFieldStyle(.roundedBorder).padding(.trailing, 8)
            }.frame(height: 460).disabled(savingKey)
            if savingKey { ProgressView("正在访问钥匙串，如有系统提示请完成授权…").controlSize(.small) }
            if !feedback.isEmpty { Text(feedback).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
        } actions: {
            Button("取消") { store.sheet = nil }.disabled(savingKey)
            Button("保存设置") { save() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(savingIdentity || savingKey)
        }.task {
            ai = settings.ai; whitespace = settings.checkWhitespace; todo = settings.checkTODO; signOff = settings.signOff; author = settings.authorOverride
            if let repo = store.repository, let identity = try? await repo.identity() { name = identity.0; email = identity.1 }
        }
    }
    private func labeled<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View { HStack { Text(label).frame(width: 78, alignment: .leading); content() } }
    private func save() {
        guard !savingKey else { return }; savingKey = true
        Task { defer { savingKey = false }; do {
            ai.baseURL = ai.baseURL.trimmingCharacters(in: .whitespacesAndNewlines); ai.model = ai.model.trimmingCharacters(in: .whitespacesAndNewlines)
            if !ai.baseURL.isEmpty { let endpoint = try ai.endpoint(); if keyChanged && !key.isEmpty { try await KeychainStore.save(key, endpoint: endpoint.absoluteString) } }
            settings.ai = ai; settings.checkWhitespace = whitespace; settings.checkTODO = todo; settings.signOff = signOff; settings.authorOverride = author; settings.save(); store.sheet = nil; store.notice = "设置已保存"
        } catch { feedback = error.localizedDescription } }
    }
    private func deleteKey() {
        guard !savingKey else { return }; savingKey = true
        Task { defer { savingKey = false }; do {
            try await KeychainStore.save("", endpoint: ai.endpoint().absoluteString)
            key = ""; keyChanged = false; feedback = "已移除此地址的密钥"
        } catch { feedback = error.localizedDescription } }
    }
}

struct CommitSheet: View {
    @ObservedObject var store: RepositoryStore
    let preparation: CommitPreparation
    let push: Bool
    var body: some View {
        SheetFrame(store: store, title: store.amend ? "确认修正上次提交" : "确认提交范围") {
            Text("\(store.branchTitle) · \(preparation.files.count) 个暂存文件").font(.headline)
            if store.amend { Text("将替换提交 \(preparation.stamp.head.prefix(8))。若此前已推送，普通推送可能被拒绝。").font(.caption).foregroundStyle(.orange) }
            ScrollView { VStack(alignment: .leading, spacing: 6) { ForEach(preparation.files) { file in HStack { Text(file.path); Spacer(); if file.hasWorking { Text("仅已暂存部分").foregroundStyle(.orange) } } } }.font(.system(size: 12, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 130)
            if let source = store.aiSource, source != preparation.stamp { Text("AI 草稿生成后暂存范围已变化，请核对说明是否仍准确。必要时返回重新生成。").font(.caption).foregroundStyle(.orange) }
            Text("提交说明").font(.caption).foregroundStyle(.secondary)
            ScrollView { Text(store.commitMessage).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 170)
            if !preparation.checkOutput.isEmpty { Text(store.settings.checkWhitespace ? "空白检查发现问题：请返回修复，或在设置中关闭阻止提交。" : "空白检查发现问题，将按设置继续提交。").font(.caption).foregroundStyle(.orange) }
            Text("工作区未暂存的修改会保留。Git hooks 将照常运行。" + (push ? "提交成功后，继续确认远端与目标分支。" : "")).font(.caption).foregroundStyle(.secondary)
        } actions: {
            Button("返回编辑") { store.sheet = nil }
            Button(store.amend ? "确认修正" : "确认提交") { store.performCommit(preparation, push: push) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(store.busy || (store.settings.checkWhitespace && !preparation.checkOutput.isEmpty))
        }
    }
}

struct PushSheet: View {
    @ObservedObject var store: RepositoryStore
    let oid: String
    @State private var remotes: [String] = []
    @State private var remote = ""
    @State private var branch = ""
    @State private var feedback = ""
    @State private var loading = true
    @State private var autoSync = true
    @State private var strategy: PushStrategy = .merge
    var body: some View {
        SheetFrame(store: store, title: "确认推送") {
            Text("提交 \(oid.prefix(10)) → 远程分支").font(.headline).textSelection(.enabled)
            Picker("远程仓库", selection: $remote) { ForEach(remotes, id: \.self) { Text($0).tag($0) } }
            TextField("目标分支，例如 main", text: $branch).textFieldStyle(.roundedBorder)
            Toggle("推送前自动同步远端更新", isOn: $autoSync)
            if autoSync {
                Picker("同步方式", selection: $strategy) { ForEach(PushStrategy.allCases, id: \.self) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                Text(strategy == .merge ? "保留本地提交，分叉时生成合并提交；仅落后时直接快进。" : "将本地未推送的提交重放到远端最新提交之后，提交 ID 会改变。").font(.caption).foregroundStyle(.secondary)
                Text("未提交修改会自动储藏并恢复；冲突时暂停处理。此仓库会记住你的选择。").font(.caption).foregroundStyle(.secondary)
            } else { Text("执行普通推送。远端有更新时停止并提示，不会强制覆盖。").font(.caption).foregroundStyle(.secondary) }
            if loading { ProgressView().controlSize(.small) }
            if !feedback.isEmpty { Text(feedback).foregroundStyle(.orange).font(.caption) }
        } actions: {
            Button("稍后推送") { store.sheet = nil }
            Button(autoSync ? "同步并推送" : "推送") { store.performPush(oid: oid, destination: PushDestination(remote: remote, branch: branch), autoSync: autoSync, strategy: strategy) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(loading || remote.isEmpty || branch.isEmpty || store.busy)
        }.task {
            guard let repo = store.repository else { loading = false; return }
            autoSync = store.autoSyncPreference; strategy = store.pushStrategyPreference
            do { remotes = try await repo.remotes(); let suggestion = try await repo.pushSuggestion(); remote = suggestion.remote; branch = suggestion.branch == "(detached)" ? "" : suggestion.branch; if remotes.isEmpty { feedback = "当前仓库没有远端。请先通过 Git 配置 remote，再重新打开推送。" } }
            catch { feedback = error.localizedDescription }; loading = false
        }
    }
}

struct NameSheet: View {
    @ObservedObject var store: RepositoryStore
    let start: String?
    let tag: Bool
    @State private var name = ""
    var body: some View {
        SheetFrame(store: store, title: tag ? "新建标签" : "新建并切换分支") {
            TextField(tag ? "标签名称" : "分支名称", text: $name).textFieldStyle(.roundedBorder)
            Text("起点：" + (start.map { String($0.prefix(10)) } ?? store.branchTitle)).font(.caption).foregroundStyle(.secondary)
        } actions: {
            Button("取消") { store.sheet = nil }
            Button("创建") {
                store.sheet = nil
                if tag, let start { store.runOperation("新建标签") { try await $0.createTag(name, revision: start); return "已创建标签 " + name } }
                else { store.runOperation("新建分支") { try await $0.createBranch(name, start: start); return "已创建并切换到 " + name } }
            }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(name.isEmpty || store.busy)
        }
    }
}
struct StashSheet: View {
    @ObservedObject var store: RepositoryStore
    @State private var message = ""
    @State private var untracked = false
    var body: some View {
        SheetFrame(store: store, title: "储藏当前修改") {
            TextField("储藏说明（可选）", text: $message).textFieldStyle(.roundedBorder)
            Toggle("包含未进行版本管理的文件", isOn: $untracked)
            Text("使用 Git Stash 保存修改并清理工作区。恢复时保留原有暂存状态；储藏记录仍会保留。").font(.caption).foregroundStyle(.secondary)
        } actions: {
            Button("取消") { store.sheet = nil }
            Button("储藏") { store.sheet = nil; store.runOperation("储藏修改") { try await $0.stashSave(message, includeUntracked: untracked) } }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(store.busy)
        }
    }
}
struct AIConfirmSheet: View {
    @ObservedObject var store: RepositoryStore
    let context: AIContext
    let intent: AIIntent
    var body: some View {
        SheetFrame(store: store, title: !context.canGenerate ? "暂无可发送的暂存内容" : intent == .commit ? "生成提交说明" : "AI 检查暂存代码") {
            Text(context.coverage).font(.headline)
            Text("服务：\((try? store.settings.ai.endpoint().absoluteString) ?? store.settings.ai.baseURL)\n模型：\(store.settings.ai.model)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if !context.included.isEmpty { Text("发送文件").font(.caption.bold()); Text(context.included.joined(separator: "\n")).font(.caption) }
                    if !context.redacted.isEmpty { Text("已在本机脱敏\n" + context.redacted.joined(separator: "\n")).font(.caption).foregroundStyle(Palette.mint) }
                    if !context.excluded.isEmpty { Text("已排除\n" + context.excluded.joined(separator: "\n")).font(.caption).foregroundStyle(.orange) }
                    Divider()
                    Text(context.patch).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 300)
            Text(context.canGenerate ? "仅发送上方预览内容。匹配到的敏感值已遮盖；排除文件不在分析范围内。" : "所选文件均已排除，尚未调用 AI。请根据上方原因调整排除规则或选择其他暂存文件。").font(.caption).foregroundStyle(.secondary)
        } actions: {
            Button("返回") { store.sheet = nil }
            if !context.excluded.isEmpty { Button("AI 排除设置…") { store.sheet = WorkspaceSheet(kind: .settings) } }
            Button("确认并" + (intent == .commit ? "生成" : "检查")) { store.generateAI(context, intent: intent) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!context.canGenerate)
        }
    }
}
struct AIResultSheet: View {
    @ObservedObject var store: RepositoryStore
    let context: AIContext
    let intent: AIIntent
    @State var text: String
    var body: some View {
        SheetFrame(store: store, title: intent == .commit ? "检查 AI 生成的提交说明" : "AI 检查结果") {
            Text(context.coverage).font(.caption).foregroundStyle(.secondary)
            if !context.redacted.isEmpty { Text("已基于脱敏后的差异生成，未分析敏感值本身。").font(.caption).foregroundStyle(Palette.mint) }
            if !context.excluded.isEmpty { Text("不包含：" + context.excluded.joined(separator: "、")).font(.caption).foregroundStyle(.orange).lineLimit(3) }
            TextEditor(text: $text).font(.system(size: 13, design: .monospaced)).frame(height: 370).overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            Text("请核对事实与覆盖范围。AI 输出不代表已执行编译或测试。").font(.caption).foregroundStyle(.secondary)
        } actions: {
            Button("复制") { copyText(text) }
            Button("关闭") { store.sheet = nil }
            if intent == .commit { Button("使用此说明") { store.useAIDraft(text, context: context) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }
    }
}
