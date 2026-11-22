import AppKit
import SwiftUI
import Carbon.HIToolbox
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var hotKeys: [EventHotKeyRef?] = []
    private var lowSpaceTimer: Timer?
    private var organizeTimer: Timer?

    func applicationDidFinishLaunching(_ n: Notification) {
        UserDefaults.standard.register(defaults: [
            "theme": "playful", "menuBarEnabled": true, "menuBarReadings": false, "quickSearchHotkey": "optSpace",
            "lowSpaceAlert": true, "lowSpaceGB": 15, "showTips": true, "searchContents": true, "searchMeaning": true,
            "historyEnabled": true, "showCloudDrives": true,
        ])
        MainActor.assumeIsolated {
            if UserDefaults.standard.bool(forKey: "menuBarEnabled") { StatusItemController.shared.install() }
            HealthHistory.shared.start()
            ClipboardHistory.shared.applySetting()
            ImageTextIndex.shared.start()
            RoutineEngine.shared.start()
        }
        registerHotKeys()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.registerHotKeysIfChanged()
        }
        lowSpaceTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { _ in Self.checkLowSpace() }
        lowSpaceTimer?.tolerance = 120
        Self.checkLowSpace()
        organizeTimer = Timer.scheduledTimer(withTimeInterval: 3 * 3600, repeats: true) { _ in
            MainActor.assumeIsolated { Organizer.runKeepOrganized(); Self.autoCleanIfDue() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { MainActor.assumeIsolated { Self.autoCleanIfDue() } }
        organizeTimer?.tolerance = 600
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { MainActor.assumeIsolated { WindowOpener.openMain() } }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            for u in urls {
                if u.scheme == "spyglass" { handleLink(u); continue }
                AppModel.shared.openItem(u)
            }
        }
    }

    @MainActor private func handleLink(_ u: URL) {
        let m = AppModel.shared
        let comps = URLComponents(url: u, resolvingAgainstBaseURL: false)
        let q = comps?.queryItems?.first { $0.name == "q" || $0.name == "path" }?.value ?? ""
        switch u.host {
        case "search": m.show(.search(q))
        case "open": m.openItem(URL(fileURLWithPath: (q as NSString).expandingTildeInPath))
        case "cleanup": m.show(.cleanup)
        case "health": m.show(.health)
        case "tool": m.show(.tool(q))
        case "page" where UserDefaults.standard.bool(forKey: "debugSnapshots"):
            let pages: [String: Page] = ["home": .home, "folder": .folder, "recents": .recents, "downloads": .downloadedFrom, "images": .library(.images), "cleanup": .cleanup,
                "duplicates": .duplicates, "large": .largeFiles, "spacemap": .spaceMap, "disk": .diskUsage, "uninstaller": .uninstaller, "caches": .caches, "startup": .startup,
                "health": .health, "memory": .memory, "activity": .activity, "organize": .organize, "assistant": .assistant, "tools": .tools(nil),
                "photos": .photos, "imagetext": .imageText, "routines": .routines]
            if let f = comps?.queryItems?.first(where: { $0.name == "file" })?.value { ToolInbox.shared.files = [URL(fileURLWithPath: f)] }
            if q == "split" { m.show(.folder); if m.splitTab == nil { m.toggleSplit() }; return }
            if let p = pages[q] { m.show(p) } else if q.hasPrefix("search:") { m.show(.search(String(q.dropFirst(7)))) } else { m.show(.tool(q)) }
        case "snapshot" where UserDefaults.standard.bool(forKey: "debugSnapshots"):
            if q == "quick" { QuickSearchPanel.shared.show() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                let w = q == "quick" ? NSApp.windows.first { $0 is KeyPanel } : NSApp.windows.first { $0.title == "Spyglass" || $0.identifier?.rawValue == "main" }
                guard let v = w?.contentView?.superview ?? w?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
                v.cacheDisplay(in: v.bounds, to: rep)
                let out = comps?.queryItems?.first { $0.name == "out" }?.value ?? "/tmp/spyglass.png"
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
            }
        default: m.show(.home)
        }
    }

    // MARK: Global hotkeys (Carbon — no Accessibility permission needed)

    private var currentHotkeyKey = ""
    private func registerHotKeysIfChanged() {
        let k = (UserDefaults.standard.string(forKey: "quickSearchHotkey") ?? "") + (UserDefaults.standard.bool(forKey: "clipboardHistory") ? "c" : "")
        if k != currentHotkeyKey { registerHotKeys() }
    }

    static let hotkeyChoices: [(id: String, label: String, key: UInt32, mods: UInt32)] = [
        ("optSpace", "⌥ Space", UInt32(kVK_Space), UInt32(optionKey)),
        ("ctrlOptSpace", "⌃⌥ Space", UInt32(kVK_Space), UInt32(controlKey | optionKey)),
        ("ctrlSpace", "⌃ Space", UInt32(kVK_Space), UInt32(controlKey)),
        ("cmdShiftSpace", "⇧⌘ Space", UInt32(kVK_Space), UInt32(cmdKey | shiftKey)),
        ("off", "Off", 0, 0),
    ]

    private func registerHotKeys() {
        for h in hotKeys { if let h { UnregisterEventHotKey(h) } }
        hotKeys.removeAll()
        let choice = UserDefaults.standard.string(forKey: "quickSearchHotkey") ?? "optSpace"
        let clip = UserDefaults.standard.bool(forKey: "clipboardHistory")
        currentHotkeyKey = choice + (clip ? "c" : "")

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        struct Once { static var installed = false }
        if !Once.installed {
            Once.installed = true
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var hk = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if hk.id == 1 { QuickSearchPanel.shared.toggle() }
                        if hk.id == 2 { ClipboardHistory.shared.showPanel() }
                    }
                }
                return noErr
            }, 1, &spec, nil, nil)
        }
        if let c = Self.hotkeyChoices.first(where: { $0.id == choice }), c.id != "off" {
            var ref: EventHotKeyRef?
            RegisterEventHotKey(c.key, c.mods, EventHotKeyID(signature: OSType(0x5350_5947), id: 1), GetApplicationEventTarget(), 0, &ref)
            hotKeys.append(ref)
        }
        if clip {
            var ref: EventHotKeyRef?
            RegisterEventHotKey(UInt32(kVK_ANSI_V), UInt32(controlKey | optionKey), EventHotKeyID(signature: OSType(0x5350_5947), id: 2), GetApplicationEventTarget(), 0, &ref)
            hotKeys.append(ref)
        }
    }

    @MainActor static func autoCleanIfDue() {
        let d = UserDefaults.standard
        guard d.bool(forKey: "autoCleanSafe"), Date().timeIntervalSince1970 - d.double(forKey: "lastAutoClean") > 86400 else { return }
        d.set(Date().timeIntervalSince1970, forKey: "lastAutoClean")
        Task { await CleanupScanner.shared.scan(); CleanupScanner.shared.cleanSafe() }
    }

    // MARK: Low space alert

    static func checkLowSpace() {
        let d = UserDefaults.standard
        guard d.bool(forKey: "lowSpaceAlert") else { return }
        let free = Places.startupDisk().important
        let limit = Int64(d.integer(forKey: "lowSpaceGB")) * 1_000_000_000
        if free < limit {
            guard !d.bool(forKey: "lowSpaceNotified") else { return }
            d.set(true, forKey: "lowSpaceNotified")
            let center = UNUserNotificationCenter.current()
            center.requestAuthorization(options: [.alert, .sound]) { ok, _ in
                guard ok else { return }
                let c = UNMutableNotificationContent()
                c.title = "Your Mac is running low on space"
                var body = "\(Fmt.size(free)) left on your startup disk."
                if let days = MainActor.assumeIsolatedOrNil({ HealthHistory.shared.daysUntilFull() }) { body += " At this rate it fills up in about \(days) days." }
                c.body = body + " Open Clean Up to free some."
                center.add(UNNotificationRequest(identifier: "lowspace", content: c, trigger: nil))
            }
        } else if free > limit + 2_000_000_000 {
            d.set(false, forKey: "lowSpaceNotified")
        }
    }
}

extension MainActor {
    static func assumeIsolatedOrNil<T>(_ body: @MainActor () -> T?) -> T? {
        if Thread.isMainThread { return MainActor.assumeIsolated(body) }
        return DispatchQueue.main.sync { MainActor.assumeIsolated(body) }
    }
}
