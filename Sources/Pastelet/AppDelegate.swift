import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let clipboardMonitor = ClipboardMonitor()
    private lazy var panelController = ClipboardPanelController(
        monitor: clipboardMonitor,
        onShowSettings: { [weak self] in
            self?.showSettings()
        }
    )
    private var settingsController: SettingsWindowController?
    private var hotKeyManager: HotKeyManager?
    private var statusItem: NSStatusItem?
    private var settingsCancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        installEditMenu()

        hotKeyManager = HotKeyManager {
            self.panelController.toggle()
        }
        configureHotKey(showAlertOnFailure: true)

        bindSettings()
        applyStatusItemVisibility()
        clipboardMonitor.start()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.panelController.prepare()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 退出前强制落盘并等待写盘完成，避免丢失未保存的历史
        clipboardMonitor.flushAndWait()
    }

    private func bindSettings() {
        AppSettings.shared.$hideMenuBarIcon
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.applyStatusItemVisibility()
                }
            }
            .store(in: &settingsCancellables)

        AppSettings.shared.$launchShortcut
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.configureHotKey(showAlertOnFailure: true)
                }
            }
            .store(in: &settingsCancellables)
    }

    private func configureHotKey(showAlertOnFailure: Bool) {
        let shortcut = AppSettings.shared.launchShortcut
        let registered = hotKeyManager?.updateShortcut(shortcut) ?? false
        if showAlertOnFailure, shortcut != nil, !registered {
            showHotKeyFailureAlert(shortcut: shortcut)
        }
    }

    private func applyStatusItemVisibility() {
        if AppSettings.shared.hideMenuBarIcon {
            removeStatusItem()
        } else {
            configureStatusItem()
        }
    }

    private func configureStatusItem() {
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Pastelet")
        item.button?.imagePosition = .imageOnly

        let menu = NSMenu()
        menu.addItem(menuItem("显示剪贴板", action: #selector(showClipboardPanel), key: ""))
        menu.addItem(menuItem("偏好设置...", action: #selector(showSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(menuItem("隐藏菜单栏图标", action: #selector(hideMenuBarIcon), key: ""))
        menu.addItem(.separator())
        menu.addItem(menuItem("清空历史", action: #selector(clearHistory), key: ""))
        menu.addItem(.separator())
        menu.addItem(menuItem("退出 Pastelet", action: #selector(quit), key: "q"))
        item.menu = menu

        statusItem = item
    }

    private func removeStatusItem() {
        guard let statusItem else { return }
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
    }

    private func menuItem(_ title: String, action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    /// 安装一张仅含标准「编辑」菜单的应用主菜单。
    ///
    /// Pastelet 是 accessory（LSUIElement）后台 App，从不设置 NSApp.mainMenu，
    /// 因此系统里没有「编辑」菜单。而文本框里的 ⌘A/⌘X/⌘C/⌘V/⌘Z 并不是 field editor
    /// 在 keyDown 里自己处理的，它们是「编辑」菜单项的快捷键，经 performKeyEquivalent:
    /// 沿响应链派发成 selectAll:/cut:/copy:/paste:/undo: 等动作。没有这张菜单，
    /// 弹窗搜索框里这些快捷键就全部失效（只哔一声）。
    /// 菜单的快捷键即便菜单栏不显示也照样生效，所以这里只为「让快捷键能路由」而装。
    private func installEditMenu() {
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(editActionItem("撤销", "undo:", "z"))
        editMenu.addItem(editActionItem("重做", "redo:", "z", modifiers: [.command, .shift]))
        editMenu.addItem(.separator())
        editMenu.addItem(editActionItem("剪切", "cut:", "x"))
        editMenu.addItem(editActionItem("拷贝", "copy:", "c"))
        editMenu.addItem(editActionItem("粘贴", "paste:", "v"))
        editMenu.addItem(editActionItem("全选", "selectAll:", "a"))

        let editItem = NSMenuItem()
        editItem.submenu = editMenu

        let mainMenu = NSMenu()
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }

    /// 构造一个 target=nil 的菜单项：nil 让动作沿响应链派发给当前第一响应者（field editor）。
    private func editActionItem(
        _ title: String,
        _ selector: String,
        _ key: String,
        modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: Selector((selector)), keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    @objc private func showClipboardPanel() {
        panelController.show()
    }

    @objc private func showSettings() {
        if settingsController == nil {
            settingsController = SettingsWindowController(monitor: clipboardMonitor)
        }
        settingsController?.show()
    }

    @objc private func clearHistory() {
        clipboardMonitor.clear()
    }

    @objc private func hideMenuBarIcon() {
        AppSettings.shared.hideMenuBarIcon = true
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func showHotKeyFailureAlert(shortcut: PasteletKeyboardShortcut?) {
        let alert = NSAlert()
        alert.messageText = "快捷键注册失败"
        let shortcutText = shortcut?.displayString ?? "当前快捷键"
        alert.informativeText = "\(shortcutText) 可能已被其他应用占用。你仍然可以从菜单栏打开 Pastelet，或在设置中换一个快捷键。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "知道了")
        alert.runModal()
    }
}
