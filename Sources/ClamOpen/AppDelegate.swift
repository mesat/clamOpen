import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {

    private let controller = DisplayController()
    private let powerManager = PowerManager()
    private var statusItem: NSStatusItem!

    /// 当前“意图”：用户或自动逻辑希望内置屏保持关闭
    private var intentDisabled = false

    /// 自动模式：检测到外接显示器自动关闭内置，拔掉自动恢复
    private var autoMode = false {
        didSet { UserDefaults.standard.set(autoMode, forKey: "autoMode") }
    }

    private var watchdog: Timer?

    /// 自动模式只在外接显示器插拔时动作，手动“恢复内置屏”后不会被立刻再次关闭
    private var lastHasExternal: Bool?
    /// 刚接上外接、尚未成功关闭内置屏（关闭失败时由 watchdog 重试）
    private var autoDisablePending = false

    /// CoreGraphics 显示重配置回调（拔插显示器时即时触发，比 NSNotification 更底层、更早）。
    /// 闭包不捕获 self，AppDelegate 通过 userInfo 指针传入。
    private let reconfigCallback: CGDisplayReconfigurationCallBack = { _, flags, userInfo in
        guard let userInfo else { return }
        if flags.contains(.beginConfigurationFlag) { return }   // 配置开始阶段状态未稳定，跳过
        let delegate = Unmanaged<AppDelegate>.fromOpaque(userInfo).takeUnretainedValue()
        DispatchQueue.main.async { delegate.enforceSafety() }
    }

    // MARK: - 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // 仅菜单栏，无 Dock 图标
        autoMode = UserDefaults.standard.bool(forKey: "autoMode")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        // 底层显示重配置回调：拔外接的瞬间即时恢复内置屏（与上面的通知互为双保险）
        CGDisplayRegisterReconfigurationCallback(
            reconfigCallback, Unmanaged.passUnretained(self).toOpaque())

        startWatchdog()
        rebuildMenu()
        updateIcon()

        if !controller.isAPIAvailable {
            notify(tr("Not supported on this system", "当前系统不支持"),
                   tr("Unable to call the private CGSConfigureDisplayEnabled API.",
                      "无法调用 CGSConfigureDisplayEnabled 私有接口。"))
        } else if autoMode {
            evaluateAuto(force: true)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 退出前务必恢复内置屏，避免用户退出后找不到开关
        if intentDisabled { controller.enableBuiltin() }
    }

    // MARK: - 动作

    @objc private func disable() {
        let r = controller.disableBuiltin()
        switch r {
        case .ok:
            intentDisabled = true
        case .noExternal:
            notify(tr("Can't turn off the internal display", "无法关闭内置屏"),
                   tr("Connect an external display first — otherwise the screen would go completely black and unusable.",
                      "请先连接外接显示器，否则屏幕会全黑、无法操作。"))
        default:
            notify(tr("Failed to turn off", "关闭失败"), r.message)
        }
        refresh()
    }

    @objc private func enable() {
        autoDisablePending = false   // 用户手动恢复：自动模式不再立刻关闭
        controller.enableBuiltin()
        intentDisabled = false
        refresh()
    }

    @objc private func toggleAuto() {
        autoMode.toggle()
        if autoMode { evaluateAuto(force: true) }
        refresh()
    }

    /// 登录时启动（macOS 13+ 使用 SMAppService，无需手动添加到登录项）
    @available(macOS 13.0, *)
    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            notify(tr("Couldn't change Launch at Login", "无法更改登录时启动"),
                   error.localizedDescription)
        }
        // 用户可能在系统设置中禁用了本 App 的登录项，需要手动批准
        if service.status == .requiresApproval {
            notify(tr("Approval required", "需要批准"),
                   tr("Allow ClamOpen in System Settings → General → Login Items.",
                      "请在 系统设置 → 通用 → 登录项 中允许 ClamOpen。"))
            SMAppService.openSystemSettingsLoginItems()
        }
        refresh()
    }

    @objc private func quit() {
        if intentDisabled { controller.enableBuiltin() }
        NSApp.terminate(nil)
    }

    @objc private func showPowerSettings() {
        let summary = powerManager.getPowerSettingsSummary()
        let needsOpt = powerManager.needsOptimization()

        let a = NSAlert()
        a.messageText = tr("Power Management — Prevent Battery Drain During Sleep", "电源管理 —— 防止休眠耗电")
        let status = needsOpt
            ? tr("⚠️ Settings that may cause overnight battery drain were detected.", "⚠️ 检测到可能导致夜间耗电的设置。")
            : tr("✓ Current settings are already optimized.", "✓ 当前设置已优化。")
        a.informativeText = tr("""
        \(summary)

        \n\(status)

        The problem:
        TCP Keep Alive makes the Mac wake up about once a minute during sleep
        to maintain network connections, draining the battery overnight.

        Recommended:
        • Disable TCP Keep Alive, Wake on Network and Proximity Wake
        • Set the standby delay to 1 hour (saves more power)

        Normal use is not affected:
        Opening the lid, pressing a key or clicking the trackpad still wakes the Mac as usual.
        """, """
        \(summary)

        \n\(status)

        问题说明：
        TCP 保活会导致 Mac 在休眠时每分钟唤醒一次维护网络连接，
        造成电池在夜间快速耗尽。

        建议操作：
        • 禁用 TCP 保活、网络唤醒、靠近唤醒
        • 调整待机延迟为 1 小时（更省电）

        不影响正常使用：
        打开盖子、按键盘、点触控板等正常唤醒方式不受影响。
        """)

        if needsOpt {
            a.addButton(withTitle: tr("Apply Power Saving Settings (requires admin)", "应用省电设置（需管理员权限）"))
            a.addButton(withTitle: tr("Cancel", "取消"))
        } else {
            a.addButton(withTitle: tr("Restore Default Settings", "恢复默认设置"))
            a.addButton(withTitle: tr("Close", "关闭"))
        }

        NSApp.activate(ignoringOtherApps: true)
        let response = a.runModal()

        if response == .alertFirstButtonReturn {
            applyPowerOptimization(restore: !needsOpt)
        }
    }

    private func applyPowerOptimization(restore: Bool) {
        let result = restore ? powerManager.restoreDefaultSettings() : powerManager.applyPowerSavingSettings()

        let a = NSAlert()
        a.messageText = result.success ? tr("Settings applied", "设置成功") : tr("Failed to apply settings", "设置失败")
        a.informativeText = result.message

        if result.success && !restore {
            a.informativeText += tr("""


            Applied optimizations:
            • TCP Keep Alive: disabled
            • Wake on Network: disabled
            • Proximity Wake: disabled
            • Standby delay: 1 hour (on battery)

            Check the result tomorrow morning:
            open Terminal and run the following to see last night's wake-ups:
            pmset -g log | grep -E "DarkWake" | tail -20
            """, """


            已应用的优化：
            • TCP 保活：已禁用
            • 网络唤醒：已禁用
            • 靠近唤醒：已禁用
            • 待机延迟：1 小时（电池模式）

            明天早上可以检查效果：
            打开终端，运行以下命令查看昨晚的唤醒情况：
            pmset -g log | grep -E "DarkWake" | tail -20
            """)
        }

        a.addButton(withTitle: tr("OK", "好"))
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()

        // 刷新菜单（更新电源设置状态）
        rebuildMenu()
    }

    // MARK: - 自动模式 & 安全恢复

    @objc private func screensChanged() {
        enforceSafety()
    }

    /// 安全收敛：任何显示器变化后调用。
    /// 硬规则：处于关闭意图但已无外接 → 立即恢复内置屏，杜绝全黑死局。
    func enforceSafety() {
        if intentDisabled && !controller.hasExternalDisplay() {
            controller.enableBuiltin()
            intentDisabled = false
        } else if autoMode {
            evaluateAuto()
        }
        refresh()
    }

    /// - Parameter force: 启动 / 开启自动模式时为 true，按当前状态立即评估
    private func evaluateAuto(force: Bool = false) {
        guard autoMode else { return }
        let hasExt = controller.hasExternalDisplay()
        if force || hasExt != lastHasExternal {
            autoDisablePending = hasExt
            if !hasExt, intentDisabled || !controller.isBuiltinActive() {
                controller.enableBuiltin()
                intentDisabled = false
            }
        }
        lastHasExternal = hasExt

        if autoDisablePending && hasExt {
            if !controller.isBuiltinActive() {
                autoDisablePending = false
            } else if controller.disableBuiltin() == .ok {
                intentDisabled = true
                autoDisablePending = false
            }
        }
    }

    private func startWatchdog() {
        // 用 .common 模式，确保菜单打开时也持续运行
        let t = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self else { return }

            // 1) 安全恢复：意图关闭却已无外接
            if self.intentDisabled && !self.controller.hasExternalDisplay() {
                self.controller.enableBuiltin()
                self.intentDisabled = false
                self.refresh()
                return
            }
            // 2) Intel 偶发唤醒：意图关闭但内置又被点亮 → 重新关闭
            if self.intentDisabled && self.controller.hasExternalDisplay()
                && self.controller.isBuiltinActive() {
                self.controller.disableBuiltin()
                self.updateIcon()
            }
            // 3) 自动模式常态评估
            if self.autoMode { self.evaluateAuto() }
        }
        RunLoop.main.add(t, forMode: .common)
        watchdog = t
    }

    // MARK: - UI

    private func refresh() {
        rebuildMenu()
        updateIcon()
    }

    private func updateIcon() {
        let off = intentDisabled || !controller.isBuiltinActive()
        let symbol = off ? "laptopcomputer.slash" : "laptopcomputer"
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "ClamOpen") {
            img.isTemplate = true
            statusItem.button?.image = img
            statusItem.button?.title = ""
        } else {
            statusItem.button?.image = nil
            statusItem.button?.title = off ? "▣" : "▢"
        }
    }

    private func rebuildMenu() {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()

        let hasExt = controller.hasExternalDisplay()
        let builtinActive = controller.isBuiltinActive()

        // —— 状态信息 ——
        let statusText: String
        if !controller.isAPIAvailable {
            statusText = tr("⚠︎ Not supported on this system", "⚠︎ 当前系统不支持")
        } else if !builtinActive && intentDisabled {
            statusText = tr("Internal display: Off (external only)", "内置屏：已关闭（仅外接）")
        } else {
            statusText = tr("Internal display: On", "内置屏：开启中")
        }
        addInfo(menu, statusText)
        let extCount = controller.externalDisplays().count
        addInfo(menu, hasExt ? tr("External displays: \(extCount) connected", "外接显示器：\(extCount) 台已连接")
                             : tr("External displays: None connected", "外接显示器：未连接"))

        menu.addItem(.separator())

        // —— 主开关 ——
        if builtinActive {
            let item = NSMenuItem(title: tr("Turn Off Internal Display (external only)", "关闭内置屏（只用外接）"),
                                  action: #selector(disable), keyEquivalent: "d")
            item.target = self
            item.isEnabled = hasExt && controller.isAPIAvailable
            if !hasExt { item.toolTip = tr("Connect an external display first", "需要先连接外接显示器") }
            menu.addItem(item)
        } else {
            let item = NSMenuItem(title: tr("Restore Internal Display", "恢复内置屏"),
                                  action: #selector(enable), keyEquivalent: "e")
            item.target = self
            menu.addItem(item)
        }

        menu.addItem(.separator())

        // —— 自动模式 ——
        let auto = NSMenuItem(title: tr("Auto-Disable Internal Display When External Is Connected",
                                        "接外接显示器时自动关闭内置屏"),
                              action: #selector(toggleAuto), keyEquivalent: "")
        auto.target = self
        auto.state = autoMode ? .on : .off
        auto.toolTip = tr("When an external display is connected, the internal display turns off automatically. When it is unplugged, the internal display turns back on.",
                          "接上外接显示器时自动关闭内置屏，拔掉后自动恢复。")
        menu.addItem(auto)

        // —— 登录时启动 ——
        if #available(macOS 13.0, *) {
            let login = NSMenuItem(title: tr("Launch at Login", "登录时启动"),
                                   action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
            login.target = self
            login.state = SMAppService.mainApp.status == .enabled ? .on : .off
            menu.addItem(login)
        }

        menu.addItem(.separator())

        // —— 电源管理 ——
        let needsOpt = powerManager.needsOptimization()
        let powerTitle = needsOpt ? tr("⚠️ Power Management (overnight drain fix)", "⚠️ 电源管理（夜间耗电优化）")
                                  : tr("Power Management", "电源管理")
        let powerItem = NSMenuItem(title: powerTitle, action: #selector(showPowerSettings), keyEquivalent: "")
        powerItem.target = self
        menu.addItem(powerItem)

        menu.addItem(.separator())

        // —— 其它 ——
        let about = NSMenuItem(title: tr("About / How to Recover", "关于 / 如何恢复"),
                               action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        let quitItem = NSMenuItem(title: tr("Quit (restores internal display)", "退出（自动恢复内置屏）"),
                                  action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func addInfo(_ menu: NSMenu, _ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    @objc private func showAbout() {
        let a = NSAlert()
        a.messageText = tr("ClamOpen — Clamshell Mode, Lid Open", "ClamOpen — 开盖合盖")
        a.informativeText = tr("""
        Use only the external display while the lid stays open (same as clamshell mode).

        How it works: calls the private CoreGraphics API CGSConfigureDisplayEnabled
        to turn off rendering and the backlight of the internal panel.

        Safety:
        • The internal display is never turned off without an external display
        • Unplugging the external display restores the internal display
        • Quitting this app restores the internal display

        If the screen misbehaves or goes black:
        Unplug the external display, or log out / restart the Mac (the setting only lasts for the current login session).
        You can also press ⌘ Space, type the Restore app name (恢复内置屏) and press Enter.
        """, """
        盖子开着也能只用外接显示器（等效合盖）。

        原理：调用 CoreGraphics 私有接口 CGSConfigureDisplayEnabled，
        关闭内置面板的渲染与背光。

        安全保障：
        • 没有外接显示器时不会关闭内置屏
        • 拔掉外接显示器会自动恢复内置屏
        • 退出本 App 会自动恢复内置屏

        万一屏幕异常 / 全黑：
        拔掉外接显示器，或注销、重启 Mac 即可恢复（设置只在本次登录会话生效）。
        """)
        a.addButton(withTitle: tr("OK", "好"))
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    private func notify(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.addButton(withTitle: tr("OK", "好"))
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) { rebuildMenu() }
}
