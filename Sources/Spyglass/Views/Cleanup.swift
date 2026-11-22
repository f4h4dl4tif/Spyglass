import SwiftUI
import Vision

struct CleanItem: Identifiable, Hashable {
    let url: URL
    let size: Int64
    let date: Date
    var safe = true
    var note: String?
    var id: URL { url }
}

struct CleanGroup: Identifiable {
    let id: String
    let title: String
    let detail: String
    let symbol: String
    let color: Color
    var items: [CleanItem]
    var bytes: Int64 { items.reduce(0) { $0 + $1.size } }
}

@MainActor final class CleanupScanner: ObservableObject {
    static let shared = CleanupScanner()
    @Published var groups: [CleanGroup] = []
    @Published var scanning = false
    @Published var selected = Set<URL>()
    @Published var unusedApps: [CleanItem] = []
    private var scannedAt: Date?

    var total: Int64 { groups.reduce(0) { $0 + $1.bytes } }

    func scanIfNeeded() { if scannedAt == nil || Date().timeIntervalSince(scannedAt!) > 600 { Task { await scan() } } }

    func scan() async {
        guard !scanning else { return }
        scanning = true
        let now = Date()
        let month = Spotlight.iso(now.addingTimeInterval(-30 * 86400))
        let week = Spotlight.iso(now.addingTimeInterval(-3 * 86400))

        let shots = await Spotlight.run("kMDItemIsScreenCapture == 1 && kMDItemFSContentChangeDate < \(month)", limit: 5000).hits
        let installers = await Spotlight.run("(kMDItemFSName == \"*.dmg\"c || kMDItemFSName == \"*.pkg\"c || kMDItemFSName == \"*.iso\"c) && kMDItemFSContentChangeDate < \(week)", limit: 2000).hits
        let recordings = await Spotlight.run("kMDItemContentTypeTree == \"public.movie\" && kMDItemFSName == \"Screen Recording*\"c && kMDItemFSSize > 50000000 && kMDItemFSContentChangeDate < \(month)", limit: 1000).hits

        let built = await Task.detached { () -> ([CleanGroup], [CleanItem]) in
            func items(_ hits: [Spotlight.Hit]) -> [CleanItem] { hits.map { CleanItem(url: $0.url, size: $0.size, date: $0.date) } }
            var gs: [CleanGroup] = []
            // Forgotten downloads: 90+ days in Downloads, never opened.
            var forgotten: [CleanItem] = []
            let keys: Set<URLResourceKey> = [.addedToDirectoryDateKey, .totalFileAllocatedSizeKey, .isDirectoryKey, .isPackageKey]
            let limit = now.addingTimeInterval(-90 * 86400)
            for u in (try? FileManager.default.contentsOfDirectory(at: Places.downloads, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])) ?? [] {
                guard let v = try? u.resourceValues(forKeys: keys) else { continue }
                let added = v.addedToDirectoryDate ?? .distantFuture
                guard added < limit, Meta.lastUsed(u) == nil || Meta.lastUsed(u)! < added.addingTimeInterval(60) else { continue }
                let size = (v.isDirectory ?? false) ? Sizer.size(of: u) : Int64(v.totalFileAllocatedSize ?? 0)
                forgotten.append(CleanItem(url: u, size: size, date: added))
            }
            gs.append(CleanGroup(id: "forgotten", title: "Forgotten Downloads", detail: "In Downloads for 90+ days and never opened", symbol: "arrow.down.circle", color: .green, items: forgotten.sorted { $0.size > $1.size }))
            gs.append(CleanGroup(id: "installers", title: "Old Installers", detail: "Disk images and installer packages you already used", symbol: "shippingbox", color: .brown, items: items(installers)))
            gs.append(CleanGroup(id: "screenshots", title: "Old Screenshots", detail: "Screenshots older than a month", symbol: "camera.viewfinder", color: .blue, items: items(shots)))
            gs.append(CleanGroup(id: "recordings", title: "Big Old Screen Recordings", detail: "Over 50 MB and older than a month", symbol: "record.circle", color: .red, items: items(recordings)))
            // Caches
            var caches: [CleanItem] = []
            let cacheDir = Places.library.appendingPathComponent("Caches")
            for u in (try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil, options: [])) ?? [] {
                let s = Sizer.size(of: u)
                guard s > 20_000_000 else { continue }
                let n = u.lastPathComponent
                let check = n.hasPrefix("com.apple.") || n.contains("CloudKit") || n.contains("Spotlight") || n.contains("keychain")
                caches.append(CleanItem(url: u, size: s, date: .distantPast, safe: !check, note: check ? "Check First" : "Safe"))
            }
            gs.append(CleanGroup(id: "caches", title: "App Caches", detail: "Apps rebuild these when needed", symbol: "shippingbox.fill", color: .orange, items: caches.sorted { $0.size > $1.size }))
            // Developer junk
            var dev: [CleanItem] = []
            for rel in ["Library/Developer/Xcode/DerivedData", "Library/Developer/Xcode/iOS DeviceSupport", "Library/Developer/Xcode/Archives", "Library/Caches/Homebrew", ".npm/_cacache", "Library/Caches/pip", ".gradle/caches", ".cocoapods/repos"] {
                let u = Places.home.appendingPathComponent(rel)
                guard FileManager.default.fileExists(atPath: u.path) else { continue }
                let s = Sizer.size(of: u)
                if s > 10_000_000 { dev.append(CleanItem(url: u, size: s, date: .distantPast, safe: !rel.contains("Archives"), note: rel.contains("Archives") ? "Check First" : "Safe")) }
            }
            if !dev.isEmpty { gs.append(CleanGroup(id: "dev", title: "Developer Data", detail: "Build files and package caches that rebuild themselves", symbol: "hammer", color: .purple, items: dev)) }
            // Unused apps (informational)
            var unused: [CleanItem] = []
            let half = now.addingTimeInterval(-180 * 86400)
            for u in (try? FileManager.default.contentsOfDirectory(at: Places.applications, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [] where u.pathExtension == "app" {
                let id = Bundle(url: u)?.bundleIdentifier ?? ""
                if id.hasPrefix("com.apple.") { continue }
                let last = Meta.lastUsed(u)
                if last == nil || last! < half { unused.append(CleanItem(url: u, size: 0, date: last ?? .distantPast)) }
            }
            return (gs, unused)
        }.value
        groups = built.0
        unusedApps = built.1
        selected = Set(groups.filter { $0.id != "caches" && $0.id != "dev" }.flatMap { $0.items.map(\.url) })
        selected.formUnion(groups.filter { $0.id == "caches" || $0.id == "dev" }.flatMap { $0.items.filter(\.safe).map(\.url) })
        scannedAt = Date()
        scanning = false
    }

    func trash(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let b = FileOps.trash(urls, kind: .cleanup, title: "Cleaned up \(urls.count) item\(urls.count == 1 ? "" : "s")")
        let set = Set(urls)
        for i in groups.indices { groups[i].items.removeAll { set.contains($0.url) } }
        selected.subtract(set)
        ActivityLog.shared.show("Freed \(Fmt.size(b)) — it's in the Trash", entry: ActivityLog.shared.entries.first?.id)
    }

    func cleanSafe() {
        trash(groups.filter { $0.id == "caches" || $0.id == "dev" }.flatMap { $0.items.filter(\.safe).map(\.url) })
    }
}

struct CleanupView: View {
    @StateObject private var s = CleanupScanner.shared
    @ObservedObject private var log = ActivityLog.shared
    @EnvironmentObject var model: AppModel
    @State private var expanded: Set<String> = []

    var selectedBytes: Int64 { s.groups.flatMap(\.items).filter { s.selected.contains($0.url) }.reduce(0) { $0 + $1.size } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(title: "Clean Up", subtitle: "Everything goes to the Trash and can be put back.", symbol: "sparkles", tint: .pink) {
                    Button { Task { await s.scan() } } label: { Label("Rescan", systemImage: "arrow.clockwise") }.disabled(s.scanning)
                }
                Card {
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Ready to reclaim").foregroundStyle(.secondary)
                            Text(s.scanning ? "Scanning…" : Fmt.size(selectedBytes)).font(.system(size: 36, weight: .bold)).monospacedDigit().contentTransition(.numericText())
                            Text("of \(Fmt.size(s.total)) found").font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 8) {
                            Button { s.trash(Array(s.selected)) } label: { Label("Move to Trash", systemImage: "trash").frame(minWidth: 140) }
                                .buttonStyle(.borderedProminent).controlSize(.large).disabled(s.selected.isEmpty || s.scanning)
                            Button("Clean Safe Items Only") { s.cleanSafe() }.disabled(s.scanning)
                        }
                    }
                }
                if s.scanning && s.groups.isEmpty { ProgressView("Looking for things you can safely remove…").frame(maxWidth: .infinity).padding(40) }
                ForEach(s.groups) { g in groupCard(g) }
                if !s.unusedApps.isEmpty {
                    Card {
                        HStack {
                            Image(systemName: "app.badge.clock").font(.title2).foregroundStyle(.teal)
                            VStack(alignment: .leading) { Text("Unused Apps").font(.headline); Text("\(s.unusedApps.count) apps not opened in 6 months").foregroundStyle(.secondary).font(.callout) }
                            Spacer()
                            Button("Review in Uninstaller") { model.show(.uninstaller) }
                        }
                    }
                }
                undoSection
            }.padding(22)
        }
        .task { s.scanIfNeeded() }
    }

    func groupCard(_ g: CleanGroup) -> some View {
        let open = expanded.contains(g.id)
        let allOn = !g.items.isEmpty && g.items.allSatisfy { s.selected.contains($0.url) }
        return Card(padding: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Toggle("", isOn: Binding(get: { allOn }, set: { on in
                        for i in g.items { if on { s.selected.insert(i.url) } else { s.selected.remove(i.url) } }
                    })).toggleStyle(.checkbox).labelsHidden().disabled(g.items.isEmpty)
                    Image(systemName: g.symbol).font(.title3).foregroundStyle(Theme.playful ? g.color : .secondary).frame(width: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(g.title).font(.headline)
                        Text(g.items.isEmpty ? "Nothing to clean" : "\(g.items.count) items · \(g.detail)").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(Fmt.size(g.bytes)).font(.title3.weight(.semibold)).monospacedDigit()
                    Button { withAnimation(.snappy) { if open { expanded.remove(g.id) } else { expanded.insert(g.id) } } } label: {
                        Image(systemName: "chevron.right").rotationEffect(.degrees(open ? 90 : 0))
                    }.buttonStyle(.borderless).disabled(g.items.isEmpty)
                }.padding(14)
                if open {
                    Divider()
                    LazyVStack(spacing: 0) {
                        ForEach(g.items.prefix(300)) { item in
                            HStack(spacing: 10) {
                                Toggle("", isOn: Binding(get: { s.selected.contains(item.url) }, set: { if $0 { s.selected.insert(item.url) } else { s.selected.remove(item.url) } }))
                                    .toggleStyle(.checkbox).labelsHidden()
                                Thumb(url: item.url, side: 26)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.url.lastPathComponent).lineLimit(1)
                                    Text(Places.displayPath(item.url.deletingLastPathComponent())).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                if let n = item.note { Text(n).font(.caption).padding(.horizontal, 6).padding(.vertical, 2).background((item.safe ? Color.green : .orange).opacity(0.18), in: Capsule()) }
                                if item.date != .distantPast { Text(Fmt.ago(item.date)).font(.caption).foregroundStyle(.secondary).frame(width: 90, alignment: .trailing) }
                                Text(Fmt.size(item.size)).monospacedDigit().foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
                                Button { FileOps.reveal([item.url]) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.borderless).help("Show in Finder")
                            }
                            .padding(.horizontal, 14).padding(.vertical, 5)
                            .contextMenu { FileMenu(urls: [item.url]) }
                        }
                    }.padding(.vertical, 6)
                }
            }
        }
    }

    var undoSection: some View {
        let sessions = log.entries.filter { $0.kind == .cleanup || $0.kind == .uninstall }.prefix(8)
        return Group {
            if !sessions.isEmpty {
                Text("Undo Cleanup").font(.headline).padding(.top, 6)
                Card(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(Array(sessions)) { e in
                            HStack {
                                Image(systemName: e.symbol).foregroundStyle(.secondary)
                                VStack(alignment: .leading) { Text(e.title); Text(Fmt.when(e.date)).font(.caption).foregroundStyle(.secondary) }
                                Spacer()
                                if e.bytes > 0 { Text(Fmt.size(e.bytes)).foregroundStyle(.secondary) }
                                if e.undone { Text("Put back").foregroundStyle(.secondary).font(.callout) }
                                else { Button("Put Back") { log.undo(e.id); Task { await CleanupScanner.shared.scan() } } }
                            }.padding(.horizontal, 14).padding(.vertical, 8)
                            Divider()
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Duplicates

@MainActor final class DuplicateFinder: ObservableObject {
    static let shared = DuplicateFinder()
    struct DupGroup: Identifiable { let id = UUID(); var files: [CleanItem]; let similar: Bool; var blurry = false; var waste: Int64 { files.dropFirst().reduce(0) { $0 + $1.size } } }
    @Published var groups: [DupGroup] = []
    @Published var running = false
    @Published var progress = 0.0
    @Published var status = ""
    @Published var marked = Set<URL>()
    @Published var scope = Places.home
    private var cancel = false

    func stop() { cancel = true }

    func scan(similarPhotos: Bool, blurry: Bool = false) async {
        running = true; cancel = false; progress = 0; groups = []; marked = []
        status = "Finding candidates…"
        let hits = await Spotlight.run("kMDItemFSSize > 102400 && kMDItemContentType != \"public.folder\" && kMDItemContentType != \"com.apple.application-bundle\"",
                                       scopes: [scope.path], sort: NSMetadataItemFSSizeKey, limit: 60000).hits
        let result = await Task.detached { [weak self] () -> [DupGroup] in
            var bySize: [Int64: [Spotlight.Hit]] = [:]
            for h in hits where !h.url.path.contains("/Library/") && !h.url.path.contains(".app/") { bySize[h.size, default: []].append(h) }
            let cands = bySize.values.filter { $0.count > 1 }
            var out: [DupGroup] = []
            for (i, group) in cands.enumerated() {
                if await self?.cancel == true { break }
                if i % 20 == 0 { let p = Double(i) / Double(max(cands.count, 1)); await MainActor.run { self?.progress = p * (similarPhotos ? 0.6 : 1); self?.status = "Comparing \(i) of \(cands.count) size groups" } }
                var byHead: [String: [Spotlight.Hit]] = [:]
                for h in group { if let k = Sizer.sha256(h.url, limit: 65536) { byHead[k, default: []].append(h) } }
                for g2 in byHead.values where g2.count > 1 {
                    var byFull: [String: [Spotlight.Hit]] = [:]
                    for h in g2 { if let k = h.size <= 65536 ? "small" : Sizer.sha256(h.url) { byFull[k, default: []].append(h) } }
                    for g3 in byFull.values where g3.count > 1 {
                        out.append(DupGroup(files: DuplicateFinder.rank(g3.map { CleanItem(url: $0.url, size: $0.size, date: $0.date) }), similar: false))
                    }
                }
            }
            if similarPhotos {
                await MainActor.run { self?.status = "Looking for look-alike photos…" }
                let imgs = hits.filter { FileKind.of($0.url, isDirectory: false) == .image && !$0.url.path.contains("/Library/") }.prefix(1500)
                var prints: [(Spotlight.Hit, VNFeaturePrintObservation)] = []
                for (i, h) in imgs.enumerated() {
                    if await self?.cancel == true { break }
                    if i % 25 == 0 { let p = 0.6 + 0.3 * Double(i) / Double(max(imgs.count, 1)); await MainActor.run { self?.progress = p } }
                    autoreleasepool {
                        let req = VNGenerateImageFeaturePrintRequest()
                        let handler = VNImageRequestHandler(url: h.url)
                        if (try? handler.perform([req])) != nil, let o = req.results?.first { prints.append((h, o)) }
                    }
                }
                var used = Set<URL>()
                let exact = Set(out.flatMap { $0.files.map(\.url) })
                for i in prints.indices where !used.contains(prints[i].0.url) && !exact.contains(prints[i].0.url) {
                    var cluster = [prints[i].0]
                    for j in (i + 1)..<prints.count where !used.contains(prints[j].0.url) && !exact.contains(prints[j].0.url) {
                        var d: Float = 0
                        if (try? prints[i].1.computeDistance(&d, to: prints[j].1)) != nil, d < 0.35 { cluster.append(prints[j].0); used.insert(prints[j].0.url) }
                    }
                    if cluster.count > 1 {
                        used.insert(prints[i].0.url)
                        out.append(DupGroup(files: DuplicateFinder.rank(cluster.map { CleanItem(url: $0.url, size: $0.size, date: $0.date) }), similar: true))
                    }
                }
            }
            out.sort { $0.waste > $1.waste }
            if blurry {
                await MainActor.run { self?.status = "Looking for blurry photos…" }
                let imgs = hits.filter { ["jpg", "jpeg", "heic", "png"].contains($0.url.pathExtension.lowercased()) && !$0.url.path.contains("/Library/") && $0.size > 200_000 }.prefix(3000)
                var soft: [CleanItem] = []
                for (i, h) in imgs.enumerated() {
                    if await self?.cancel == true { break }
                    if i % 40 == 0 { let p = 0.9 + 0.1 * Double(i) / Double(max(imgs.count, 1)); await MainActor.run { self?.progress = p } }
                    if let v = autoreleasepool(invoking: { Blur.sharpness(h.url) }), v < 60 { soft.append(CleanItem(url: h.url, size: h.size, date: h.date, note: String(format: "Sharpness %.0f", v))) }
                }
                if !soft.isEmpty { out.insert(DupGroup(files: soft, similar: true, blurry: true), at: 0) }
            }
            return out
        }.value
        groups = result
        marked = Set(result.filter { !$0.similar }.flatMap { $0.files.dropFirst().map(\.url) })
        progress = 1; running = false
        status = groups.isEmpty ? "No duplicates found" : "\(groups.count) groups · \(Fmt.size(groups.reduce(0) { $0 + $1.waste })) wasted"
        NSApp.dockTile.badgeLabel = nil
    }

    /// Keep-best: the copy outside Downloads/Desktop with the shortest path, oldest first.
    nonisolated static func rank(_ files: [CleanItem]) -> [CleanItem] {
        files.sorted { a, b in
            func score(_ u: URL) -> Int { (u.path.contains("/Downloads/") ? 2 : 0) + (u.path.contains("/Desktop/") ? 1 : 0) + (u.lastPathComponent.contains(" copy") || u.lastPathComponent.contains("(1)") ? 3 : 0) }
            let sa = score(a.url), sb = score(b.url)
            if sa != sb { return sa < sb }
            if a.date != b.date { return a.date < b.date }
            return a.url.path.count < b.url.path.count
        }
    }

    func trashMarked() {
        let urls = Array(marked)
        guard !urls.isEmpty else { return }
        FileOps.trash(urls, kind: .cleanup, title: "Removed \(urls.count) duplicate\(urls.count == 1 ? "" : "s")")
        let set = Set(urls)
        groups = groups.compactMap { g in var g = g; g.files.removeAll { set.contains($0.url) }; return g.files.count > 1 ? g : nil }
        marked = []
    }
}

struct DuplicatesView: View {
    @StateObject private var f = DuplicateFinder.shared
    @State private var similar = false
    @State private var blurry = false
    @State private var compare: DuplicateFinder.DupGroup?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Duplicates", subtitle: "Exact copies by SHA-256, plus look-alike photos with on-device Vision", symbol: "square.on.square", tint: .purple) {
                HStack {
                    Menu(Places.displayPath(f.scope)) {
                        Button("Home folder") { f.scope = Places.home }
                        Button("Downloads") { f.scope = Places.downloads }
                        Button("Pictures") { f.scope = Places.pictures }
                        Button("Choose Folder…") { if let u = pickFolder() { f.scope = u } }
                    }.frame(width: 160)
                    Toggle("Look-alike photos", isOn: $similar).toggleStyle(.checkbox)
                    Toggle("Blurry photos", isOn: $blurry).toggleStyle(.checkbox).help("Finds out-of-focus or shaky shots. Portraits with a soft background are left out.")
                    if f.running { Button("Stop") { f.stop() } }
                    else { Button("Scan") { Task { await f.scan(similarPhotos: similar, blurry: blurry) } }.buttonStyle(.borderedProminent) }
                }
            }.padding(20)
            if f.running { ProgressView(value: f.progress) { Text(f.status).font(.callout) }.padding(.horizontal, 20).padding(.bottom, 10) }
            else if !f.status.isEmpty {
                HStack {
                    Text(f.status).foregroundStyle(.secondary)
                    Spacer()
                    Button("Select All Extra Copies") { f.marked = Set(f.groups.flatMap { $0.files.dropFirst().map(\.url) }) }
                    Button { f.trashMarked() } label: { Label("Move \(f.marked.count) to Trash", systemImage: "trash") }.disabled(f.marked.isEmpty)
                }.padding(.horizontal, 20).padding(.bottom, 10)
            }
            Divider()
            if f.groups.isEmpty && !f.running {
                EmptyState(symbol: "square.on.square", title: f.status.isEmpty ? "Find duplicate files" : "All clear", message: "Spyglass compares file sizes first, then fingerprints. The best copy is kept automatically; you can change which.")
            } else {
                List {
                    ForEach(f.groups) { g in
                        Section {
                            ForEach(Array(g.files.enumerated()), id: \.element.id) { i, file in
                                HStack(spacing: 10) {
                                    Toggle("", isOn: Binding(get: { f.marked.contains(file.url) }, set: { if $0 { f.marked.insert(file.url) } else { f.marked.remove(file.url) } }))
                                        .toggleStyle(.checkbox).labelsHidden()
                                    Thumb(url: file.url, side: 34)
                                    VStack(alignment: .leading, spacing: 1) {
                                        HStack { Text(file.url.lastPathComponent).lineLimit(1); if let n = file.note { Text(n).font(.caption2).foregroundStyle(.orange) }; if i == 0 && !g.blurry { Text("Keep").font(.caption2.weight(.semibold)).padding(.horizontal, 5).padding(.vertical, 1).background(.green.opacity(0.2), in: Capsule()) } }
                                        Text(Places.displayPath(file.url.deletingLastPathComponent())).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                    Text(Fmt.when(file.date)).font(.caption).foregroundStyle(.secondary)
                                    Button { FileOps.reveal([file.url]) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.borderless)
                                }
                                .contextMenu { FileMenu(urls: [file.url]) }
                            }
                        } header: {
                            HStack {
                                Text(g.blurry ? "Blurry photos · \(g.files.count)" : g.similar ? "Look-alike photos" : "\(g.files.count) identical copies")
                                if !g.blurry { Text("· \(Fmt.size(g.files.first?.size ?? 0)) each").foregroundStyle(.secondary) }
                                Spacer()
                                Button("Compare") { compare = g }.buttonStyle(.borderless)
                            }
                        }
                    }
                }
            }
        }
        .sheet(item: $compare) { g in CompareSheet(group: g) }
    }
}

struct CompareSheet: View {
    let group: DuplicateFinder.DupGroup
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(group.files) { f in
                        VStack(spacing: 6) {
                            Thumb(url: f.url, side: 260)
                            Text(f.url.lastPathComponent).font(.headline).lineLimit(1)
                            Text(Places.displayPath(f.url.deletingLastPathComponent())).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            Text("\(Fmt.size(f.size)) · \(Fmt.when(f.date))").font(.caption)
                        }.frame(width: 280)
                    }
                }.padding()
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }.padding()
        }.frame(minWidth: 640, minHeight: 420)
    }
}

@MainActor func pickFolder(_ message: String = "Choose a folder") -> URL? {
    let p = NSOpenPanel()
    p.canChooseDirectories = true; p.canChooseFiles = false; p.message = message
    return p.runModal() == .OK ? p.url : nil
}

@MainActor func pickFiles(_ types: [String] = [], multiple: Bool = true) -> [URL] {
    let p = NSOpenPanel()
    p.allowsMultipleSelection = multiple; p.canChooseFiles = true; p.canChooseDirectories = false
    if !types.isEmpty { p.allowedContentTypes = types.compactMap { UTType(filenameExtension: $0) } }
    return p.runModal() == .OK ? p.urls : []
}

import UniformTypeIdentifiers

// MARK: - Large files

struct LargeFilesView: View {
    @State private var minMB = 500.0
    @State private var hits: [Spotlight.Hit] = []
    @State private var selection = Set<URL>()
    @State private var loading = false
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Large Files", subtitle: "\(hits.count) files over \(Fmt.size(Int64(minMB * 1e6))) · \(Fmt.size(hits.reduce(0) { $0 + $1.size })) total", symbol: "doc.badge.arrow.up", tint: .orange) {
                HStack {
                    Text("Over").foregroundStyle(.secondary)
                    Slider(value: $minMB, in: 50...5000, step: 50).frame(width: 160)
                    Text(Fmt.size(Int64(minMB * 1e6))).monospacedDigit().frame(width: 70)
                }
            }.padding(20)
            HStack {
                Spacer()
                let drives = Places.volumes()
                if !drives.isEmpty {
                    Menu("Move to Drive") {
                        ForEach(drives) { d in Button("\(d.name) (\(Fmt.size(d.free)) free)") { FileOps.move(Array(selection), into: d.url, copy: false, title: "Moved \(selection.count) items to \(d.name)"); reload() } }
                    }.frame(width: 140).disabled(selection.isEmpty)
                }
                Button { FileOps.trash(Array(selection), kind: .cleanup); hits.removeAll { selection.contains($0.url) }; selection = [] } label: { Label("Move to Trash", systemImage: "trash") }.disabled(selection.isEmpty)
            }.padding(.horizontal, 20).padding(.bottom, 8)
            Divider()
            if loading { ProgressView().frame(maxHeight: .infinity) }
            else {
                Table(hits, selection: $selection) {
                    TableColumn("Name") { h in HStack { Thumb(url: h.url, side: 24); VStack(alignment: .leading) { Text(h.name).lineLimit(1); Text(Places.displayPath(h.url.deletingLastPathComponent())).font(.caption).foregroundStyle(.secondary).lineLimit(1) } } }
                    TableColumn("Size") { Text(Fmt.size($0.size)).monospacedDigit() }.width(90)
                    TableColumn("Last Opened") { h in Text(Meta.lastUsed(h.url).map(Fmt.ago) ?? "Never").foregroundStyle(.secondary) }.width(120)
                }
                .contextMenu(forSelectionType: URL.self) { FileMenu(urls: Array($0)) } primaryAction: { $0.forEach { FileOps.reveal([$0]) } }
            }
        }
        .task(id: Int(minMB)) { try? await Task.sleep(for: .milliseconds(250)); reload() }
    }
    func reload() {
        loading = hits.isEmpty
        Task {
            hits = await Spotlight.run("kMDItemFSSize > \(Int64(minMB * 1e6))", sort: NSMetadataItemFSSizeKey, limit: 800).hits.filter { FileManager.default.fileExists(atPath: $0.url.path) }
            loading = false
        }
    }
}

// MARK: - Activity

struct ActivityView: View {
    @ObservedObject var log = ActivityLog.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Activity", subtitle: "Every move, rename, organize, cleanup and uninstall. Each can be undone.", symbol: "clock.arrow.circlepath", tint: .gray) {
                Button("Clear History") { log.clear() }.disabled(log.entries.isEmpty)
            }.padding(20)
            Divider()
            if log.entries.isEmpty { EmptyState(symbol: "clock.arrow.circlepath", title: "No activity yet") }
            else {
                List(log.entries) { e in
                    HStack(spacing: 12) {
                        Image(systemName: e.symbol).frame(width: 22).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.title).strikethrough(e.undone)
                            Text("\(Fmt.when(e.date)) · \(e.moves.count) item\(e.moves.count == 1 ? "" : "s")" + (e.bytes > 0 ? " · \(Fmt.size(e.bytes))" : "")).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if e.undone { Text("Undone").foregroundStyle(.secondary).font(.callout) }
                        else { Button(e.kind == .trash || e.kind == .cleanup || e.kind == .uninstall ? "Put Back" : "Undo") { log.undo(e.id) } }
                    }.padding(.vertical, 3)
                }
            }
        }
    }
}
