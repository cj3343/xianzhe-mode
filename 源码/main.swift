import AppKit
import Darwin
import Carbon

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem!
    private var toggleItem: NSMenuItem!
    private var quitItem: NSMenuItem!
    private var controller: ModeController!
    private var busy = false
    private var signalSources: [DispatchSourceSignal] = []
    private var controlWindow: NSWindow?
    private var windowToggle: NSButton?
    private var windowStatus: NSTextField?
    private var hotKey: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?

    private func registerRescueShortcut() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let appDelegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            appDelegate.showControl()
            return noErr
        }, 1, &type, context, &hotKeyHandler)
        guard installed == noErr else { log("shortcut handler failed: \(installed)"); return }
        let identifier = EventHotKeyID(signature: OSType(0x58495A48), id: 1)
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_S), UInt32(cmdKey | optionKey | controlKey),
                                        identifier, GetApplicationEventTarget(), 0, &hotKey)
        log("rescue shortcut registered: \(status)")
    }

    private func log(_ message: String) {
        guard let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let directory = folder.appendingPathComponent("XianZheMode")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("startup.log")
        let line = "\(Date()) \(message)\n"
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        log("didFinishLaunching v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "unknown") pid=\(ProcessInfo.processInfo.processIdentifier)")
        let identifier = Bundle.main.bundleIdentifier ?? "local.xianzhe.mode"
        let copies = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
        if copies.contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            NSApp.terminate(nil)
            return
        }
        let statusName = "SageModeStatus"
        if !UserDefaults.standard.bool(forKey: "statusPlacementV2") {
            // Keep the entry near the system items, to the right of collapsing utilities.
            UserDefaults.standard.set(0, forKey: "NSStatusItem Preferred Position \(statusName)")
            UserDefaults.standard.set(true, forKey: "NSStatusItem Visible \(statusName)")
            UserDefaults.standard.set(true, forKey: "statusPlacementV2")
        }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = statusName
        item.behavior = []
        let menu = NSMenu()
        toggleItem = NSMenuItem(title: "开启贤者模式", action: #selector(toggle), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)
        menu.addItem(.separator())
        quitItem = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)
        menu.autoenablesItems = false
        item.menu = menu
        item.isVisible = true
        registerRescueShortcut()

        do {
            let support = try FileManager.default.url(for: .applicationSupportDirectory,
                in: .userDomainMask, appropriateFor: nil, create: true)
            let store = FileRecoveryStore(url: support.appendingPathComponent("XianZheMode/original-settings.plist"))
            controller = try ModeController(backend: SystemDesktopBackend(), store: store)
        } catch {
            showError(error)
            NSApp.terminate(nil)
            return
        }
        refresh()
        log("status item installed; visible=\(item.isVisible), frame=\(String(describing: item.button?.window?.frame))")
        DispatchQueue.main.async { self.showControl() }
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
        // A previous force-quit may have left settings hidden. Restore, never overwrite its backup.
        if controller.isActive {
            DispatchQueue.main.async { self.performChange { try self.controller.disable() } }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        item?.isVisible = true
        DispatchQueue.main.async { self.showControl() }
        log("reopen: showing control")
        return false
    }

    private func showControl() {
        if controlWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 210),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "贤者模式"
            window.isReleasedWhenClosed = false
            let status = NSTextField(labelWithString: "贤者模式已关闭")
            status.alignment = .center
            status.font = .systemFont(ofSize: 16, weight: .medium)
            status.frame = NSRect(x: 20, y: 163, width: 320, height: 24)
            let button = NSButton(title: "开启贤者模式", target: self, action: #selector(toggle))
            button.bezelStyle = .rounded
            button.frame = NSRect(x: 95, y: 116, width: 170, height: 34)
            let exitButton = NSButton(title: "恢复原设置并退出", target: self, action: #selector(quit))
            exitButton.bezelStyle = .rounded
            exitButton.frame = NSRect(x: 95, y: 77, width: 170, height: 32)
            let hint = NSTextField(labelWithString: "随时按 ⌃⌥⌘S 唤回窗口，或再次打开应用。")
            hint.alignment = .center
            hint.font = .systemFont(ofSize: 11)
            hint.textColor = .secondaryLabelColor
            hint.frame = NSRect(x: 10, y: 41, width: 340, height: 20)
            let hint2 = NSTextField(labelWithString: "顶部“贤·开 / 贤·关”显示当前状态。")
            hint2.alignment = .center
            hint2.font = .systemFont(ofSize: 11)
            hint2.textColor = .secondaryLabelColor
            hint2.frame = NSRect(x: 10, y: 19, width: 340, height: 20)
            window.contentView?.addSubview(status)
            window.contentView?.addSubview(button)
            window.contentView?.addSubview(exitButton)
            window.contentView?.addSubview(hint)
            window.contentView?.addSubview(hint2)
            controlWindow = window
            windowToggle = button
            windowStatus = status
            window.center()
        }
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        controlWindow?.makeKeyAndOrderFront(nil)
        log("control shown; status frame=\(String(describing: item?.button?.window?.frame))")
    }

    private func refresh() {
        let active = controller?.isActive ?? false
        let symbol = active ? "moon.zzz.fill" : "moon"
        let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: "贤者模式")
        icon?.isTemplate = true
        item?.button?.image = icon
        item?.button?.title = active ? "贤·开" : "贤·关"
        item?.button?.setAccessibilityLabel("贤者模式")
        item?.button?.toolTip = active ? "贤者模式已开启 · 移到屏幕顶部可打开菜单" : "贤者模式已关闭"
        toggleItem?.title = active ? "关闭贤者模式" : "开启贤者模式"
        toggleItem?.state = active ? .on : .off
        toggleItem?.isEnabled = !busy
        windowToggle?.title = active ? "关闭贤者模式" : "开启贤者模式"
        windowToggle?.isEnabled = !busy
        windowStatus?.stringValue = active ? "贤者模式已开启" : "贤者模式已关闭"
        quitItem?.title = active ? "恢复原设置并退出" : "退出"
        quitItem?.isEnabled = !busy
    }

    private func performChange(_ operation: () throws -> Void) {
        guard !busy else { return }
        busy = true
        refresh()
        defer { busy = false; refresh() }
        do { try operation(); log("mode changed; active=\(controller.isActive)") }
        catch { log("mode failed: \(error.localizedDescription)"); showError(error) }
    }

    @objc private func toggle() {
        guard !busy else { return }
        // Let the menu close before hiding the bar or restarting Finder.
        DispatchQueue.main.async {
            self.performChange {
                if self.controller.isActive { try self.controller.disable() }
                else { try self.controller.enable() }
            }
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    func applicationWillTerminate(_ notification: Notification) {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !busy else { return .terminateCancel }
        guard let controller, controller.isActive else { return .terminateNow }
        do { try controller.disable(); return .terminateNow }
        catch { showError(error); refresh(); return .terminateCancel }
    }

    private func showError(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "贤者模式"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}

if CommandLine.arguments.contains("--self-test") {
    do { try runSelfTests(); exit(0) }
    catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
}

let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.setActivationPolicy(.accessory)
// NSApplication.delegate is weak. Retain its status item throughout the event loop.
withExtendedLifetime(delegate) {
    app.run()
}
