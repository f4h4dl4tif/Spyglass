import SwiftUI
import IOKit.pwr_mgt

struct KeepAwakeTool: View {
    @ObservedObject var k = KeepAwake.shared
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: k.active ? "cup.and.saucer.fill" : "cup.and.saucer").font(.system(size: 72)).foregroundStyle(k.active ? .orange : .secondary)
                .symbolEffect(.bounce, value: k.active)
            Text(k.active ? (k.until.map { "Awake until \(DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .short))" } ?? "Awake until you turn it off") : "Your Mac sleeps as usual").font(.title3)
            HStack {
                ForEach([(15, "15 min"), (60, "1 hour"), (180, "3 hours"), (0, "Indefinitely")], id: \.0) { m, l in Button(l) { k.start(minutes: m) } }
            }
            if k.active { Button("Turn Off") { k.stop() }.buttonStyle(.borderedProminent).tint(.red) }
            Toggle("Keep the display on too", isOn: $k.display).toggleStyle(.checkbox)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor final class KeepAwake: ObservableObject {
    static let shared = KeepAwake()
    @Published var active = false
    @Published var until: Date?
    @Published var display = true
    private var id: IOPMAssertionID = 0
    private var timer: Timer?
    func start(minutes: Int) {
        stop()
        let type = (display ? kIOPMAssertionTypePreventUserIdleDisplaySleep : kIOPMAssertionTypePreventUserIdleSystemSleep) as CFString
        if IOPMAssertionCreateWithName(type, IOPMAssertionLevel(kIOPMAssertionLevelOn), "Spyglass Keep Awake" as CFString, &id) == kIOReturnSuccess {
            active = true
            if minutes > 0 {
                until = Date().addingTimeInterval(Double(minutes) * 60)
                timer = Timer.scheduledTimer(withTimeInterval: Double(minutes) * 60, repeats: false) { _ in MainActor.assumeIsolated { self.stop() } }
            }
        }
    }
    func stop() { if active { IOPMAssertionRelease(id) }; active = false; until = nil; timer?.invalidate() }
}

// MARK: - Clipboard history

@MainActor final class ClipboardHistory: ObservableObject {
    static let shared = ClipboardHistory()
    @Published var items: [String] = []
    private var timer: Timer?
    private var lastCount = NSPasteboard.general.changeCount
    private var panel: NSPanel?

    func applySetting() {
        timer?.invalidate(); timer = nil
        guard UserDefaults.standard.bool(forKey: "clipboardHistory") else { items = []; return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { _ in MainActor.assumeIsolated { self.poll() } }
        timer?.tolerance = 0.3
    }
    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastCount else { return }
        lastCount = pb.changeCount
        if pb.types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) == true { return }   // password managers
        guard let s = pb.string(forType: .string), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, s.count < 20000 else { return }
        items.removeAll { $0 == s }
        items.insert(s, at: 0)
        if items.count > 50 { items.removeLast() }
    }
    func copy(_ s: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string)
        lastCount = NSPasteboard.general.changeCount
        items.removeAll { $0 == s }; items.insert(s, at: 0)
    }
    func showPanel() {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 440), styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel, .utilityWindow], backing: .buffered, defer: true)
            p.titlebarAppearsTransparent = true; p.title = "Clipboard History"; p.isFloatingPanel = true; p.level = .floating; p.hidesOnDeactivate = false
            p.contentView = NSHostingView(rootView: ClipboardList(close: { [weak p] in p?.orderOut(nil) }))
            panel = p
        }
        panel?.center(); panel?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
}

private struct ClipboardList: View {
    @ObservedObject var h = ClipboardHistory.shared
    let close: () -> Void
    var body: some View {
        List(Array(h.items.enumerated()), id: \.offset) { i, s in
            Button { h.copy(s); close() } label: {
                HStack { Text(i < 9 ? "\(i + 1)" : " ").foregroundStyle(.secondary).monospacedDigit(); Text(s).lineLimit(2); Spacer() }.contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
        .overlay { if h.items.isEmpty { Text("Copy something and it shows up here.").foregroundStyle(.secondary) } }
    }
}

struct ClipboardTool: View {
    @AppStorage("clipboardHistory") private var on = false
    @ObservedObject var h = ClipboardHistory.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Keep clipboard history (press ⌃⌥V anywhere to open it)", isOn: $on).toggleStyle(.switch)
                .onChange(of: on) { _, _ in h.applySetting() }
            Text("Kept in memory only, never saved to disk. Items marked as passwords by password managers are skipped.").font(.caption).foregroundStyle(.secondary)
            List(Array(h.items.enumerated()), id: \.offset) { _, s in
                HStack { Text(s).lineLimit(3); Spacer(); Button("Copy") { h.copy(s); ActivityLog.shared.show("Copied") }.controlSize(.small) }
            }
            HStack { Spacer(); Button("Clear") { h.items = [] }.disabled(h.items.isEmpty) }
        }.padding(20)
    }
}

// MARK: - Battery, network, disk

struct BatteryTool: View {
    @State private var b = SystemStats.battery()
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if b.percent == nil { EmptyState(symbol: "powerplug", title: "No battery", message: "This Mac runs on power only.") }
            else {
                HStack(spacing: 14) {
                    stat("Charge", "\(b.percent ?? 0)%", b.charging ? "Charging" : "On battery")
                    stat("Health", b.health.map { "\($0)%" } ?? "–", b.health.map { $0 >= 80 ? "Normal" : "Service recommended" } ?? "Not reported")
                    stat("Cycle count", b.cycles.map(String.init) ?? "–", "Most Mac batteries are rated for 1,000")
                }
                Button("Battery Settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension")!) }
            }
            Spacer()
        }.padding(20).onAppear { b = SystemStats.battery() }
    }
    func stat(_ t: String, _ v: String, _ s: String) -> some View {
        Card { VStack(alignment: .leading, spacing: 4) { Text(t).foregroundStyle(.secondary); Text(v).font(.system(size: 30, weight: .bold, design: .rounded)); Text(s).font(.caption).foregroundStyle(.secondary) } }
    }
}

struct NetworkSpeedTool: View {
    @State private var running = false
    @State private var result: [String: Any] = [:]
    @State private var error: String?
    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 14) {
                gauge("Download", (result["dl_throughput"] as? Double).map { String(format: "%.0f Mbps", $0 / 1e6) } ?? "–", "arrow.down.circle.fill", .blue)
                gauge("Upload", (result["ul_throughput"] as? Double).map { String(format: "%.0f Mbps", $0 / 1e6) } ?? "–", "arrow.up.circle.fill", .green)
                gauge("Responsiveness", (result["responsiveness"] as? Double).map { String(format: "%.0f RPM", $0) } ?? "–", "bolt.horizontal.circle.fill", .orange)
            }
            if running { ProgressView("Testing — about 20 seconds…") }
            if let error { Text(error).foregroundStyle(.red) }
            Button(running ? "Testing…" : "Start Test") { run() }.buttonStyle(.borderedProminent).controlSize(.large).disabled(running)
            Text("Uses Apple's networkQuality test servers.").font(.caption).foregroundStyle(.secondary)
            Spacer()
        }.padding(20)
    }
    func gauge(_ t: String, _ v: String, _ s: String, _ c: Color) -> some View {
        Card { VStack(spacing: 6) { Image(systemName: s).font(.title).foregroundStyle(c); Text(v).font(.title2.weight(.bold)).monospacedDigit(); Text(t).foregroundStyle(.secondary) }.frame(maxWidth: .infinity) }
    }
    func run() {
        running = true; error = nil
        DispatchQueue.global().async {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/networkQuality"); p.arguments = ["-c"]
            let pipe = Pipe(); p.standardOutput = pipe
            do { try p.run() } catch { DispatchQueue.main.async { self.error = "networkQuality isn't available"; running = false }; return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            DispatchQueue.main.async { if let obj { result = obj } else { error = "The test didn't finish. Check your connection." }; running = false }
        }
    }
}

struct DiskSpeedTool: View {
    @State private var target = FileManager.default.temporaryDirectory
    @State private var write: Double?
    @State private var read: Double?
    @State private var running = false
    var body: some View {
        VStack(spacing: 18) {
            HStack {
                Menu("Drive: \(target.path.hasPrefix("/Volumes/") ? target.pathComponents[2] : "Macintosh HD")") {
                    Button("Macintosh HD") { target = FileManager.default.temporaryDirectory }
                    ForEach(Places.volumes()) { v in Button(v.name) { target = v.url } }
                }.frame(width: 240)
            }
            HStack(spacing: 14) {
                Card { VStack { Text("Write").foregroundStyle(.secondary); Text(write.map { String(format: "%.0f MB/s", $0) } ?? "–").font(.title.weight(.bold)).monospacedDigit() }.frame(maxWidth: .infinity) }
                Card { VStack { Text("Read").foregroundStyle(.secondary); Text(read.map { String(format: "%.0f MB/s", $0) } ?? "–").font(.title.weight(.bold)).monospacedDigit() }.frame(maxWidth: .infinity) }
            }
            if running { ProgressView("Writing and reading a 1 GB test file…") }
            Button("Start Test") { run() }.buttonStyle(.borderedProminent).controlSize(.large).disabled(running)
            Spacer()
        }.padding(20)
    }
    func run() {
        running = true; write = nil; read = nil
        let file = target.appendingPathComponent(".spyglass-speedtest-\(UUID().uuidString)")
        DispatchQueue.global(qos: .userInitiated).async {
            let chunk = Data(count: 8 << 20), total = 1 << 30
            FileManager.default.createFile(atPath: file.path, contents: nil)
            var w = 0.0, r = 0.0
            if let h = FileHandle(forWritingAtPath: file.path) {
                _ = fcntl(h.fileDescriptor, F_NOCACHE, 1)
                let t0 = Date()
                for _ in 0..<(total / chunk.count) { h.write(chunk) }
                try? h.synchronize(); try? h.close()
                w = Double(total) / 1e6 / Date().timeIntervalSince(t0)
            }
            if let h = FileHandle(forReadingAtPath: file.path) {
                _ = fcntl(h.fileDescriptor, F_NOCACHE, 1)
                let t0 = Date()
                while autoreleasepool(invoking: { !h.readData(ofLength: chunk.count).isEmpty }) {}
                try? h.close()
                r = Double(total) / 1e6 / Date().timeIntervalSince(t0)
            }
            try? FileManager.default.removeItem(at: file)
            DispatchQueue.main.async { write = w; read = r; running = false }
        }
    }
}

// MARK: - Full-screen utilities

@MainActor final class FullScreenOverlay {
    static var window: NSWindow?
    static var monitor: Any?
    static func show<V: View>(_ v: V, swallowKeys: Bool) {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let w = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.level = .screenSaver; w.isOpaque = true; w.backgroundColor = .black
        w.contentView = NSHostingView(rootView: v.frame(maxWidth: .infinity, maxHeight: .infinity))
        w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        window = w
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { e in
            if !swallowKeys && e.type == .keyDown && e.keyCode == 53 { close(); return nil }
            return swallowKeys ? nil : e
        }
    }
    static func close() {
        if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
        window?.orderOut(nil); window = nil
    }
}

struct CleanKeyboardTool: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "keyboard").font(.system(size: 64)).foregroundStyle(.secondary)
            Text("The keyboard is locked while the cleaning screen is open. Click Done with the mouse or trackpad to finish.").multilineTextAlignment(.center).frame(maxWidth: 420)
            Button("Start Cleaning") { FullScreenOverlay.show(CleaningScreen(), swallowKeys: true) }.buttonStyle(.borderedProminent).controlSize(.large)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
private struct CleaningScreen: View {
    var body: some View {
        ZStack {
            Color.black
            VStack(spacing: 20) {
                Image(systemName: "sparkles").font(.system(size: 70)).foregroundStyle(.white)
                Text("Wipe away — keys are ignored").font(.largeTitle.weight(.semibold)).foregroundStyle(.white)
                Button("Done") { FullScreenOverlay.close() }.controlSize(.large).buttonStyle(.borderedProminent)
            }
        }
    }
}

struct PixelTestTool: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "display").font(.system(size: 64)).foregroundStyle(.secondary)
            Text("Fills the screen with solid colours. Click or press Space for the next colour, Esc to finish.").multilineTextAlignment(.center).frame(maxWidth: 420)
            Button("Start Test") { FullScreenOverlay.show(PixelScreen(), swallowKeys: false) }.buttonStyle(.borderedProminent).controlSize(.large)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
private struct PixelScreen: View {
    @State private var i = 0
    let colors: [Color] = [.red, .green, .blue, .white, .black, .gray, .yellow, .cyan, .pink]
    var body: some View {
        colors[i % colors.count].ignoresSafeArea()
            .onTapGesture { if i >= colors.count - 1 { FullScreenOverlay.close() } else { i += 1 } }
            .focusable().onKeyPress(.space) { i += 1; if i >= colors.count { FullScreenOverlay.close() }; return .handled }
    }
}

struct EjectAllTool: View {
    @State private var vols = Places.volumes().filter(\.ejectable)
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if vols.isEmpty { EmptyState(symbol: "eject", title: "No external disks") }
            else {
                ForEach(vols) { v in HStack { Image(systemName: "externaldrive.fill"); Text(v.name); Spacer(); Text("\(Fmt.size(v.free)) free").foregroundStyle(.secondary) } }
                Button("Eject All") {
                    var n = 0
                    for v in vols { if (try? NSWorkspace.shared.unmountAndEjectDevice(at: v.url)) != nil { n += 1 } }
                    ActivityLog.shared.show("Ejected \(n) of \(vols.count) disks"); vols = Places.volumes().filter(\.ejectable)
                }.buttonStyle(.borderedProminent)
            }
            Spacer()
        }.padding(20)
    }
}

struct ClearDesktopTool: View {
    @State private var hidden = (UserDefaults(suiteName: "com.apple.finder")?.object(forKey: "CreateDesktop") as? Bool) == false
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: hidden ? "eye.slash" : "menubar.dock.rectangle").font(.system(size: 64)).foregroundStyle(.secondary)
            Text(hidden ? "Desktop icons are hidden" : "Desktop icons are showing").font(.title3)
            Button(hidden ? "Show Desktop Icons" : "Hide Desktop Icons") { toggle() }.buttonStyle(.borderedProminent).controlSize(.large)
            Text("Files stay where they are; Finder just stops drawing them. Finder restarts briefly.").font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    func toggle() {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "defaults write com.apple.finder CreateDesktop -bool \(hidden ? "true" : "false") && killall Finder"]
        try? p.run(); p.waitUntilExit(); hidden.toggle()
    }
}

struct WiFiTool: View {
    @State private var ssid = ""
    @State private var pw = ""
    @State private var security = "WPA"
    var payload: String {
        func e(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ";", with: "\\;").replacingOccurrences(of: ",", with: "\\,").replacingOccurrences(of: ":", with: "\\:") }
        return "WIFI:T:\(security);S:\(e(ssid));P:\(e(pw));;"
    }
    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            Form {
                TextField("Network name", text: $ssid)
                SecureField("Password", text: $pw)
                Picker("Security", selection: $security) { Text("WPA/WPA2/WPA3").tag("WPA"); Text("WEP").tag("WEP"); Text("None").tag("nopass") }
                Text("Guests point their phone camera at the code to join. Nothing is stored.").font(.caption).foregroundStyle(.secondary)
            }.formStyle(.grouped).frame(width: 360)
            if !ssid.isEmpty, let img = QR.make(payload) {
                VStack { Image(nsImage: img).interpolation(.none).resizable().frame(width: 240, height: 240).padding(12).background(.white, in: RoundedRectangle(cornerRadius: 12)); Text(ssid).font(.headline) }
            }
        }.padding(20)
    }
}

struct UnblockTool: View {
    @State private var app: URL?
    @State private var done = false
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.shield").font(.system(size: 64)).foregroundStyle(.secondary)
            Text("If macOS refuses to open an app you trust because it's “from an unidentified developer”, this removes the download quarantine flag so it opens normally. Only use it for apps you trust.")
                .multilineTextAlignment(.center).frame(maxWidth: 460)
            Button(app?.lastPathComponent ?? "Choose App…") { let p = NSOpenPanel(); p.allowedContentTypes = [.application]; p.directoryURL = Places.applications; if p.runModal() == .OK { app = p.url; done = false } }
            if let app {
                Button("Unblock \(app.deletingPathExtension().lastPathComponent)") { unblock(app) }.buttonStyle(.borderedProminent)
            }
            if done { Label("Done — open the app as usual", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    func unblock(_ u: URL) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/xattr"); p.arguments = ["-dr", "com.apple.quarantine", u.path]
        try? p.run(); p.waitUntilExit()
        if p.terminationStatus == 0 { done = true; return }
        var err: NSDictionary?
        NSAppleScript(source: "do shell script \"/usr/bin/xattr -dr com.apple.quarantine '\(u.path)'\" with administrator privileges")?.executeAndReturnError(&err)
        done = err == nil
    }
}

struct ShortcutsTool: View {
    let groups: [(String, [(String, String)])] = [
        ("Anywhere", [("Quick Search", "⌥Space (change in Settings)"), ("Clipboard History", "⌃⌥V (when on)")]),
        ("Find", [("Quick Search / Command palette", "⌘K or ⌘F"), ("Downloaded From", "⇧⌘J"), ("Recents", "⇧⌘F"), ("Assistant", "⌥⇧⌘A")]),
        ("View", [("Icons / List / Columns", "⌘1 / ⌘2 / ⌘3"), ("Inspector", "⌘I"), ("Quick Look", "Space"), ("Hidden files", "⇧⌘."), ("Playful / Minimal", "⌃⌘T"), ("Look / Sweep / Tools", "⌥⌘1 / ⌥⌘2 / ⌥⌘3")]),
        ("Go", [("Back / Forward", "⌘[ / ⌘]"), ("Enclosing folder", "⌘↑"), ("Open", "⌘↓"), ("Home / Desktop / Documents", "⇧⌘H / ⇧⌘D / ⇧⌘O"), ("Downloads / Applications", "⌥⌘L / ⇧⌘A"), ("Go to Folder", "⇧⌘G")]),
        ("Tabs", [("New tab", "⌘T"), ("Close tab", "⌘W"), ("Next tab", "⌃Tab"), ("Open in new tab", "⌘-double-click")]),
        ("Files", [("Copy / Paste", "⌘C / ⌘V"), ("Move items here", "⌥⌘V"), ("Duplicate", "⌘D"), ("Rename", "Return"), ("New folder", "⇧⌘N"), ("Move to Trash", "⌘⌫"), ("Undo", "⌘Z")]),
        ("Tidy", [("Clean Up", "⇧⌘K"), ("Duplicates", "⇧⌘I"), ("Space Map", "⇧⌘M"), ("Disk Usage", "⇧⌘U"), ("Mac Health", "⌃⌥⌘H"), ("Memory", "⇧⌘P"), ("Activity", "⇧⌘Y"), ("Put back last cleanup", "⌥⌘Z")]),
    ]
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 14)], alignment: .leading, spacing: 14) {
                ForEach(groups, id: \.0) { g in
                    Card {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(g.0).font(.headline)
                            ForEach(g.1, id: \.0) { s in HStack { Text(s.0); Spacer(); Text(s.1).font(.system(.body, design: .rounded)).foregroundStyle(.secondary) } }
                        }
                    }
                }
            }.padding(20)
        }
    }
}
