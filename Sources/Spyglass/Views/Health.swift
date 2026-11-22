import SwiftUI
import IOKit.ps
import Darwin

// MARK: - System readings

struct Reading: Codable {
    var date = Date()
    var cpu: Double = 0          // 0...1
    var memUsed: Int64 = 0
    var memTotal: Int64 = 0
    var pressure: Int = 1        // 1 normal, 2 warn, 4 critical
    var swap: Int64 = 0
    var diskFree: Int64 = 0
    var diskTotal: Int64 = 0
    var netIn: Double = 0        // bytes/s
    var netOut: Double = 0
    var thermal: Int = 0         // ProcessInfo.ThermalState raw
    var battery: Int? = nil      // percent
    var batteryHealth: Int? = nil // percent of design
    var cycles: Int? = nil
    var charging = false
}

enum SystemStats {
    private static var lastCPU: (user: UInt64, sys: UInt64, idle: UInt64, nice: UInt64)?
    private static var lastNet: (i: UInt64, o: UInt64, t: Date)?

    static func cpu() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) } }
        guard r == KERN_SUCCESS else { return 0 }
        let now = (UInt64(info.cpu_ticks.0), UInt64(info.cpu_ticks.1), UInt64(info.cpu_ticks.2), UInt64(info.cpu_ticks.3))
        defer { lastCPU = (now.0, now.1, now.2, now.3) }
        guard let l = lastCPU else { return 0 }
        let user = Double(now.0 &- l.user), sys = Double(now.1 &- l.sys), idle = Double(now.2 &- l.idle), nice = Double(now.3 &- l.nice)
        let total = user + sys + idle + nice
        return total > 0 ? (user + sys + nice) / total : 0
    }

    static func memory() -> (used: Int64, total: Int64, pressure: Int, swap: Int64) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &stats) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) } }
        let page = Int64(vm_kernel_page_size)
        let used = (Int64(stats.active_count) + Int64(stats.wire_count) + Int64(stats.compressor_page_count)) * page
        var level: Int32 = 1; var sz = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &sz, nil, 0)
        var swap = xsw_usage(); var ssz = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &ssz, nil, 0)
        return (used, Int64(ProcessInfo.processInfo.physicalMemory), Int(level), Int64(swap.xsu_used))
    }

    static func network() -> (Double, Double) {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return (0, 0) }
        defer { freeifaddrs(ifaddr) }
        var i: UInt64 = 0, o: UInt64 = 0
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let a = p {
            let name = String(cString: a.pointee.ifa_name)
            if a.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK), !name.hasPrefix("lo"), let d = a.pointee.ifa_data {
                let data = d.assumingMemoryBound(to: if_data.self).pointee
                i += UInt64(data.ifi_ibytes); o += UInt64(data.ifi_obytes)
            }
            p = a.pointee.ifa_next
        }
        let now = Date()
        defer { lastNet = (i, o, now) }
        guard let l = lastNet else { return (0, 0) }
        let dt = max(now.timeIntervalSince(l.t), 0.1)
        return (Double(i &- l.i) / dt, Double(o &- l.o) / dt)
    }

    static func battery() -> (percent: Int?, health: Int?, cycles: Int?, charging: Bool) {
        var percent: Int?, charging = false
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(), let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for ps in list {
                if let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any], d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType {
                    if let c = d[kIOPSCurrentCapacityKey] as? Int, let m = d[kIOPSMaxCapacityKey] as? Int, m > 0 { percent = c * 100 / m }
                    charging = d[kIOPSIsChargingKey] as? Bool ?? false
                }
            }
        }
        var health: Int?, cycles: Int?
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if svc != 0 {
            func num(_ k: String) -> Int? { (IORegistryEntryCreateCFProperty(svc, k as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.intValue }
            let maxCap = num("AppleRawMaxCapacity") ?? num("NominalChargeCapacity") ?? num("MaxCapacity")
            if let m = maxCap, let d = num("DesignCapacity"), d > 0, m > 100 { health = min(100, m * 100 / d) }
            cycles = num("CycleCount")
            IOObjectRelease(svc)
        }
        return (percent, health, cycles, charging)
    }

    static func read() -> Reading {
        var r = Reading()
        r.cpu = cpu()
        let m = memory(); r.memUsed = m.used; r.memTotal = m.total; r.pressure = m.pressure; r.swap = m.swap
        let d = Places.startupDisk(); r.diskFree = d.important; r.diskTotal = d.total
        let n = network(); r.netIn = n.0; r.netOut = n.1
        r.thermal = ProcessInfo.processInfo.thermalState.rawValue
        let b = battery(); r.battery = b.percent; r.batteryHealth = b.health; r.cycles = b.cycles; r.charging = b.charging
        return r
    }

    static func rate(_ bps: Double) -> String { Fmt.size(Int64(bps)) + "/s" }
}

struct HealthScore {
    struct Point: Identifiable { let id: String; let title: String; let detail: String; let penalty: Int; let symbol: String; let fix: String; let page: Page? }
    let score: Int
    let points: [Point]
    var word: String { score >= 90 ? "Excellent" : score >= 80 ? "Good" : score >= 60 ? "Fair" : "Needs Attention" }
    var color: Color { score >= 90 ? .green : score >= 80 ? .mint : score >= 60 ? .orange : .red }

    init(_ r: Reading) {
        var pts: [Point] = []
        let freePct = r.diskTotal > 0 ? Double(r.diskFree) / Double(r.diskTotal) : 1
        if freePct < 0.05 { pts.append(Point(id: "disk", title: "Startup disk almost full", detail: "\(Fmt.size(r.diskFree)) free", penalty: 30, symbol: "internaldrive", fix: "Free Up Space", page: .cleanup)) }
        else if freePct < 0.15 { pts.append(Point(id: "disk", title: "Low disk space", detail: "\(Fmt.size(r.diskFree)) free", penalty: 15, symbol: "internaldrive", fix: "Free Up Space", page: .cleanup)) }
        if r.pressure >= 4 { pts.append(Point(id: "mem", title: "Memory pressure is critical", detail: "Apps are being slowed down", penalty: 25, symbol: "memorychip", fix: "Open Memory", page: .memory)) }
        else if r.pressure >= 2 { pts.append(Point(id: "mem", title: "Memory pressure is elevated", detail: "\(Fmt.size(r.swap)) swap in use", penalty: 12, symbol: "memorychip", fix: "Open Memory", page: .memory)) }
        if r.cpu > 0.85 { pts.append(Point(id: "cpu", title: "Processor is very busy", detail: "\(Int(r.cpu * 100))% in use", penalty: 15, symbol: "cpu", fix: "See Busy Apps", page: .memory)) }
        else if r.cpu > 0.6 { pts.append(Point(id: "cpu", title: "Processor is busy", detail: "\(Int(r.cpu * 100))% in use", penalty: 6, symbol: "cpu", fix: "See Busy Apps", page: .memory)) }
        if r.thermal >= 2 { pts.append(Point(id: "heat", title: r.thermal >= 3 ? "Mac is very hot" : "Mac is running warm", detail: "macOS is limiting speed to cool down", penalty: r.thermal >= 3 ? 30 : 15, symbol: "thermometer.high", fix: "See Busy Apps", page: .memory)) }
        else if r.thermal == 1 { pts.append(Point(id: "heat", title: "Mac is slightly warm", detail: "Fair thermal state", penalty: 4, symbol: "thermometer.medium", fix: "See Busy Apps", page: .memory)) }
        if let h = r.batteryHealth, h < 80 { pts.append(Point(id: "battery", title: "Battery is worn", detail: "\(h)% of original capacity", penalty: h < 70 ? 15 : 8, symbol: "battery.25", fix: "Battery Settings", page: nil)) }
        points = pts
        score = max(0, 100 - pts.reduce(0) { $0 + $1.penalty })
    }
}

@MainActor final class SystemMonitor: ObservableObject {
    static let shared = SystemMonitor()
    @Published var r = Reading()
    private var timer: Timer?
    private var users = 0

    func start() {
        users += 1
        guard timer == nil else { return }
        _ = SystemStats.cpu(); _ = SystemStats.network()
        r = SystemStats.read()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            DispatchQueue.global(qos: .utility).async { let x = SystemStats.read(); DispatchQueue.main.async { self.r = x } }
        }
        timer?.tolerance = 0.5
    }
    func stop() { users = max(0, users - 1); if users == 0 { timer?.invalidate(); timer = nil } }
}

/// A reading every five minutes while Spyglass runs, kept for a week. Skipped in Low Power Mode.
@MainActor final class HealthHistory: ObservableObject {
    static let shared = HealthHistory()
    @Published var samples: [Reading] = []
    private var timer: Timer?
    private var file: URL { Places.support.appendingPathComponent("health.json") }

    func start() {
        if let d = try? Data(contentsOf: file), let s = try? JSONDecoder().decode([Reading].self, from: d) { samples = s }
        guard UserDefaults.standard.bool(forKey: "historyEnabled") else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in MainActor.assumeIsolated { self.sample() } }
        timer?.tolerance = 60
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { self.sample() }
    }
    func sample() {
        guard !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }
        DispatchQueue.global(qos: .background).async {
            _ = SystemStats.cpu(); Thread.sleep(forTimeInterval: 1)
            let r = SystemStats.read()
            DispatchQueue.main.async {
                self.samples.append(r)
                let cutoff = Date().addingTimeInterval(-7 * 86400)
                self.samples.removeAll { $0.date < cutoff }
                let s = self.samples, f = self.file
                DispatchQueue.global(qos: .background).async { try? JSONEncoder().encode(s).write(to: f) }
                AppDelegate.checkLowSpace()
            }
        }
    }
    func daysUntilFull() -> Int? {
        guard let first = samples.first, let last = samples.last, last.date.timeIntervalSince(first.date) > 86400 else { return nil }
        let used = Double(first.diskFree - last.diskFree)
        guard used > 0 else { return nil }
        let perDay = used / (last.date.timeIntervalSince(first.date) / 86400)
        return Int(Double(last.diskFree) / perDay)
    }
}

// MARK: - Views

struct HealthView: View {
    @ObservedObject var mon = SystemMonitor.shared
    @ObservedObject var hist = HealthHistory.shared
    @EnvironmentObject var model: AppModel

    var body: some View {
        let r = mon.r
        let s = HealthScore(r)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(title: "Mac Health", subtitle: "Read live on your Mac every two seconds", symbol: "heart.text.square.fill", tint: .red)
                HStack(alignment: .top, spacing: 16) {
                    Card {
                        VStack(spacing: 10) {
                            ZStack {
                                Circle().stroke(Color.primary.opacity(0.08), lineWidth: 14)
                                Circle().trim(from: 0, to: CGFloat(s.score) / 100).stroke(s.color.gradient, style: StrokeStyle(lineWidth: 14, lineCap: .round)).rotationEffect(.degrees(-90))
                                    .animation(.spring(duration: 0.8), value: s.score)
                                VStack(spacing: 0) { Text("\(s.score)").font(.system(size: 46, weight: .bold, design: .rounded)).contentTransition(.numericText()); Text(s.word).foregroundStyle(s.color).font(.headline) }
                            }.frame(width: 160, height: 160)
                            Text(s.points.isEmpty ? "Everything looks good." : "\(s.points.count) thing\(s.points.count == 1 ? "" : "s") to look at").foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity)
                    }.frame(width: 260)
                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Score breakdown").font(.headline)
                            if s.points.isEmpty { Label("No problems found", systemImage: "checkmark.seal.fill").foregroundStyle(.green) }
                            ForEach(s.points) { p in
                                HStack {
                                    Image(systemName: p.symbol).frame(width: 22).foregroundStyle(.orange)
                                    VStack(alignment: .leading) { Text(p.title); Text(p.detail).font(.caption).foregroundStyle(.secondary) }
                                    Spacer()
                                    Text("−\(p.penalty)").foregroundStyle(.secondary).monospacedDigit()
                                    Button(p.fix) { if let pg = p.page { model.show(pg) } else { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.battery")!) } }
                                }
                            }
                            Spacer(minLength: 0)
                            Text("Bands: 90+ Excellent · 80+ Good · 60+ Fair · below 60 Needs Attention").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 14)], spacing: 14) {
                    tile("Processor", "cpu", "\(Int(r.cpu * 100))%", "\(ProcessInfo.processInfo.activeProcessorCount) cores", r.cpu, .blue, hist.samples.map(\.cpu)) { model.show(.memory) }
                    tile("Memory", "memorychip", "\(Fmt.size(r.memUsed))", "of \(Fmt.size(r.memTotal)) · " + ["", "Normal", "Elevated", "", "Critical"][min(r.pressure, 4)], Double(r.memUsed) / Double(max(r.memTotal, 1)), r.pressure > 1 ? .orange : .green,
                         hist.samples.map { Double($0.memUsed) / Double(max($0.memTotal, 1)) }) { model.show(.memory) }
                    tile("Startup Disk", "internaldrive", "\(Fmt.size(r.diskFree)) free", "of \(Fmt.size(r.diskTotal))", 1 - Double(r.diskFree) / Double(max(r.diskTotal, 1)), .indigo,
                         hist.samples.map { 1 - Double($0.diskFree) / Double(max($0.diskTotal, 1)) }) { model.show(.cleanup) }
                    tile("Network", "network", "↓ \(SystemStats.rate(r.netIn))", "↑ \(SystemStats.rate(r.netOut))", min(1, r.netIn / 12_500_000), .teal, hist.samples.map { min(1, $0.netIn / 12_500_000) }) { model.show(.tool("networkspeed")) }
                    tile("Heat", "thermometer.medium", ["Nominal", "Fair", "Serious", "Critical"][min(r.thermal, 3)], "Thermal state", Double(r.thermal) / 3, r.thermal > 1 ? .red : .orange, hist.samples.map { Double($0.thermal) / 3 }) { model.show(.memory) }
                    if let b = r.battery {
                        tile("Battery", r.charging ? "battery.100.bolt" : "battery.75", "\(b)%", [r.batteryHealth.map { "Health \($0)%" }, r.cycles.map { "\($0) cycles" }].compactMap { $0 }.joined(separator: " · "),
                             Double(b) / 100, .green, hist.samples.compactMap { $0.battery.map { Double($0) / 100 } }) { model.show(.tool("battery")) }
                    }
                }
                if let days = hist.daysUntilFull() {
                    Label("At the current rate your disk fills up in about \(days) days.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                Text("History: a reading every five minutes while Spyglass runs, kept for a week (\(hist.samples.count) readings). Skipped in Low Power Mode.").font(.caption).foregroundStyle(.secondary)
            }.padding(22)
        }
        .onAppear { mon.start() }
        .onDisappear { mon.stop() }
    }

    func tile(_ t: String, _ sym: String, _ v: String, _ sub: String, _ frac: Double, _ c: Color, _ history: [Double], action: @escaping () -> Void) -> some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack { Image(systemName: sym).foregroundStyle(c); Text(t).font(.headline); Spacer()
                    Button("Fix", action: action).controlSize(.small) }
                Text(v).font(.title2.weight(.semibold)).monospacedDigit().contentTransition(.numericText())
                Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Sparkline(values: history.suffix(288).map { $0 }, color: c).frame(height: 32)
                ProgressView(value: min(max(frac, 0), 1)).tint(c)
            }
        }
    }
}

struct Sparkline: View {
    let values: [Double]
    let color: Color
    var body: some View {
        GeometryReader { g in
            if values.count > 1 {
                let maxV = max(values.max() ?? 1, 0.05)
                let pts = values.enumerated().map { CGPoint(x: g.size.width * CGFloat($0.offset) / CGFloat(values.count - 1), y: g.size.height * (1 - CGFloat($0.element / maxV))) }
                Path { p in p.addLines(pts) }.stroke(color.opacity(0.8), lineWidth: 1.5)
                Path { p in p.move(to: CGPoint(x: 0, y: g.size.height)); p.addLines(pts); p.addLine(to: CGPoint(x: g.size.width, y: g.size.height)) }.fill(color.opacity(0.12))
            } else {
                Text("History builds up over time").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Memory

struct AppUsage: Identifiable { let id: pid_t; let name: String; let icon: NSImage?; let bytes: Int64; let cpu: Double; let app: NSRunningApplication }

struct MemoryView: View {
    @ObservedObject var mon = SystemMonitor.shared
    @State private var apps: [AppUsage] = []
    @State private var lastCPU: [pid_t: (UInt64, Date)] = [:]
    @State private var sortCPU = false
    let timer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        let r = mon.r
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(title: "Memory", subtitle: "Pressure is how hard macOS is working to keep apps in memory", symbol: "memorychip.fill", tint: .green) {
                Button("Free Up Memory") { purge() }.help("Clears macOS's file cache (asks for your password)")
            }
            HStack(spacing: 14) {
                Card(padding: 12) { VStack(alignment: .leading) { Text("Pressure").font(.caption).foregroundStyle(.secondary)
                    Text(["", "Normal", "Elevated", "", "Critical"][min(r.pressure, 4)]).font(.title3.weight(.semibold)).foregroundStyle(r.pressure > 1 ? (r.pressure > 2 ? .red : .orange) : .green) } }
                Card(padding: 12) { VStack(alignment: .leading) { Text("In use").font(.caption).foregroundStyle(.secondary); Text("\(Fmt.size(r.memUsed)) of \(Fmt.size(r.memTotal))").font(.title3.weight(.semibold)) } }
                Card(padding: 12) { VStack(alignment: .leading) { Text("Swap").font(.caption).foregroundStyle(.secondary); Text(Fmt.size(r.swap)).font(.title3.weight(.semibold)) } }
                Card(padding: 12) { VStack(alignment: .leading) { Text("Processor").font(.caption).foregroundStyle(.secondary); Text("\(Int(r.cpu * 100))%").font(.title3.weight(.semibold)) } }
            }
            HStack { Text("Apps by \(sortCPU ? "processor" : "memory")").font(.headline); Spacer()
                Picker("", selection: $sortCPU) { Text("Memory").tag(false); Text("Processor").tag(true) }.pickerStyle(.segmented).frame(width: 180) }
            List(sortCPU ? apps.sorted { $0.cpu > $1.cpu } : apps) { a in
                HStack(spacing: 10) {
                    if let i = a.icon { Image(nsImage: i).resizable().frame(width: 24, height: 24) }
                    Text(a.name)
                    Spacer()
                    Text(String(format: "%.0f%%", a.cpu * 100)).foregroundStyle(.secondary).monospacedDigit().frame(width: 50, alignment: .trailing)
                    Text(Fmt.size(a.bytes)).monospacedDigit().frame(width: 90, alignment: .trailing)
                    Button("Quit") { a.app.terminate(); DispatchQueue.main.asyncAfter(deadline: .now() + 1) { refresh() } }.controlSize(.small)
                }
            }
        }
        .padding(20)
        .onAppear { mon.start(); refresh() }
        .onDisappear { mon.stop() }
        .onReceive(timer) { _ in refresh() }
    }

    func refresh() {
        let now = Date()
        var next: [pid_t: (UInt64, Date)] = [:]
        apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap { app in
            var info = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &info) { p in p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(app.processIdentifier, RUSAGE_INFO_V4, $0) } }
            guard ok == 0 else { return nil }
            let t = info.ri_user_time + info.ri_system_time
            next[app.processIdentifier] = (t, now)
            var cpu = 0.0
            if let l = lastCPU[app.processIdentifier] {
                var tb = mach_timebase_info(); mach_timebase_info(&tb)
                let ns = Double(t &- l.0) * Double(tb.numer) / Double(tb.denom)
                cpu = ns / 1e9 / max(now.timeIntervalSince(l.1), 0.1)
            }
            return AppUsage(id: app.processIdentifier, name: app.localizedName ?? "App", icon: app.icon, bytes: Int64(info.ri_phys_footprint), cpu: cpu, app: app)
        }.sorted { $0.bytes > $1.bytes }
        lastCPU = next
    }

    func purge() {
        let script = NSAppleScript(source: "do shell script \"/usr/sbin/purge\" with administrator privileges")
        var err: NSDictionary?
        script?.executeAndReturnError(&err)
        ActivityLog.shared.show(err == nil ? "Cleared the file cache" : "Memory was not cleared")
    }
}

// MARK: - Startup items

struct StartupItem: Identifiable, Hashable {
    let url: URL
    let label: String
    let program: String
    let owner: String
    let userOwned: Bool
    let leftover: Bool
    var id: URL { url }
}

struct StartupItemsView: View {
    @State private var items: [StartupItem] = []
    @State private var loginItemsNote = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Startup Items", subtitle: "Helpers and agents that start with your Mac. Apple and security items are never offered.", symbol: "power", tint: .teal) {
                Button("Login Items Settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!) }
            }.padding(20)
            Divider()
            if items.isEmpty { EmptyState(symbol: "power", title: "No third-party startup items") }
            else {
                List(items) { i in
                    HStack(spacing: 10) {
                        Image(systemName: i.leftover ? "exclamationmark.triangle.fill" : "gearshape.2").foregroundStyle(i.leftover ? .orange : .secondary).frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack { Text(i.owner).font(.headline); if i.leftover { Text("Leftover of a deleted app").font(.caption).foregroundStyle(.orange) } }
                            Text(i.label).font(.caption).foregroundStyle(.secondary)
                            Text(i.program).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                        }
                        Spacer()
                        Button { FileOps.reveal([i.url]) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.borderless)
                        if i.userOwned { Button("Turn Off") { FileOps.trash([i.url], title: "Turned off \(i.owner)"); load() } }
                        else { Button("Turn Off…") { turnOffSystem(i) } }
                    }.padding(.vertical, 3)
                }
            }
        }
        .task { load() }
    }

    func load() {
        var out: [StartupItem] = []
        let dirs: [(URL, Bool)] = [(Places.library.appendingPathComponent("LaunchAgents"), true), (URL(fileURLWithPath: "/Library/LaunchAgents"), false), (URL(fileURLWithPath: "/Library/LaunchDaemons"), false)]
        for (dir, user) in dirs {
            for u in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where u.pathExtension == "plist" {
                guard let d = NSDictionary(contentsOf: u) as? [String: Any] else { continue }
                let label = d["Label"] as? String ?? u.deletingPathExtension().lastPathComponent
                if label.hasPrefix("com.apple.") { continue }
                let lower = label.lowercased()
                if ["crowdstrike", "sentinel", "jamf", "kandji", "mosyle", "microsoft.wdav", "sophos", "malwarebytes", "carbonblack", "defender"].contains(where: lower.contains) { continue }
                let prog = d["Program"] as? String ?? (d["ProgramArguments"] as? [String])?.first ?? ""
                var owner = label.split(separator: ".").dropFirst().first.map { String($0).capitalized } ?? label
                if let r = prog.range(of: ".app/") { owner = (String(prog[..<r.lowerBound]) as NSString).lastPathComponent }
                let leftover = !prog.isEmpty && !FileManager.default.fileExists(atPath: prog)
                out.append(StartupItem(url: u, label: label, program: prog, owner: owner, userOwned: user, leftover: leftover))
            }
        }
        items = out.sorted { ($0.leftover ? 0 : 1, $0.owner) < ($1.leftover ? 0 : 1, $1.owner) }
    }

    func turnOffSystem(_ i: StartupItem) {
        let dest = Places.home.appendingPathComponent(".Trash/\(i.url.lastPathComponent)").path
        let cmd = "/bin/launchctl bootout system '\(i.url.path)' 2>/dev/null; /bin/mv '\(i.url.path)' '\(dest)'"
        var err: NSDictionary?
        NSAppleScript(source: "do shell script \"\(cmd)\" with administrator privileges")?.executeAndReturnError(&err)
        if err == nil {
            ActivityLog.shared.record(.trash, "Turned off \(i.owner)", moves: [Move(from: i.url.path, to: dest)])
            load()
        }
    }
}
