// Copyright (c) 2026 zhiyu
// SPDX-License-Identifier: LicenseRef-Sprig-NC-SA-1.0

import AppKit
import SwiftUI
import CoreServices
import GitCore

final class RepositoryWatcher {
    private var stream: FSEventStreamRef?
    private let changed: () -> Void
    init(paths: [String], changed: @escaping () -> Void) {
        self.changed = changed
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagUseCFTypes)
        stream = FSEventStreamCreate(nil, { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<RepositoryWatcher>.fromOpaque(info).takeUnretainedValue().changed()
        }, &context, Array(Set(paths)) as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.25, flags)
        if let stream { FSEventStreamSetDispatchQueue(stream, .main); if !FSEventStreamStart(stream) { stop() } }
    }
    var isRunning: Bool { stream != nil }
    func stop() {
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
        stream = nil
    }
    deinit { stop() }
}

struct DiffPreview {
    let file: ChangedFile
    let scope: DiffScope
    let document: DiffDocument
}

@MainActor final class RepositoryStore: ObservableObject {
    let settings = AppSettings()
    @Published var page: WorkspacePage = .changes
    @Published var busy = false
    @Published var indexUpdatePaths: Set<String> = []
    var updatingIndex: Bool { !indexUpdatePaths.isEmpty }
    var blockingBusy: Bool { busy && !updatingIndex }
    @Published var busyTitle = ""
    @Published var notice: String?
    @Published var sheet: WorkspaceSheet?
    @Published var showBranches = false
    @Published var refs: [GitRef] = []
    @Published var trackedExpanded = true
    @Published var untrackedExpanded = false
    @Published var showDiff = true
    @Published var amend = false
    @Published var commitMessage = "" { didSet { saveDraft() } }
    @Published var messageHistory = UserDefaults.standard.stringArray(forKey: "Sprig.messageHistory") ?? []
    @Published var history: [GitCommit] = []
    @Published var historyQuery = ""
    @Published var historyAuthor = ""
    @Published var historyAll = true
    @Published var historyMore = false
    @Published var historyLoading = false
    @Published var selectedCommit: GitCommit?
    @Published var historyFiles: [CommitFile] = []
    @Published var selectedHistoryFile: CommitFile?
    @Published var historyDocument: DiffDocument?
    @Published var stashes: [GitStash] = []
    @Published var selectedStash: GitStash?
    @Published var stashDocument: DiffDocument?
    @Published var console: [OperationLog] = []
    @Published var pendingPushOID: String?
    @Published var pendingPushTarget: PushDestination?
    @Published var synchronizedPushSession: PushSession?
    @Published var aiSource: IndexStamp?
    @Published var aiStartedAt: Date?
    var aiRequestID = UUID()
    @Published var preview: DiffPreview?
    var document: DiffDocument? { preview?.document }
    var documentIdentity: String { preview?.file.path ?? "" }
    var previewFile: ChangedFile? { preview?.file ?? selected }
    var previewScope: DiffScope { preview?.scope ?? scope }
    // Injectable so regression checks can hold the read in flight.
    var readDiff: @Sendable (GitRepository, ChangedFile, DiffScope) async throws -> DiffDocument = { try await $0.diff(for: $1, scope: $2) }
    var operationTask: Task<Void, Never>?
    var auxiliaryToken = UUID()
    var historyToken = UUID()
    var detailToken = UUID()
    var needsRefresh = false
    @Published var snapshot: RepositorySnapshot?
    @Published var selectedPath: String?
    @Published var scope: DiffScope = .working
    @Published var query = ""
    @Published var filter = "all"
    @Published var split = true
    @Published var opening = false
    @Published var refreshing = false
    @Published var loadingDiff = false
    @Published var error: String?
    @Published var diffError: String?
    @Published var watching = false
    @Published var updatedAt: Date?
    @Published var refreshMilliseconds = 0
    @Published var recent = UserDefaults.standard.stringArray(forKey: "recentRepositories") ?? []
    var repository: GitRepository?
    private var watcher: RepositoryWatcher?
    private var openTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var diffTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    var repositoryToken = UUID()
    private var diffToken = UUID()

    var selected: ChangedFile? { snapshot?.files.first { $0.path == selectedPath } }
    var files: [ChangedFile] {
        (snapshot?.files ?? []).filter { (query.isEmpty || $0.path.localizedCaseInsensitiveContains(query)) && (filter == "all" || (filter == "staged" ? $0.hasStaged : $0.hasWorking)) }
    }
    var branchTitle: String {
        guard let snapshot else { return "尚未打开仓库" }
        return snapshot.branch == "(detached)" ? "分离 HEAD · \(snapshot.head.prefix(7))" : snapshot.branch
    }

    func chooseRepository() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.title = "打开 Git 仓库"; panel.prompt = "打开仓库"
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in self?.open(url) }
        }
    }

    func open(_ url: URL) {
        guard !busy else { return }
        openTask?.cancel(); refreshTask?.cancel(); diffTask?.cancel(); debounceTask?.cancel(); watcher?.stop()
        repositoryToken = UUID(); let token = repositoryToken
        auxiliaryToken = UUID(); historyToken = UUID(); detailToken = UUID()
        history = []; historyFiles = []; historyDocument = nil; selectedCommit = nil; stashes = []; stashDocument = nil; selectedStash = nil; selectedHistoryFile = nil; refs = []; historyLoading = false; showBranches = false
        pendingPushOID = nil; pendingPushTarget = nil; synchronizedPushSession = nil; aiSource = nil; amend = false; page = .changes; notice = nil; sheet = nil
        opening = true; refreshing = false; loadingDiff = false; watching = false
        error = nil; diffError = nil; snapshot = nil; preview = nil; repository = nil; selectedPath = nil; updatedAt = nil; query = ""; filter = "all"
        openTask = Task { [self] in
            do {
                let start = Date()
                let repo = try await GitRepository.open(url)
                let state = try await repo.snapshot()
                guard !Task.isCancelled, token == repositoryToken else { return }
                repository = repo; snapshot = state; commitMessage = UserDefaults.standard.string(forKey: draftKey(repo.root.path)) ?? ""; opening = false; updatedAt = Date(); refreshMilliseconds = Int(Date().timeIntervalSince(start) * 1000)
                reloadPushSession()
                recent.removeAll { $0 == repo.root.path }; recent.insert(repo.root.path, at: 0); recent = Array(recent.prefix(8))
                UserDefaults.standard.set(recent, forKey: "recentRepositories")
                if let first = state.files.first { select(first) }; loadAuxiliary()
                watcher = RepositoryWatcher(paths: [repo.root.path, repo.gitDirectory.path, repo.commonDirectory.path]) { [weak self] in
                    Task { @MainActor in self?.scheduleRefresh() }
                }
                watching = watcher?.isRunning == true
                if !watching { error = "文件监听未能启动。可使用右上角刷新按钮更新。" }
                (NSApp.mainWindow ?? NSApp.windows.first(where: { $0.canBecomeMain && !$0.isSheet }))?.title = "\(repo.root.lastPathComponent) — Sprig"
            } catch {
                guard !Task.isCancelled, token == repositoryToken else { return }
                self.error = error.localizedDescription; opening = false
            }
        }
    }

    func scheduleRefresh() {
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            refresh()
        }
    }

    func refresh() {
        guard let repository, !opening else { return }
        if busy { needsRefresh = true; return }
        // Serialize refreshes while retaining an event that arrived during a scan.
        if refreshing { scheduleRefresh(); return }
        refreshing = true; let token = repositoryToken
        refreshTask = Task {
            do {
                let start = Date(), state = try await repository.snapshot()
                guard !Task.isCancelled, token == repositoryToken else { return }
                refreshing = false; updatedAt = Date(); refreshMilliseconds = Int(Date().timeIntervalSince(start) * 1000)
                if error?.hasPrefix("刷新失败") == true { error = nil }
                loadAuxiliary()
                applySnapshot(state)
            } catch {
                guard !Task.isCancelled, token == repositoryToken else { return }
                refreshing = false; self.error = "刷新失败，当前仍为上次读取结果。\n" + error.localizedDescription
            }
        }
    }

    func suspendRefreshForIndexWrite() {
        refreshTask?.cancel(); debounceTask?.cancel(); refreshing = false
    }
    func refreshAfterIndexWrite(_ repository: GitRepository) async throws {
        let start = Date(), state = try await repository.snapshot()
        try Task.checkCancellation()
        updatedAt = Date(); refreshMilliseconds = Int(Date().timeIntervalSince(start) * 1000)
        applySnapshot(state)
    }
    private func applySnapshot(_ state: RepositorySnapshot) {
        snapshot = state
        if let file = selected {
            if scope == .staged && !file.hasStaged { scope = .working }
            else if scope == .working && !file.hasWorking { scope = .staged }
            loadDiff()
        } else if let first = state.files.first { select(first) }
        else { selectedPath = nil; preview = nil; diffError = nil; loadingDiff = false; diffTask?.cancel() }
    }
    func select(_ file: ChangedFile) {
        selectedPath = file.path; scope = file.hasStaged ? .staged : .working; loadDiff()
    }
    func changeScope(_ value: DiffScope) { scope = value; loadDiff() }
    func loadDiff() {
        diffTask?.cancel(); diffToken = UUID(); let token = diffToken
        guard let repository, let file = selected else { preview = nil; loadingDiff = false; return }
        let chosenScope = scope
        loadingDiff = true; diffError = nil
        diffTask = Task {
            do {
                let result = try await readDiff(repository, file, chosenScope)
                guard !Task.isCancelled, token == diffToken else { return }
                // The file name, scope labels and diff become visible together.
                preview = DiffPreview(file: file, scope: chosenScope, document: result); loadingDiff = false
            } catch {
                guard !Task.isCancelled, token == diffToken else { return }
                diffError = error.localizedDescription; loadingDiff = false
            }
        }
    }
    func cancelRead() {
        if opening { openTask?.cancel(); opening = false }
        refreshTask?.cancel(); refreshing = false
        if loadingDiff { diffTask?.cancel(); loadingDiff = false; diffError = "读取已取消，可点击重试。" }
    }
    func revealFile() {
        guard let snapshot, let selected else { return }
        NSWorkspace.shared.activateFileViewerSelecting([snapshot.root.appendingPathComponent(selected.path)])
    }
    func stop() { operationTask?.cancel(); openTask?.cancel(); refreshTask?.cancel(); diffTask?.cancel(); debounceTask?.cancel(); watcher?.stop() }
}
