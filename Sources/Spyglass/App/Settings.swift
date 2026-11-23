import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            CleanupSettings().tabItem { Label("Cleanup", systemImage: "sparkles") }
            LibrarySettings().tabItem { Label("Library", systemImage: "books.vertical") }
            AdvancedSettings().tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
        }
        .frame(width: 560, height: 470)
    }
}

private struct GeneralSettings: View {
    @AppStorage("theme") private var theme = "playful"
    @AppStorage(GlassTheme.key) private var glassTheme = false
    @AppStorage("quickSearchHotkey") private var hotkey = "optSpace"
    @AppStorage("menuBarEnabled") private var menuBar = true
    @AppStorage("menuBarReadings") private var readings = false
    @AppStorage("showTips") private var tips = true
    @AppStorage("defaultViewMode") private var mode = "grid"
    @AppStorage("hideGettingStarted") private var hideGS = false
    @AppStorage("searchContents") private var contents = true
    @AppStorage("searchMeaning") private var meaning = true
    @State private var loginItem = LoginItem.enabled

    var body: some View {
        Form {
            Picker("Theme", selection: $theme) {
                Text("Playful — each kind of file gets its colour").tag("playful")
                Text("Minimal — the library stays grey").tag("minimal")
            }.pickerStyle(.radioGroup)
            Toggle(isOn: $glassTheme) {
                Text("Liquid Glass theme")
                Text(GlassTheme.supported ? "Quick Search, dashboard cards and pop-up notices use Apple's Liquid Glass. File lists stay plain."
                                          : "Requires macOS 26.")
            }
            .disabled(!GlassTheme.supported)
            Picker("Quick Search shortcut", selection: $hotkey) { ForEach(AppDelegate.hotkeyChoices, id: \.id) { Text($0.label).tag($0.id) } }
            Text("Works from any app, even when the Spyglass window is closed.").font(.caption).foregroundStyle(.secondary)
            Picker("Folders open as", selection: $mode) { Text("Icons").tag("grid"); Text("List").tag("list"); Text("Columns").tag("columns") }
            Toggle("Search inside file contents", isOn: $contents)
            Toggle("Search by meaning (on-device word model: “receipt” also finds “invoice”)", isOn: $meaning)
            Toggle("Show recent downloads in the menu bar", isOn: $menuBar)
            Toggle("Show Mac Health readings in the menu bar", isOn: $readings).disabled(!menuBar)
            Toggle("Open Spyglass at login", isOn: $loginItem).onChange(of: loginItem) { _, v in LoginItem.set(v) }
            Button("Show Getting Started Again") { hideGS = false; UserDefaults.standard.set("", forKey: "gsDone") }
        }.formStyle(.grouped)
    }
}

private struct CleanupSettings: View {
    @AppStorage("autoCleanSafe") private var autoSafe = false
    @AppStorage("keepOrganized") private var keep = false
    @AppStorage("lowSpaceAlert") private var lowSpace = true
    @AppStorage("lowSpaceGB") private var lowGB = 15
    @AppStorage("resetPermissionsOnUninstall") private var resetPerms = true
    var body: some View {
        Form {
            Toggle("Keep folders organized (every few hours, loose files move into subfolders)", isOn: $keep)
            Toggle("Clean Safe items automatically once a day (App Caches and developer data marked Safe)", isOn: $autoSafe)
            Toggle("Notify me when space is low", isOn: $lowSpace)
            Stepper("When less than \(lowGB) GB is free", value: $lowGB, in: 5...200, step: 5).disabled(!lowSpace)
            Toggle("Reset privacy permissions when uninstalling apps", isOn: $resetPerms)
            Text("Everything Spyglass removes goes to the Trash and is listed in Activity, so it can be put back.").font(.caption).foregroundStyle(.secondary)
            Button("Open Activity") { AppModel.shared.show(.activity) }
        }.formStyle(.grouped)
    }
}

private struct LibrarySettings: View {
    @AppStorage("showCloudDrives") private var cloud = true
    @AppStorage("historyEnabled") private var history = true
    @State private var access: [(String, Bool)] = []
    var body: some View {
        Form {
            Section("Folder access") {
                ForEach(access, id: \.0) { n, ok in HStack { Text(n); Spacer(); Label(ok ? "Allowed" : "Not allowed", systemImage: ok ? "checkmark.circle.fill" : "xmark.circle").foregroundStyle(ok ? .green : .orange) } }
                Button("Open Full Disk Access Settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!) }
                Text("Optional. Full Disk Access lets Space Map and Clean Up see every folder.").font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Show cloud drives (Google Drive, Dropbox, OneDrive, Box, iCloud Drive)", isOn: $cloud)
            Toggle("Keep a week of Mac Health history", isOn: $history)
            Button("Recount Library") { Task { await LibraryStats.shared.refresh() } }
        }
        .formStyle(.grouped)
        .onAppear {
            access = [("Desktop", Places.desktop), ("Documents", Places.documents), ("Downloads", Places.downloads)].map { n, u in
                (n, (try? FileManager.default.contentsOfDirectory(atPath: u.path)) != nil)
            }
        }
    }
}

private struct AdvancedSettings: View {
    @AppStorage("devFeatures") private var dev = false
    @AppStorage("clipboardHistory") private var clip = false
    @State private var confirmUninstall = false
    var body: some View {
        Form {
            Toggle("Show developer features (Open in Terminal, Copy Path As)", isOn: $dev)
            Toggle("Clipboard History (⌃⌥V)", isOn: $clip).onChange(of: clip) { _, _ in ClipboardHistory.shared.applySetting() }
            Section("Links") {
                Text("spyglass://search?q=…  ·  spyglass://open?path=…  ·  spyglass://tool?q=json").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
            HStack {
                Button("Export Settings…") { exportSettings() }
                Button("Import Settings…") { importSettings() }
            }
            Button("Copy Support Info") {
                let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
                var size = 0; sysctlbyname("hw.model", nil, &size, nil, 0); var m = [CChar](repeating: 0, count: size); sysctlbyname("hw.model", &m, &size, nil, 0)
                let s = "Spyglass \(v)\nmacOS \(ProcessInfo.processInfo.operatingSystemVersionString)\nMac \(String(cString: m))"
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string)
            }
            Button("Uninstall Spyglass…", role: .destructive) { confirmUninstall = true }
        }
        .formStyle(.grouped)
        .confirmationDialog("Move Spyglass and its data to the Trash, then quit?", isPresented: $confirmUninstall) {
            Button("Uninstall", role: .destructive) {
                try? FileManager.default.trashItem(at: Places.support, resultingItemURL: nil)
                try? FileManager.default.trashItem(at: Bundle.main.bundleURL, resultingItemURL: nil)
                if let id = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: id) }
                NSApp.terminate(nil)
            }
        }
    }

    static let keys = ["theme", "quickSearchHotkey", "menuBarEnabled", "menuBarReadings", "showTips", "defaultViewMode", "searchContents", "searchMeaning", "autoCleanSafe",
                       "keepOrganized", "keepOrganizedFolders", "organizeByMonth", "lowSpaceAlert", "lowSpaceGB", "resetPermissionsOnUninstall", "showCloudDrives", "historyEnabled",
                       "devFeatures", "clipboardHistory", "pinned", "savedSearches", "cardSize", "gridSort"]

    func exportSettings() {
        let p = NSSavePanel(); p.nameFieldStringValue = "Spyglass Settings.json"; p.allowedContentTypes = [.json]
        guard p.runModal() == .OK, let u = p.url else { return }
        var d: [String: Any] = [:]
        for k in Self.keys { if let v = UserDefaults.standard.object(forKey: k) { d[k] = v } }
        try? JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted, .sortedKeys]).write(to: u)
    }
    func importSettings() {
        guard let u = pickFiles(["json"], multiple: false).first, let data = try? Data(contentsOf: u),
              let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let changes = d.filter { Self.keys.contains($0.key) }
        let a = NSAlert(); a.messageText = "Import \(changes.count) settings?"; a.informativeText = changes.keys.sorted().joined(separator: ", ")
        a.addButton(withTitle: "Import"); a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn { for (k, v) in changes { UserDefaults.standard.set(v, forKey: k) } }
    }
}

import ServiceManagement
@MainActor enum LoginItem {
    static var enabled: Bool { SMAppService.mainApp.status == .enabled }
    static func set(_ on: Bool) { do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch { ActivityLog.shared.show("Couldn't change login item: \(error.localizedDescription)") } }
}
