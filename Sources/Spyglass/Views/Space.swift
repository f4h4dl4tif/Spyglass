import SwiftUI

/// Folder tree with sizes. Keeps detail only for the top levels so memory stays small.
final class SizeNode: Identifiable {
    let url: URL
    let name: String
    var size: Int64
    var children: [SizeNode]
    let isDir: Bool
    weak var parent: SizeNode?
    var id: URL { url }
    init(url: URL, name: String, size: Int64, children: [SizeNode], isDir: Bool) {
        self.url = url; self.name = name; self.size = size; self.children = children; self.isDir = isDir
        children.forEach { $0.parent = self }
    }
}

@MainActor final class DiskScan: ObservableObject {
    static let shared = DiskScan()
    @Published var root: SizeNode?
    @Published var focus: SizeNode?
    @Published var scanning = false
    @Published var scanned = 0
    @Published var target = Places.home
    private var cancelled = false

    func scan(_ url: URL? = nil) {
        if let url { target = url }
        cancelled = true
        let t = target
        scanning = true; scanned = 0; root = nil; focus = nil
        cancelled = false
        Task.detached(priority: .utility) { [weak self] in
            var count = 0
            func build(_ u: URL, depth: Int) -> SizeNode {
                let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .totalFileAllocatedSizeKey, .isSymbolicLinkKey]
                let v = try? u.resourceValues(forKeys: Set(keys))
                let name = FileManager.default.displayName(atPath: u.path)
                if v?.isSymbolicLink == true { return SizeNode(url: u, name: name, size: 0, children: [], isDir: false) }
                guard v?.isDirectory == true else { return SizeNode(url: u, name: name, size: Int64(v?.totalFileAllocatedSize ?? 0), children: [], isDir: false) }
                if depth >= 4 || v?.isPackage == true {
                    return SizeNode(url: u, name: name, size: Sizer.size(of: u), children: [], isDir: true)
                }
                let kids = (try? FileManager.default.contentsOfDirectory(at: u, includingPropertiesForKeys: keys, options: [])) ?? []
                var nodes = kids.map { build($0, depth: depth + 1) }
                count += kids.count
                if count % 500 < kids.count { let c = count; Task { @MainActor in self?.scanned = c } }
                let total = nodes.reduce(Int64(0)) { $0 + $1.size }
                nodes.sort { $0.size > $1.size }
                // Collapse the long tail into one "Smaller items" node.
                let keep = depth < 2 ? 24 : 12
                if nodes.count > keep {
                    let tail = nodes[keep...]
                    let rest = tail.reduce(Int64(0)) { $0 + $1.size }
                    nodes = Array(nodes.prefix(keep)) + [SizeNode(url: u.appendingPathComponent("…smaller"), name: "\(tail.count) smaller items", size: rest, children: [], isDir: false)]
                }
                return SizeNode(url: u, name: name, size: total, children: nodes, isDir: true)
            }
            let r = build(t, depth: 0)
            await MainActor.run { self?.root = r; self?.focus = r; self?.scanning = false; GrowthTracker.shared.record(r) }
        }
    }
}

struct SpaceMapView: View {
    @StateObject private var scan = DiskScan.shared
    @State private var hover: SizeNode?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Space Map", subtitle: scan.scanning ? "Mapping \(Fmt.count(scan.scanned)) items…" : "Click a ring to zoom in. Press Esc to zoom out.", symbol: "chart.pie.fill", tint: .blue) {
                HStack {
                    Button(Places.displayPath(scan.target)) { if let u = pickFolder() { scan.scan(u) } }
                    Button { scan.scan() } label: { Image(systemName: "arrow.clockwise") }.disabled(scan.scanning)
                }
            }.padding(20)
            if let focus = scan.focus {
                HStack(alignment: .top, spacing: 20) {
                    ZStack {
                        Sunburst(node: focus, hover: $hover) { n in if !n.children.isEmpty { withAnimation(.snappy) { scan.focus = n } } }
                        VStack(spacing: 2) {
                            Text((hover ?? focus).name).font(.headline).lineLimit(2).multilineTextAlignment(.center)
                            Text(Fmt.size((hover ?? focus).size)).font(.title2.weight(.semibold)).monospacedDigit()
                            if focus.parent != nil {
                                Button { withAnimation(.snappy) { scan.focus = focus.parent } } label: { Label("Back", systemImage: "arrow.uturn.left") }
                                    .buttonStyle(.borderless).keyboardShortcut(.cancelAction)
                            }
                        }.frame(width: 150)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    SizeList(node: focus, onOpen: { n in if !n.children.isEmpty { withAnimation(.snappy) { scan.focus = n } } }).frame(width: 320)
                }.padding([.horizontal, .bottom], 20)
            } else {
                VStack(spacing: 14) {
                    if scan.scanning { ProgressView() } else {
                        EmptyState(symbol: "chart.pie", title: "Map your disk", message: "See which folders take the most space.")
                        Button("Map \(Places.displayPath(scan.target))") { scan.scan() }.buttonStyle(.borderedProminent)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { if scan.root == nil && !scan.scanning { scan.scan() } }
    }
}

struct Sunburst: View {
    let node: SizeNode
    @Binding var hover: SizeNode?
    let tap: (SizeNode) -> Void
    private struct Seg { let node: SizeNode; let depth: Int; let start: Double; let end: Double; let hue: Double }

    private func segments() -> [Seg] {
        var out: [Seg] = []
        func walk(_ n: SizeNode, depth: Int, start: Double, span: Double, hue: Double?) {
            guard depth <= 3, n.size > 0 else { return }
            var a = start
            for (i, c) in n.children.enumerated() {
                let s = span * Double(c.size) / Double(n.size)
                guard s > 0.004 else { a += s; continue }
                let h = hue ?? Double(i) / Double(max(n.children.count, 1))
                out.append(Seg(node: c, depth: depth, start: a, end: a + s, hue: h))
                walk(c, depth: depth + 1, start: a, span: s, hue: h)
                a += s
            }
        }
        walk(node, depth: 1, start: 0, span: 1, hue: nil)
        return out
    }

    var body: some View {
        let segs = segments()
        GeometryReader { g in
            let side = min(g.size.width, g.size.height)
            let center = CGPoint(x: g.size.width / 2, y: g.size.height / 2)
            let inner = side * 0.17, ring = (side / 2 - inner) / 3.2
            Canvas { ctx, _ in
                for s in segs {
                    let r0 = inner + CGFloat(s.depth - 1) * ring, r1 = r0 + ring - 2
                    var p = Path()
                    let a0 = Angle.radians(s.start * 2 * .pi - .pi / 2), a1 = Angle.radians(s.end * 2 * .pi - .pi / 2)
                    p.addArc(center: center, radius: r1, startAngle: a0, endAngle: a1, clockwise: false)
                    p.addArc(center: center, radius: r0, startAngle: a1, endAngle: a0, clockwise: true)
                    p.closeSubpath()
                    let isHover = hover === s.node
                    let sat = Theme.playful ? 0.62 - Double(s.depth) * 0.1 : 0.0
                    let bri = 0.88 - Double(s.depth) * 0.07
                    ctx.fill(p, with: .color(Color(hue: s.hue, saturation: sat, brightness: isHover ? bri + 0.1 : bri)))
                    ctx.stroke(p, with: .color(Color(nsColor: .windowBackgroundColor)), lineWidth: 1.2)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                if case .active(let pt) = phase { hover = hit(pt, center, inner, ring, segs) } else { hover = nil }
            }
            .gesture(SpatialTapGesture().onEnded { v in if let n = hit(v.location, center, inner, ring, segs) { tap(n) } })
            .contextMenu { if let h = hover, h.url.lastPathComponent != "…smaller" { FileMenu(urls: [h.url]) } }
        }
    }

    private func hit(_ pt: CGPoint, _ c: CGPoint, _ inner: CGFloat, _ ring: CGFloat, _ segs: [Seg]) -> SizeNode? {
        let dx = pt.x - c.x, dy = pt.y - c.y
        let r = sqrt(dx * dx + dy * dy)
        guard r > inner else { return nil }
        let depth = Int((r - inner) / ring) + 1
        var ang = atan2(dy, dx) + .pi / 2
        if ang < 0 { ang += 2 * .pi }
        let f = ang / (2 * .pi)
        return segs.first { $0.depth == depth && f >= $0.start && f < $0.end }?.node
    }
}

struct SizeList: View {
    let node: SizeNode
    let onOpen: (SizeNode) -> Void
    @EnvironmentObject var model: AppModel
    var body: some View {
        List(node.children) { c in
            HStack(spacing: 8) {
                Thumb(url: c.url, side: 20, iconOnly: true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(c.name).lineLimit(1)
                    GeometryReader { g in
                        Capsule().fill(Color.accentColor.opacity(0.7)).frame(width: max(2, g.size.width * CGFloat(c.size) / CGFloat(max(node.size, 1))))
                    }.frame(height: 4)
                }
                Text(Fmt.size(c.size)).monospacedDigit().foregroundStyle(.secondary).frame(width: 74, alignment: .trailing)
            }
            .contentShape(Rectangle())
            .onTapGesture { if NSApp.currentEvent?.clickCount == 2 { if c.children.isEmpty { model.reveal(c.url) } else { onOpen(c) } } }
            .contextMenu {
                if c.url.lastPathComponent != "…smaller" {
                    Button("Show in Spyglass") { model.reveal(c.url) }
                    Button("Move to Trash", role: .destructive) { FileOps.trash([c.url], kind: .cleanup); DiskScan.shared.scan() }
                }
            }
        }
    }
}

struct DiskUsageView: View {
    @StateObject private var scan = DiskScan.shared
    @ObservedObject private var growth = GrowthTracker.shared
    var body: some View {
        let disk = Places.startupDisk()
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(title: "Disk Usage", subtitle: Places.displayPath(scan.target), symbol: "internaldrive.fill", tint: .indigo) {
                HStack {
                    Button("Choose Folder…") { if let u = pickFolder() { scan.scan(u) } }
                    Button { scan.scan() } label: { Image(systemName: "arrow.clockwise") }.disabled(scan.scanning)
                }
            }
            HStack(spacing: 14) {
                stat("Capacity", Fmt.size(disk.total))
                stat("Used", Fmt.size(disk.total - disk.free))
                stat("Free", Fmt.size(disk.free))
                stat("Purgeable", Fmt.size(max(0, disk.important - disk.free)))
            }
            if scan.scanning { ProgressView("Measuring \(Fmt.count(scan.scanned)) items…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if let r = scan.focus {
                HStack {
                    if r.parent != nil { Button { scan.focus = r.parent } label: { Label("Up", systemImage: "arrow.up") } }
                    Text(r.name).font(.headline); Text(Fmt.size(r.size)).foregroundStyle(.secondary)
                }
                SizeList(node: r) { scan.focus = $0 }
            } else { Button("Measure \(Places.displayPath(scan.target))") { scan.scan() }.buttonStyle(.borderedProminent) ; Spacer() }
        }
        .padding(20)
        .onAppear { if scan.root == nil && !scan.scanning { scan.scan() } }
    }
    func stat(_ t: String, _ v: String) -> some View {
        Card(padding: 12) { VStack(alignment: .leading, spacing: 2) { Text(t).font(.caption).foregroundStyle(.secondary); Text(v).font(.title3.weight(.semibold)).monospacedDigit() } }
    }
}

// MARK: - What Grew

/// Records top-level folder sizes once a day (kept 90 days) to show what grew.
@MainActor final class GrowthTracker: ObservableObject {
    static let shared = GrowthTracker()
    @Published var snapshots: [String: [String: Int64]] = [:]   // day -> path -> size
    private var file: URL { Places.support.appendingPathComponent("growth.json") }
    private let dayFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f }()

    init() {
        if let d = try? Data(contentsOf: file), let s = try? JSONDecoder().decode([String: [String: Int64]].self, from: d) { snapshots = s }
    }

    func record(_ root: SizeNode) {
        guard root.url.standardizedFileURL == Places.home.standardizedFileURL else { return }
        var day: [String: Int64] = [:]
        for c in root.children where c.isDir { day[c.url.path] = c.size }
        for c in root.children where c.url.lastPathComponent == "Library" { for g in c.children where g.isDir { day[g.url.path] = g.size } }
        snapshots[dayFmt.string(from: Date())] = day
        let keep = Set(snapshots.keys.sorted().suffix(90))
        snapshots = snapshots.filter { keep.contains($0.key) }
        try? JSONEncoder().encode(snapshots).write(to: file)
    }

    func measureIfDue() {
        let today = dayFmt.string(from: Date())
        guard snapshots[today] == nil, !DiskScan.shared.scanning, DiskScan.shared.root == nil else { return }
        DiskScan.shared.scan(Places.home)
    }

    func growth(days: Int) -> [(String, Int64)] {
        let keys = snapshots.keys.sorted()
        guard let latest = keys.last, let now = snapshots[latest] else { return [] }
        let target = dayFmt.string(from: Date().addingTimeInterval(-Double(days) * 86400))
        guard let baseKey = keys.last(where: { $0 <= target }) ?? (keys.count > 1 ? keys.first : nil), baseKey != latest, let base = snapshots[baseKey] else { return [] }
        return now.compactMap { p, s in
            guard let b = base[p] else { return nil }
            let d = s - b
            return d > 1_000_000 ? (p, d) : nil
        }.sorted { $0.1 > $1.1 }
    }
}

struct GrewCard: View {
    @ObservedObject var g = GrowthTracker.shared
    @EnvironmentObject var model: AppModel
    @State private var month = false
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(month ? "What Grew This Month" : "What Grew This Week", systemImage: "chart.line.uptrend.xyaxis").font(.headline)
                    Spacer()
                    Picker("", selection: $month) { Text("Week").tag(false); Text("Month").tag(true) }.pickerStyle(.segmented).frame(width: 120)
                }
                let rows = g.growth(days: month ? 30 : 7).prefix(5)
                if rows.isEmpty {
                    Text(g.snapshots.count < 2 ? "Spyglass measures your folders once a day. Check back tomorrow." : "Nothing grew noticeably.").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(Array(rows), id: \.0) { p, d in
                    HStack {
                        Image(systemName: "folder.fill").foregroundStyle(.blue)
                        Text(Places.displayPath(URL(fileURLWithPath: p))).lineLimit(1)
                        Spacer()
                        Text("+\(Fmt.size(d))").foregroundStyle(.orange).monospacedDigit()
                    }.font(.callout)
                    .onTapGesture { model.open(folder: URL(fileURLWithPath: p)) }
                }
            }
        }
        .task { g.measureIfDue() }
    }
}
