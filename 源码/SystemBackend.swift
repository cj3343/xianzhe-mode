import AppKit
import CoreFoundation

final class SystemDesktopBackend: DesktopBackend {
    private var widgetKeys: [(String, String)] {
        if #available(macOS 14.0, *) {
            return [("com.apple.WindowManager", "StandardHideWidgets"),
                    ("com.apple.WindowManager", "StageManagerHideWidgets")]
        }
        return []
    }

    private var keys: [(String, String)] {
        [("com.apple.finder", "CreateDesktop"),
         ("com.apple.dock", "autohide"),
         ("NSGlobalDomain", "_HIHideMenuBar")] + widgetKeys
    }

    private func domainID(_ domain: String) -> CFString {
        domain == "NSGlobalDomain" ? kCFPreferencesAnyApplication : domain as CFString
    }

    private func preference(_ domain: String, _ key: String) -> CFPropertyList? {
        CFPreferencesSynchronize(domainID(domain), kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        return CFPreferencesCopyValue(key as CFString, domainID(domain),
                                      kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    private func writePreference(_ domain: String, _ key: String, _ value: CFPropertyList?) throws {
        CFPreferencesSetValue(key as CFString, value, domainID(domain),
                              kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard CFPreferencesSynchronize(domainID(domain), kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
            throw ModeError(message: "无法保存系统设置：\(domain) / \(key)")
        }
    }

    private func script(_ body: String) throws -> NSAppleEventDescriptor {
        guard let script = NSAppleScript(source: """
        with timeout of 30 seconds
            tell application "System Events"
                \(body)
            end tell
        end timeout
        """) else { throw ModeError(message: "无法创建系统设置脚本。") }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            let number = (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0
            if number == -1743 {
                throw ModeError(message: "需要允许“贤者模式”控制“System Events（系统事件）”。请在“系统设置 → 隐私与安全性 → 自动化”中允许后重试。")
            }
            let detail = error[NSAppleScript.errorMessage] as? String ?? "未知错误"
            throw ModeError(message: "系统设置失败（\(number)）：\(detail)")
        }
        return result
    }

    private func visibility() throws -> (dock: Bool, menu: Bool) {
        let result = try script("return {autohide of dock preferences, autohide menu bar of dock preferences}")
        let booleanTypes: Set<DescType> = [typeBoolean, typeTrue, typeFalse]
        guard result.numberOfItems == 2,
              let dock = result.atIndex(1), let menu = result.atIndex(2),
              booleanTypes.contains(dock.descriptorType), booleanTypes.contains(menu.descriptorType) else {
            throw ModeError(message: "系统未返回有效的程序坞和菜单栏状态。")
        }
        return (dock.booleanValue, menu.booleanValue)
    }

    private func setVisibility(dock: Bool, menu: Bool) throws {
        _ = try script("""
        set autohide of dock preferences to \(dock ? "true" : "false")
        set autohide menu bar of dock preferences to \(menu ? "true" : "false")
        """)
        let actual = try visibility()
        guard actual.dock == dock, actual.menu == menu else {
            throw ModeError(message: "系统未应用程序坞或菜单栏设置。原设置已保留，可再次尝试恢复。")
        }
    }

    private func restartFinder() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["-HUP", "Finder"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        // If Finder wasn't running, launch it so the preference can take effect.
        if process.terminationStatus == 1 {
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = ["-g", "-b", "com.apple.finder"]
            try open.run()
            open.waitUntilExit()
            guard open.terminationStatus == 0 else {
                throw ModeError(message: "桌面设置已保存，但无法重新启动访达。")
            }
        } else if process.terminationStatus != 0 {
            throw ModeError(message: "无法刷新访达桌面（\(process.terminationStatus)）。")
        }
    }

    private func refreshWidgets() throws {
        // WindowManager owns widget visibility. Restarting NotificationCenter alone
        // briefly removes widgets, then brings them back from WindowManager's cache.
        // Reload the owner; preserve widget placement and instances.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["-TERM", "WindowManager"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 || process.terminationStatus == 1 else {
            throw ModeError(message: "无法刷新桌面小组件（\(process.terminationStatus)）。")
        }
    }

    func capture() throws -> ModeBackup {
        // Reading permission happens before creating a journal or changing anything.
        let state = try visibility()
        let backups = try keys.map { domain, key in
            let data = try preference(domain, key).map {
                try PropertyListSerialization.data(fromPropertyList: ["value": $0],
                                                    format: .binary, options: 0)
            }
            return PreferenceBackup(domain: domain, key: key, propertyList: data)
        }
        return ModeBackup(dockWasHidden: state.dock, menuBarWasHidden: state.menu, preferences: backups)
    }

    func enable() throws {
        try setVisibility(dock: true, menu: true)
        for (domain, key) in widgetKeys {
            try writePreference(domain, key, kCFBooleanTrue)
            guard let actual = preference(domain, key), CFEqual(actual, kCFBooleanTrue) else {
                throw ModeError(message: "无法隐藏桌面小组件：\(key)")
            }
        }
        if !widgetKeys.isEmpty { try refreshWidgets() }
        try writePreference("com.apple.finder", "CreateDesktop", kCFBooleanFalse)
        guard let desktop = preference("com.apple.finder", "CreateDesktop"),
              CFEqual(desktop, kCFBooleanFalse) else {
            throw ModeError(message: "无法隐藏桌面图标。")
        }
        try restartFinder()
    }

    func restore(_ backup: ModeBackup) throws {
        var failures: [String] = []
        // Try every independent restore step even if another one fails.
        do { try setVisibility(dock: backup.dockWasHidden, menu: backup.menuBarWasHidden) }
        catch { failures.append(error.localizedDescription) }
        for item in backup.preferences {
            do {
                var value: CFPropertyList?
                if let data = item.propertyList {
                    guard let wrapped = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                          let original = wrapped["value"] else {
                        throw ModeError(message: "恢复文件中的 \(item.key) 无效。")
                    }
                    value = original as CFPropertyList
                }
                try writePreference(item.domain, item.key, value)
                let actual = preference(item.domain, item.key)
                switch (value, actual) {
                case (nil, nil): break
                case let (expected?, observed?) where CFEqual(expected, observed): break
                default: throw ModeError(message: "未能恢复设置：\(item.key)")
                }
            } catch { failures.append(error.localizedDescription) }
        }
        do { try restartFinder() } catch { failures.append(error.localizedDescription) }
        if backup.preferences.contains(where: { $0.domain == "com.apple.WindowManager" }) {
            do { try refreshWidgets() } catch { failures.append(error.localizedDescription) }
        }
        if !failures.isEmpty { throw ModeError(message: failures.joined(separator: "\n")) }
    }
}
