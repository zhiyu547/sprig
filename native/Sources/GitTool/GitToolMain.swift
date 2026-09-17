// Copyright (c) 2026 zhiyu
// SPDX-License-Identifier: LicenseRef-Sprig-NC-SA-1.0

import AppKit
import SwiftUI

@main struct GitToolMain {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.setActivationPolicy(.regular); application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let store = RepositoryStore()
    private var window: NSWindow?
    private var aboutWindow: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenus()
        let window = WorkspaceWindow(store: store); window.delegate = self
        window.center(); window.setFrameAutosaveName("GitTool.MainWindow")
        window.isReleasedWhenClosed = false; self.window = window
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        AppUpdater.shared.start(store: store)
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--repository"), args.indices.contains(index + 1) { store.open(URL(fileURLWithPath: args[index + 1], isDirectory: true)) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func windowShouldClose(_ sender: NSWindow) -> Bool { canClose() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { canClose() ? .terminateNow : .terminateCancel }
    private func canClose() -> Bool {
        if store.aiStartedAt != nil { store.cancelAI(); return true }
        guard store.busy else { return true }
        store.error = "请等待当前操作完成后退出。AI 请求可先点击取消。"
        return false
    }
    func applicationWillTerminate(_ notification: Notification) { store.stop() }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        if let path = filenames.first { store.open(URL(fileURLWithPath: path, isDirectory: true)) }
        sender.reply(toOpenOrPrint: .success)
    }
    @objc private func openRepository() { store.chooseRepository() }
    @objc private func checkForUpdates() { AppUpdater.shared.check() }
    @objc private func showLicense() { AppUpdater.showLicense() }
    @objc private func showAbout() {
        if let aboutWindow { aboutWindow.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "关于 Sprig"; window.isReleasedWhenClosed = false
        let content = NSHostingView(rootView: AboutSprigView())
        content.sizingOptions = []
        window.contentView = content; window.center()
        aboutWindow = window; window.makeKeyAndOrderFront(nil)
    }
    @objc private func settings() { guard !store.busy else { return }; store.sheet = WorkspaceSheet(kind: .settings) }
    @objc private func commit() { store.prepareCommit(push: false) }
    @objc private func commitPush() { store.prepareCommit(push: true) }
    @objc private func history() { store.page = .history }
    @objc private func refresh() { store.refresh() }
    @objc private func widenCode() { NotificationCenter.default.post(name: .gitToolAdjustSidebar, object: Double(-24)) }
    @objc private func widenSidebar() { NotificationCenter.default.post(name: .gitToolAdjustSidebar, object: Double(24)) }
    @objc private func resetSidebar() { NotificationCenter.default.post(name: .gitToolAdjustSidebar, object: Double(0)) }
    private func installMenus() {
        let main = NSMenu(), appItem = NSMenuItem(), appMenu = NSMenu()
        let about = appMenu.addItem(withTitle: "关于 Sprig", action: #selector(showAbout), keyEquivalent: ""); about.target = self
        let updates = appMenu.addItem(withTitle: "检查更新…", action: #selector(checkForUpdates), keyEquivalent: ""); updates.target = self
        let license = appMenu.addItem(withTitle: "使用许可…", action: #selector(showLicense), keyEquivalent: ""); license.target = self
        let settings = appMenu.addItem(withTitle: "设置…", action: #selector(settings), keyEquivalent: ","); settings.target = self
        appMenu.addItem(.separator()); appMenu.addItem(withTitle: "退出 Sprig", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu; main.addItem(appItem)
        let file = NSMenuItem(), menu = NSMenu(title: "文件")
        let open = menu.addItem(withTitle: "打开仓库…", action: #selector(openRepository), keyEquivalent: "o"); open.target = self
        let refresh = menu.addItem(withTitle: "刷新", action: #selector(refresh), keyEquivalent: "r"); refresh.target = self
        menu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let commit = menu.addItem(withTitle: "提交…", action: #selector(commit), keyEquivalent: "k"); commit.target = self
        let push = menu.addItem(withTitle: "提交并推送…", action: #selector(commitPush), keyEquivalent: "k"); push.target = self; push.keyEquivalentModifierMask = [.command, .shift]
        let history = menu.addItem(withTitle: "查看历史", action: #selector(history), keyEquivalent: "l"); history.target = self
        file.submenu = menu; main.addItem(file)
        let editItem = NSMenuItem(), edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z"); redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit; main.addItem(editItem)
        let viewItem = NSMenuItem(), view = NSMenu(title: "视图")
        for (title, action, key) in [("扩大代码区域", #selector(widenCode), "["), ("扩大文件列表", #selector(widenSidebar), "]"), ("恢复默认分栏", #selector(resetSidebar), "0")] {
            let item = view.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.target = self; item.keyEquivalentModifierMask = [.command, .option]
        }
        viewItem.submenu = view; main.addItem(viewItem); NSApp.mainMenu = main
    }
}

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(checkForUpdates) { return AppUpdater.shared.available && AppUpdater.shared.canCheck }
        return true
    }
}

final class WorkspaceWindow: NSWindow {
    init(store: RepositoryStore) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        title = "Sprig"; minSize = NSSize(width: 940, height: 680)
        titlebarAppearsTransparent = true; backgroundColor = NSColor(srgbRed: 0.14, green: 0.16, blue: 0.19, alpha: 1)
        appearance = NSAppearance(named: .darkAqua)
        let content = NSHostingView(rootView: WorkspaceView(store: store))
        // Window geometry belongs to the user, not the current diff's intrinsic size.
        content.sizingOptions = []
        contentView = content
    }
}
