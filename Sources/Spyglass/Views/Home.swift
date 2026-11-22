import SwiftUI

struct HomeView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var lib = LibraryStats.shared
    @StateObject private var cleanup = CleanupScanner.shared
    @AppStorage("hideGettingStarted") private var hideGS = false
    @AppStorage("theme") private var theme = "playful"
    @State private var recent: [LibraryKind: [Spotlight.Hit]] = [:]
    @State private var downloads: [Spotlight.Hit] = []
    @State private var sources: [(String, Int)] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if !hideGS { GettingStartedCard() }
                storageCard
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 14)], spacing: 14) {
                    ForEach(LibraryKind.allCases) { k in categoryCard(k) }
                }
                HStack(alignment: .top, spacing: 14) {
                    freeUpCard
                    VStack(spacing: 14) { GrewCard(); sourcesCard }
                }
                recentDownloadsCard
            }
            .padding(22)
        }
        .task {
            lib.refreshIfNeeded()
            cleanup.scanIfNeeded()
            for k in [LibraryKind.images, .videos, .music, .documents, .screenshots] {
                recent[k] = await Spotlight.run(k.query, scopes: k.scopes, limit: 4).hits
            }
            downloads = await Spotlight.run("kMDItemPath == \"\(Places.downloads.path)/*\"", scopes: [Places.downloads.path], sort: "kMDItemDateAdded", limit: 12).hits
            let froms = await Spotlight.run("kMDItemWhereFroms == \"*\"", sort: "kMDItemDateAdded", limit: 600).hits
            let counts = await Task.detached { () -> [(String, Int)] in
                var c: [String: Int] = [:]
                for h in froms { if let n = Meta.sourceName(for: Meta.whereFroms(h.url)) { c[n, default: 0] += 1 } }
                return c.sorted { $0.value > $1.value }.prefix(6).map { ($0.key, $0.value) }
            }.value
            sources = counts
        }
    }

    var header: some View {
        let total = lib.counts.values.reduce(0, +), bytes = lib.bytes.values.reduce(0, +)
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(greeting).font(.largeTitle.weight(.bold))
                Text(total == 0 ? "Mapping your Mac…" : "\(Fmt.count(total)) files · \(Fmt.size(bytes)) in your library")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if lib.loading { ProgressView().controlSize(.small) }
            Button { Task { await lib.refresh() } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).help("Recount")
        }
    }

    var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        return h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : "Good evening"
    }

    var storageCard: some View {
        let disk = Places.startupDisk()
        let used = max(0, disk.total - disk.free)
        let segs = LibraryKind.allCases.map { ($0, lib.bytes[$0] ?? 0) }
        let known = segs.reduce(Int64(0)) { $0 + $1.1 }
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Macintosh HD").font(.headline)
                    Spacer()
                    Text("\(Fmt.size(disk.important)) available of \(Fmt.size(disk.total))").foregroundStyle(.secondary).font(.callout)
                }
                GeometryReader { g in
                    HStack(spacing: 1.5) {
                        ForEach(segs, id: \.0) { k, b in
                            Rectangle().fill(Theme.tint(k.fileKind).gradient).frame(width: max(0, g.size.width * CGFloat(b) / CGFloat(max(disk.total, 1))))
                        }
                        Rectangle().fill(Color.gray.opacity(0.5)).frame(width: max(0, g.size.width * CGFloat(max(0, used - known)) / CGFloat(max(disk.total, 1))))
                        Rectangle().fill(Color.primary.opacity(0.06))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }.frame(height: 14)
                HStack(spacing: 14) {
                    ForEach(segs.filter { $0.1 > 0 }, id: \.0) { k, b in
                        HStack(spacing: 5) { Circle().fill(Theme.tint(k.fileKind)).frame(width: 8, height: 8); Text(k.title).font(.caption); Text(Fmt.size(b)).font(.caption).foregroundStyle(.secondary) }
                    }
                    HStack(spacing: 5) { Circle().fill(.gray.opacity(0.5)).frame(width: 8, height: 8); Text("System & other").font(.caption) }
                }
            }
        }
    }

    func categoryCard(_ k: LibraryKind) -> some View {
        Button { model.show(.library(k)) } label: {
            Card(padding: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: k.symbol).font(.title3).foregroundStyle(theme == "minimal" ? .secondary : k.fileKind.color)
                        Text(k.title).font(.headline)
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                    HStack(alignment: .firstTextBaseline) {
                        Text(Fmt.count(lib.counts[k] ?? 0)).font(.title.weight(.semibold)).monospacedDigit().contentTransition(.numericText())
                        Text(Fmt.size(lib.bytes[k] ?? 0)).foregroundStyle(.secondary)
                    }
                    if theme != "minimal", let r = recent[k], !r.isEmpty {
                        HStack(spacing: 6) { ForEach(r.prefix(4)) { Thumb(url: $0.url, side: 38).clipShape(RoundedRectangle(cornerRadius: 6)) } }
                    } else if theme != "minimal" {
                        Color.clear.frame(height: 38)
                    }
                }
            }
        }.buttonStyle(.plain)
    }

    var freeUpCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack { Label("Free Up Space", systemImage: "sparkles").font(.headline); Spacer()
                    if cleanup.scanning { ProgressView().controlSize(.small) } }
                Text(cleanup.scanning ? "Looking for things you can safely remove…" : "\(Fmt.size(cleanup.total)) ready to reclaim")
                    .font(.title2.weight(.semibold))
                ForEach(cleanup.groups.filter { !$0.items.isEmpty }.prefix(5)) { g in
                    HStack { Image(systemName: g.symbol).foregroundStyle(g.color).frame(width: 18); Text(g.title); Spacer(); Text(Fmt.size(g.bytes)).foregroundStyle(.secondary).monospacedDigit() }
                        .font(.callout)
                }
                Button("Review in Clean Up") { model.show(.cleanup) }.buttonStyle(.borderedProminent)
            }
        }
    }

    var sourcesCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack { Label("Where Downloads Came From", systemImage: "arrow.down.circle").font(.headline); Spacer()
                    Button("All") { model.show(.downloadedFrom) }.buttonStyle(.borderless) }
                if sources.isEmpty { Text("No download sources yet").foregroundStyle(.secondary).font(.callout) }
                ForEach(sources, id: \.0) { n, c in
                    HStack { SourceIcon(name: n); Text(n); Spacer(); Text("\(c)").foregroundStyle(.secondary).monospacedDigit() }.font(.callout)
                }
            }
        }
    }

    var recentDownloadsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack { Label("Recent Downloads", systemImage: "clock").font(.headline); Spacer()
                    Button("Open Downloads") { model.open(folder: Places.downloads) }.buttonStyle(.borderless) }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(downloads) { h in
                            VStack(spacing: 4) {
                                Thumb(url: h.url, side: 76)
                                Text(h.name).font(.caption).lineLimit(1).frame(width: 90)
                            }
                            .onTapGesture { if NSApp.currentEvent?.clickCount == 2 { FileOps.open(h.url) } }
                            .onDrag { NSItemProvider(object: h.url as NSURL) }
                            .contextMenu { FileMenu(urls: [h.url]); Button("Show in Spyglass") { model.reveal(h.url) } }
                        }
                    }
                }
            }
        }
    }
}

struct GettingStartedCard: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("hideGettingStarted") private var hide = false
    @AppStorage("gsDone") private var doneRaw = ""
    struct Step { let id: String; let title: String; let detail: String; let page: Page? ; let action: (() -> Void)? }

    var steps: [Step] {
        [Step(id: "search", title: "Search in plain English", detail: "Try “screenshots from last week”", page: nil, action: { QuickSearchPanel.shared.toggle() }),
         Step(id: "cleanup", title: "Free up space", detail: "Review what's safe to remove", page: .cleanup, action: nil),
         Step(id: "map", title: "See your Space Map", detail: "Find what takes the room", page: .spaceMap, action: nil),
         Step(id: "health", title: "Check Mac Health", detail: "Score, readings, quick fixes", page: .health, action: nil),
         Step(id: "tools", title: "Try a tool", detail: "60+ on-device tools", page: .tools(nil), action: nil),
         Step(id: "tabs", title: "Browse with tabs", detail: "⌘T opens a new tab", page: nil, action: { AppModel.shared.addTab(Places.downloads) })]
    }

    var body: some View {
        let done = Set(doneRaw.split(separator: ",").map(String.init))
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Getting Started").font(.headline)
                    Text("\(done.count) of \(steps.count)").foregroundStyle(.secondary).font(.callout)
                    Spacer()
                    Button("Hide") { withAnimation { hide = true } }.buttonStyle(.borderless)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 10)], spacing: 10) {
                    ForEach(steps, id: \.id) { s in
                        HStack(spacing: 10) {
                            Image(systemName: done.contains(s.id) ? "checkmark.circle.fill" : "circle").foregroundStyle(done.contains(s.id) ? .green : .secondary).font(.title3)
                            VStack(alignment: .leading, spacing: 1) { Text(s.title).font(.callout.weight(.medium)); Text(s.detail).font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            Button("Show Me") {
                                var d = done; d.insert(s.id); doneRaw = d.joined(separator: ",")
                                if let p = s.page { model.show(p) } else { s.action?() }
                            }.controlSize(.small)
                        }
                        .padding(10).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
        }
    }
}
