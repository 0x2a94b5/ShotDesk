import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var config = AppConfig.standard
    private var statusItem: NSStatusItem!
    private var flashWorkItem: DispatchWorkItem?
    /// Targets whose shortcuts conflict with system shortcuts and must be shown in the menu.
    private var hotKeyConflicts: [String] = []

    private let idleSymbol = "camera.viewfinder"

    func applicationDidFinishLaunching(_ notification: Notification) {
        config = ConfigStore.load()
        ConfigStore.save(config) // Create a hand-editable configuration on first launch.

        // The permission state does not refresh during a process lifetime; log it at launch.
        NSLog("ShotDesk: 启动，屏幕录制权限 = %@",
              CGPreflightScreenCaptureAccess() ? "已授权" : "未授权")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setSymbol(idleSymbol)
        rebuildMenu()
        registerHotKeys()
    }

    // MARK: - Menu

    private func rebuildMenu() {
        let menu = NSMenu()

        if !hotKeyConflicts.isEmpty {
            let warn = NSMenuItem(title: "⚠︎ 热键和系统快捷键冲突（点此查看）",
                                  action: #selector(explainConflictAction), keyEquivalent: "")
            warn.target = self
            menu.addItem(warn)
            menu.addItem(.separator())
        }

        // Manual region selection is the primary path, so keep it at the top.
        let region = NSMenuItem(title: "框选截图", action: #selector(regionCaptureAction),
                                keyEquivalent: "")
        region.target = self
        if let hk = config.regionHotKey {
            region.keyEquivalent = hk.keyEquivalent
            region.keyEquivalentModifierMask = hk.cocoaFlags
        }
        menu.addItem(region)
        menu.addItem(.separator())

        for target in config.targets {
            let item = NSMenuItem(title: target.label,
                                  action: #selector(captureAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = target.id
            if let hk = target.hotKey {
                item.keyEquivalent = hk.keyEquivalent
                item.keyEquivalentModifierMask = hk.cocoaFlags
            }
            menu.addItem(item)
        }

        menu.addItem(.separator())

        for target in config.targets where !target.isFrontmost {
            let has = target.insets?.isZero == false
            let title = "框选 \(target.appLabel) 的内容区域…" + (has ? "  ✓" : "")
            let item = NSMenuItem(title: title, action: #selector(selectRegionAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = target.id
            menu.addItem(item)
        }

        let clear = NSMenuItem(title: "清除全部内容区域设置",
                               action: #selector(clearRegionsAction), keyEquivalent: "")
        clear.target = self
        clear.isEnabled = config.targets.contains { $0.insets?.isZero == false }
        menu.addItem(clear)

        menu.addItem(.separator())

        let save = NSMenuItem(title: "同时存盘到 \(shortPath(config.saveDirectory))",
                              action: #selector(toggleSaveAction), keyEquivalent: "")
        save.target = self
        save.state = config.saveToDisk ? .on : .off
        menu.addItem(save)

        let sound = NSMenuItem(title: "抓取时播放快门音",
                               action: #selector(toggleSoundAction), keyEquivalent: "")
        sound.target = self
        sound.state = config.playSound ? .on : .off
        menu.addItem(sound)

        let login = NSMenuItem(title: "开机自动启动",
                               action: #selector(toggleLoginAction), keyEquivalent: "")
        login.target = self
        login.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())

        let reload = NSMenuItem(title: "重新加载配置", action: #selector(reloadAction), keyEquivalent: "")
        reload.target = self
        menu.addItem(reload)

        let reveal = NSMenuItem(title: "在 Finder 中显示配置", action: #selector(revealAction), keyEquivalent: "")
        reveal.target = self
        menu.addItem(reveal)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 ShotDesk", action: #selector(quitAction), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private func shortPath(_ path: String) -> String {
        path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    // MARK: - Hot keys

    private func registerHotKeys() {
        HotKeyCenter.shared.unregisterAll()
        hotKeyConflicts = []

        if let spec = config.regionHotKey {
            HotKeyCenter.shared.register(spec) { [weak self] in
                self?.beginRegionCapture()
            }
        }

        for target in config.targets {
            guard let spec = target.hotKey else { continue }
            let id = target.id
            HotKeyCenter.shared.register(spec) { [weak self] in
                self?.capture(targetID: id)
            }
        }

        // Successful registration does not make a combination usable: system
        // shortcuts receive the event first. Detect and report conflicts explicitly.
        var checkTargets = config.targets
        if let spec = config.regionHotKey {
            checkTargets.append(CaptureTarget(id: "region", label: "框选截图", hotKey: spec))
        }
        hotKeyConflicts = SystemHotKeys.conflicts(in: checkTargets).map {
            "\($0.spec.displayString)（\($0.target.label)）"
        }
    }

    @objc private func explainConflictAction() {
        showAlert("""
        以下热键和 macOS 系统快捷键撞车，按下去会被系统先拦走，ShotDesk 收不到：

        \(hotKeyConflicts.joined(separator: "\n"))

        这些目标仍然可以从本菜单点击抓取。要换热键，\
        编辑 ~/Library/Application Support/ShotDesk/config.json 里的 hotKey，\
        再点「重新加载配置」。
        """)
    }

    // MARK: - Actions

    @objc private func regionCaptureAction() {
        beginRegionCapture()
    }

    private func beginRegionCapture() {
        guard !RegionSelector.shared.isActive else { return }
        guard ScreenCapturer.hasPermission() else {
            showAlert(CaptureError.noPermission.message, offerRestart: true)
            return
        }
        RegionSelector.shared.beginFreeCapture { [weak self] image in
            guard let self = self else { return }
            guard let image = image else { return }   // Esc cancels quietly.
            Clipboard.put(image)
            if self.config.saveToDisk {
                Clipboard.saveToDisk(image, targetID: "region",
                                     directory: self.config.saveDirectory)
            }
            if self.config.playSound { Feedback.playShutter() }
            self.flash(success: true, note: nil,
                       size: CGSize(width: image.width, height: image.height))
        }
    }

    @objc private func captureAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        capture(targetID: id)
    }

    private func capture(targetID: String) {
        guard let target = config.targets.first(where: { $0.id == targetID }) else { return }
        ScreenCapturer.capture(target: target) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let outcome):
                Clipboard.put(outcome.image)
                if self.config.saveToDisk {
                    Clipboard.saveToDisk(outcome.image, targetID: target.id,
                                         directory: self.config.saveDirectory)
                }
                if self.config.playSound { Feedback.playShutter() }
                self.flash(success: outcome.note == nil, note: outcome.note,
                           size: CGSize(width: outcome.image.width, height: outcome.image.height))
            case .failure(let error):
                self.showAlert(error.message, offerRestart: error.offersRestart)
            }
        }
    }

    @objc private func selectRegionAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let index = config.targets.firstIndex(where: { $0.id == id }) else { return }
        let target = config.targets[index]

        guard ScreenCapturer.hasPermission() else {
            showAlert(CaptureError.noPermission.message, offerRestart: true)
            return
        }
        guard let match = WindowFinder.find(target) else {
            showAlert(CaptureError.windowNotFound(target.label).message)
            return
        }

        // Bring the target window forward so the user can select it accurately.
        NSRunningApplication(processIdentifier: match.ownerPID)?
            .activate(options: [.activateIgnoringOtherApps])

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            let bounds = WindowFinder.find(target)?.bounds ?? match.bounds
            RegionSelector.shared.begin(over: bounds) { insets in
                guard let self = self, let insets = insets else { return }
                self.config.targets[index].insets = insets
                ConfigStore.save(self.config)
                self.rebuildMenu()
                self.flash(success: true, note: nil)
            }
        }
    }

    @objc private func clearRegionsAction() {
        for i in config.targets.indices { config.targets[i].insets = nil }
        ConfigStore.save(config)
        rebuildMenu()
    }

    @objc private func toggleSaveAction() {
        config.saveToDisk.toggle()
        ConfigStore.save(config)
        rebuildMenu()
    }

    @objc private func toggleSoundAction() {
        config.playSound.toggle()
        ConfigStore.save(config)
        rebuildMenu()
        if config.playSound { Feedback.playShutter() }
    }

    @objc private func toggleLoginAction() {
        LoginItem.setEnabled(!LoginItem.isEnabled)
        rebuildMenu()
    }

    @objc private func reloadAction() {
        config = ConfigStore.load()
        rebuildMenu()
        registerHotKeys()
        flash(success: true, note: nil)
    }

    @objc private func revealAction() {
        ConfigStore.save(config)
        NSWorkspace.shared.activateFileViewerSelecting([ConfigStore.fileURL])
    }

    @objc private func quitAction() {
        HotKeyCenter.shared.unregisterAll()
        NSApp.terminate(nil)
    }

    // MARK: - Feedback

    /// Avoid Notification Center because it adds a permission prompt and a
    /// persistent connection. Use shutter sound, icon changes, and menu-bar text instead.
    private func flash(success: Bool, note: String?, size: CGSize? = nil) {
        if let size = size {
            statusItem.button?.toolTip =
                note ?? "已复制到剪贴板 \(Int(size.width))×\(Int(size.height))"
        } else {
            statusItem.button?.toolTip = note
        }
        setSymbol(success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
        statusItem.button?.title = success ? " 已复制" : " 有警告"

        flashWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.setSymbol(self.idleSymbol)
            self.statusItem.button?.title = ""
        }
        flashWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (note == nil ? 1.2 : 2.2), execute: work)
    }

    private func setSymbol(_ name: String) {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "ShotDesk")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    private func showAlert(_ message: String, offerRestart: Bool = false) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "ShotDesk"
        alert.informativeText = message
        alert.alertStyle = .warning
        if offerRestart { alert.addButton(withTitle: "重新启动 ShotDesk") }
        alert.addButton(withTitle: "好")

        let response = alert.runModal()
        if offerRestart, response == .alertFirstButtonReturn { relaunch() }
    }

    /// Restart after granting permission so the new state takes effect immediately.
    private func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; open -n \"\(path)\""]
        try? task.run()
        HotKeyCenter.shared.unregisterAll()
        NSApp.terminate(nil)
    }
}
