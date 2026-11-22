import SwiftUI

/// Reusable result list for Spotlight-backed pages (Recents, library kinds, search).
struct HitList: View {
    let hits: [Spotlight.Hit]
    var showDate = true
    @EnvironmentObject var model: AppModel
    @State private var selection = Set<URL>()
    @State private var qlURL: URL?
    @State private var order = [KeyPathComparator(\Spotlight.Hit.date, order: .reverse)]

    var body: some View {
        Table(hits.sorted(using: order), selection: $selection, sortOrder: $order) {
            TableColumn("Name", value: \.name, comparator: .localizedStandard) { h in
                HStack(spacing: 8) {
                    Thumb(url: h.url, side: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(h.name).lineLimit(1)
                        Text(Places.displayPath(h.url.deletingLastPathComponent())).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .onDrag { NSItemProvider(object: h.url as NSURL) }
            }.width(min: 260, ideal: 420)
            TableColumn("Date", value: \.date) { Text(Fmt.when($0.date)).foregroundStyle(.secondary) }.width(min: 110, ideal: 150)
            TableColumn("Size", value: \.size) { Text(Fmt.size($0.size)).foregroundStyle(.secondary).monospacedDigit() }.width(min: 70, ideal: 90)
        }
        .contextMenu(forSelectionType: URL.self) { urls in
            FileMenu(urls: Array(urls))
            Divider()
            Button("Show in Spyglass") { if let u = urls.first { model.reveal(u) } }
        } primaryAction: { urls in urls.forEach { model.openItem($0) } }
        .onKeyPress(.space) { qlURL = qlURL == nil ? selection.first : nil; return .handled }
        .quickLookPreview($qlURL, in: hits.map(\.url))
        .onChange(of: selection) { _, s in model.inspected = s.count == 1 ? s.first : nil }
    }
}

struct SpotlightListView: View {
    let title: String
    let subtitle: String?
    let symbol: String
    let query: String
    var scopes: [Any] = [NSMetadataQueryUserHomeScope]
    var sort = NSMetadataItemFSContentChangeDateKey
    var kind: FileKind = .other
    @State private var hits: [Spotlight.Hit] = []
    @State private var total = 0
    @State private var loading = true
    @State private var gallery = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                PageHeader(title: title, subtitle: subtitle ?? (loading ? "Looking…" : "\(Fmt.count(total)) items" + (total > hits.count ? " · showing newest \(hits.count)" : "")),
                           symbol: symbol, tint: Theme.tint(kind == .other ? .folder : kind)) {
                    Picker("", selection: $gallery) { Image(systemName: "list.bullet").tag(false); Image(systemName: "square.grid.2x2").tag(true) }
                        .pickerStyle(.segmented).frame(width: 80)
                }
            }.padding([.horizontal, .top], 20).padding(.bottom, 12)
            if loading { ProgressView().frame(maxHeight: .infinity) }
            else if hits.isEmpty { EmptyState(symbol: symbol, title: "Nothing here yet") }
            else if gallery { HitGallery(hits: hits) }
            else { HitList(hits: hits) }
        }
        .task(id: query) {
            loading = true
            let r = await Spotlight.run(query, scopes: scopes, sort: sort, limit: 1500)
            hits = r.hits; total = r.total; loading = false
        }
    }
}

struct HitGallery: View {
    let hits: [Spotlight.Hit]
    @EnvironmentObject var model: AppModel
    @State private var qlURL: URL?
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 10)], spacing: 10) {
                ForEach(hits.prefix(600)) { h in
                    VStack(spacing: 4) {
                        Thumb(url: h.url, side: 120)
                        Text(h.name).font(.caption).lineLimit(1)
                    }
                    .padding(6)
                    .contentShape(Rectangle())
                    .onTapGesture { if NSApp.currentEvent?.clickCount == 2 { FileOps.open(h.url) } else { qlURL = h.url; model.inspected = h.url } }
                    .contextMenu { FileMenu(urls: [h.url]); Button("Show in Spyglass") { model.reveal(h.url) } }
                    .onDrag { NSItemProvider(object: h.url as NSURL) }
                }
            }.padding(14)
        }
        .quickLookPreview($qlURL, in: hits.map(\.url))
    }
}

// MARK: - Search

struct SearchView: View {
    let text: String
    @EnvironmentObject var model: AppModel
    @AppStorage("searchContents") private var contents = true
    @AppStorage("searchMeaning") private var meaning = true
    @State private var parsed = ParsedSearch()
    @State private var removed = Set<String>()
    @State private var hits: [Spotlight.Hit] = []
    @State private var total = 0
    @State private var loading = false
    @State private var everywhere = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Understood as").font(.callout).foregroundStyle(.secondary)
                    ChipRow(parsed: parsed, removed: $removed)
                    Spacer()
                    Toggle("Everywhere", isOn: $everywhere).toggleStyle(.checkbox).help("Search the whole disk, not just your home folder")
                    Button { model.saveSearch(text) } label: { Label("Save", systemImage: "bookmark") }
                }
                Text(loading ? "Searching…" : "\(Fmt.count(total)) results").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            Divider()
            if loading && hits.isEmpty { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if hits.isEmpty { EmptyState(symbol: "magnifyingglass", title: "No results", message: "Try fewer words, or remove a chip above. Try things like “screenshots from last week”, “pdfs over 5 MB”, “ext:psd”, “from gmail”.") }
            else { HitList(hits: hits) }
        }
        .task(id: "\(text)|\(removed)|\(everywhere)|\(contents)|\(meaning)") {
            if parsed.chips.isEmpty && parsed.words.isEmpty || model.searchText != text { parsed = ParsedSearch.parse(text) }
            await run()
        }
        .onChange(of: text) { _, t in removed = []; parsed = ParsedSearch.parse(t) }
        .onAppear { parsed = ParsedSearch.parse(text); if model.searchText.isEmpty { model.searchText = text } }
    }

    private func run() async {
        guard let q = parsed.query(excluding: removed, meaning: meaning, contents: contents) else { hits = []; total = 0; return }
        loading = true
        let scopes: [Any] = everywhere ? [NSMetadataQueryLocalComputerScope] : [parsed.scope?.path ?? NSMetadataQueryUserHomeScope]
        let r = await Spotlight.run(q, scopes: scopes, limit: 1000)
        let seen = Set(r.hits.map(\.url))
        let fromImages = parsed.chips.filter({ !removed.contains($0.id) }).allSatisfy({ $0.id == "date" || $0.label == "Images" || $0.label == "Screenshots" })
            ? ImageTextIndex.shared.search(parsed.words.filter { !removed.contains("w:" + $0) }).filter { !seen.contains($0.url) } : []
        hits = r.hits + fromImages; total = r.total + fromImages.count; loading = false
    }
}

struct ChipRow: View {
    let parsed: ParsedSearch
    @Binding var removed: Set<String>
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(parsed.chips) { c in chip(c.label, c.symbol, c.id) }
                ForEach(parsed.words, id: \.self) { w in chip("“\(w)”", "textformat", "w:" + w) }
            }
        }
    }
    private func chip(_ label: String, _ symbol: String, _ id: String) -> some View {
        let off = removed.contains(id)
        return HStack(spacing: 4) {
            Image(systemName: symbol).font(.caption)
            Text(label).font(.callout).strikethrough(off)
            Button { if off { removed.remove(id) } else { removed.insert(id) } } label: { Image(systemName: off ? "plus" : "xmark").font(.system(size: 9, weight: .bold)) }
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(off ? AnyShapeStyle(.quaternary) : AnyShapeStyle(Color.accentColor.opacity(0.15)), in: Capsule())
        .foregroundStyle(off ? .secondary : .primary)
    }
}

// MARK: - Downloaded From

struct DownloadedFromView: View {
    struct Group: Identifiable { let name: String; var hits: [Spotlight.Hit]; var bytes: Int64; var id: String { name } }
    @State private var groups: [Group] = []
    @State private var picked: String?
    @State private var loading = true

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Downloaded From", subtitle: loading ? "Reading where your files came from…" : "\(groups.count) sources · grouped by the site each file came from",
                       symbol: "arrow.down.circle", tint: .green).padding(20)
            if loading { ProgressView().frame(maxHeight: .infinity) }
            else {
                HSplitView {
                    List(selection: $picked) {
                        ForEach(groups) { g in
                            HStack {
                                SourceIcon(name: g.name)
                                VStack(alignment: .leading) { Text(g.name); Text("\(g.hits.count) files · \(Fmt.size(g.bytes))").font(.caption).foregroundStyle(.secondary) }
                            }.tag(g.name)
                        }
                    }.frame(minWidth: 220, idealWidth: 260, maxWidth: 340)
                    if let g = groups.first(where: { $0.name == picked }) { HitList(hits: g.hits) }
                    else { EmptyState(symbol: "arrow.down.circle", title: "Pick a source") }
                }
            }
        }
        .task {
            let r = await Spotlight.run("kMDItemWhereFroms == \"*\"", sort: "kMDItemDateAdded", limit: 4000)
            let map = await Task.detached { () -> [String: Group] in
                var map: [String: Group] = [:]
                for h in r.hits {
                    let name = Meta.sourceName(for: Meta.whereFroms(h.url)) ?? "Other"
                    map[name, default: Group(name: name, hits: [], bytes: 0)].hits.append(h)
                    map[name]!.bytes += h.size
                }
                return map
            }.value
            groups = map.values.sorted { $0.hits.count > $1.hits.count }
            picked = groups.first?.name
            loading = false
        }
    }
}

struct SourceIcon: View {
    let name: String
    var body: some View {
        let colors: [String: Color] = ["Gmail": .red, "Google Drive": .yellow, "ChatGPT": .teal, "Claude": .orange, "Canva": .cyan, "X": .primary,
                                       "Slack": .purple, "WhatsApp": .green, "GitHub": .primary, "Dropbox": .blue, "Apple": .gray]
        Text(String(name.prefix(1)).uppercased()).font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
            .frame(width: 24, height: 24).background((colors[name] ?? .accentColor).gradient, in: RoundedRectangle(cornerRadius: 6))
    }
}

struct CloudDrivesView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        let clouds = Places.cloudDrives()
        VStack(alignment: .leading) {
            PageHeader(title: "Cloud Drives", subtitle: "Read from the folders their apps keep on this Mac. Spyglass never signs in.", symbol: "cloud", tint: .blue)
            if clouds.isEmpty { EmptyState(symbol: "cloud", title: "No cloud drives found", message: "Install Google Drive, Dropbox, OneDrive or Box, or turn on iCloud Drive.") }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220))], spacing: 12) {
                ForEach(clouds) { c in
                    Button { model.open(folder: c.url) } label: {
                        Card { HStack { Image(systemName: c.symbol).font(.title2).foregroundStyle(.blue); Text(c.name).font(.headline); Spacer() } }
                    }.buttonStyle(.plain)
                }
            }
            Spacer()
        }.padding(20)
    }
}
