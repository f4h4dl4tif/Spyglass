import SwiftUI
import AppKit

/// Spotlight-style floating panel: files (live Spotlight), places, pages, tools and commands.
@MainActor final class QuickSearchPanel {
    static let shared = QuickSearchPanel()
    private var panel: KeyPanel?
    let state = QuickSearchState()

    func toggle() {
        if let p = panel, p.isVisible { hide(); return }
        show()
    }
    func show() {
        if panel == nil {
            let p = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 680, height: 460), styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: true)
            p.isFloatingPanel = true; p.level = .floating; p.backgroundColor = .clear; p.isOpaque = false; p.hasShadow = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.isMovableByWindowBackground = true
            p.contentView = NSHostingView(rootView: QuickSearchView(state: state, close: { [weak self] in self?.hide() }).glassThemeRoot())
            p.onResign = { [weak self] in self?.hide() }
            panel = p
        }
        guard let p = panel, let screen = NSScreen.main else { return }
        let f = screen.visibleFrame
        p.setFrameOrigin(NSPoint(x: f.midX - 340, y: f.maxY - f.height * 0.22 - 460))
        state.reset()
        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func hide() { panel?.orderOut(nil) }
}

final class KeyPanel: NSPanel {
    var onResign: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func resignKey() { super.resignKey(); onResign?() }
    override func cancelOperation(_ sender: Any?) { onResign?() }
}

@MainActor final class QuickSearchState: ObservableObject {
    enum Scope: Int { case all, files, tools }
    struct Row: Identifiable, Hashable {
        let id: String
        let title: String
        let subtitle: String
        let symbol: String
        let url: URL?
        let section: String
        let run: (() -> Void)?
        static func == (a: Row, b: Row) -> Bool { a.id == b.id }
        func hash(into h: inout Hasher) { h.combine(id) }
    }
    @Published var text = ""
    @Published var scope = Scope.all
    @Published var rows: [Row] = []
    @Published var selected = 0
    @Published var parsed = ParsedSearch()
    private var task: Task<Void, Never>?

    func reset() { text = ""; selected = 0; scope = .all; update() }

    func update() {
        task?.cancel()
        let q = text.trimmingCharacters(in: .whitespaces)
        var out: [Row] = []
        let m = AppModel.shared
        if scope != .files {
            let pages: [(String, String, Page)] = [("Home", "house", .home), ("Recents", "clock", .recents), ("Downloaded From", "arrow.down.circle", .downloadedFrom),
                ("Clean Up", "sparkles", .cleanup), ("Duplicates", "square.on.square", .duplicates), ("Large Files", "doc.badge.arrow.up", .largeFiles), ("Space Map", "chart.pie", .spaceMap),
                ("Disk Usage", "internaldrive", .diskUsage), ("App Uninstaller", "xmark.app", .uninstaller), ("App Caches", "shippingbox", .caches), ("Startup Items", "power", .startup),
                ("Mac Health", "heart.text.square", .health), ("Memory", "memorychip", .memory), ("Activity", "clock.arrow.circlepath", .activity), ("Organize", "folder.badge.plus", .organize),
                ("Assistant", "wand.and.stars", .assistant), ("All Tools", "wrench.and.screwdriver", .tools(nil)),
                ("Photos", "photo.stack", .photos), ("Text in Images", "text.viewfinder", .imageText), ("Routines", "repeat.circle", .routines)]
            let places: [(String, URL)] = [("Home Folder", Places.home), ("Desktop", Places.desktop), ("Documents", Places.documents), ("Downloads", Places.downloads), ("Applications", Places.applications)]
                + m.pinned.map { ($0.lastPathComponent, $0) } + Places.cloudDrives().map { ($0.name, $0.url) }
            let commands: [(String, String, () -> Void)] = [
                ("New Tab", "plus.square.on.square", { m.addTab() }), ("Switch Playful / Minimal", "paintpalette", { m.toggleTheme() }),
                ("Show / Hide Hidden Files", "eye", { m.toggleHidden() }), ("Put Back Last Cleanup", "arrow.uturn.backward", { ActivityLog.shared.undoLast(of: [.cleanup, .trash, .uninstall]) }),
                ("Go to Folder…", "arrow.right.circle", { m.show(.folder); m.goToFolder = true }), ("Split View", "rectangle.split.2x1", { m.toggleSplit() }), ("Settings", "gearshape", { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) })]
            func match(_ s: String) -> Bool { q.isEmpty || s.localizedCaseInsensitiveContains(q) || fuzzy(q, s) }
            if scope == .all {
                out += places.filter { match($0.0) }.prefix(q.isEmpty ? 5 : 4).map { p in Row(id: "place:\(p.1.path)", title: p.0, subtitle: Places.displayPath(p.1), symbol: "folder", url: p.1, section: "Places") { m.open(folder: p.1) } }
                out += pages.filter { match($0.0) }.prefix(q.isEmpty ? 4 : 5).map { p in Row(id: "page:\(p.0)", title: p.0, subtitle: "Go to page", symbol: p.1, url: nil, section: "Pages") { m.show(p.2) } }
            }
            out += ToolCatalog.all.filter { match($0.name) || (!q.isEmpty && $0.detail.localizedCaseInsensitiveContains(q)) }.prefix(scope == .tools ? 40 : (q.isEmpty ? 3 : 5))
                .map { t in Row(id: "tool:\(t.id)", title: t.name, subtitle: t.detail, symbol: t.symbol, url: nil, section: "Tools") { m.show(.tool(t.id)) } }
            if scope == .all && !q.isEmpty {
                out += commands.filter { match($0.0) }.prefix(3).map { c in Row(id: "cmd:\(c.0)", title: c.0, subtitle: "Command", symbol: c.1, url: nil, section: "Commands", run: c.2) }
            }
        }
        rows = out
        selected = 0
        parsed = ParsedSearch.parse(q)
        guard scope != .tools, q.count >= 2 else { return }
        let p = parsed
        task = Task {
            try? await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled, let query = p.query(excluding: [], meaning: UserDefaults.standard.bool(forKey: "searchMeaning"), contents: false) else { return }
            let r = await Spotlight.run(query, scopes: [p.scope?.path ?? NSMetadataQueryUserHomeScope], sort: "kMDItemLastUsedDate", limit: 30)
            guard !Task.isCancelled else { return }
            let files = r.hits.map { h in Row(id: "file:\(h.url.path)", title: h.name, subtitle: Places.displayPath(h.url.deletingLastPathComponent()), symbol: "doc", url: h.url, section: "Files · \(Fmt.count(r.total))", run: nil) }
            let seen = Set(r.hits.map(\.url))
            let inImages = ImageTextIndex.shared.search(p.words, limit: 8).filter { !seen.contains($0.url) }.map { h in
                Row(id: "file:\(h.url.path)", title: h.name, subtitle: "Text in image · " + Places.displayPath(h.url.deletingLastPathComponent()), symbol: "text.viewfinder", url: h.url, section: "Text in Images", run: nil) }
            rows = (scope == .files ? [] : rows.filter { !$0.id.hasPrefix("file:") }) + files + inImages
        }
    }

    private func fuzzy(_ q: String, _ s: String) -> Bool {
        var it = s.lowercased().makeIterator()
        for c in q.lowercased() where c != " " { var found = false; while let x = it.next() { if x == c { found = true; break } }; if !found { return false } }
        return q.count >= 2
    }

    func activate(_ row: Row, mode: Int) {   // 0 open, 1 show in Spyglass, 2 show in Finder
        QuickSearchPanel.shared.hide()
        if let run = row.run, row.url == nil || row.id.hasPrefix("place:") { run(); return }
        guard let u = row.url else { return }
        switch mode {
        case 1: AppModel.shared.reveal(u)
        case 2: FileOps.reveal([u])
        default: AppModel.shared.openItem(u)
        }
    }
}

struct QuickSearchView: View {
    @ObservedObject var state: QuickSearchState
    let close: () -> Void
    @FocusState private var focus: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 20, weight: .medium)).foregroundStyle(.secondary)
                TextField("Search files, places and tools", text: $state.text)
                    .textFieldStyle(.plain).font(.system(size: 22, weight: .regular)).focused($focus)
                    .onSubmit { submit(0) }
                Picker("", selection: $state.scope) { Text("All").tag(QuickSearchState.Scope.all); Text("Files").tag(QuickSearchState.Scope.files); Text("Tools").tag(QuickSearchState.Scope.tools) }
                    .pickerStyle(.segmented).frame(width: 170).labelsHidden()
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            if !state.parsed.chips.isEmpty {
                HStack(spacing: 6) {
                    Text("Understood as").font(.caption).foregroundStyle(.secondary)
                    ForEach(state.parsed.chips) { c in Label(c.label, systemImage: c.symbol).font(.caption).padding(.horizontal, 7).padding(.vertical, 3).background(Color.accentColor.opacity(0.15), in: Capsule()) }
                    ForEach(state.parsed.words, id: \.self) { Text("“\($0)”").font(.caption).padding(.horizontal, 7).padding(.vertical, 3).background(.quaternary, in: Capsule()) }
                    Spacer()
                }.padding(.horizontal, 18).padding(.bottom, 8)
            }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(state.rows.enumerated()), id: \.element.id) { i, row in
                            if i == 0 || state.rows[i - 1].section != row.section {
                                Text(row.section).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 2)
                            }
                            HStack(spacing: 10) {
                                if let u = row.url { Thumb(url: u, side: 26, iconOnly: true) } else { Image(systemName: row.symbol).frame(width: 26, height: 26).foregroundStyle(i == state.selected ? .white : .accentColor) }
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(row.title).lineLimit(1)
                                    Text(row.subtitle).font(.caption).foregroundStyle(i == state.selected ? .white.opacity(0.8) : .secondary).lineLimit(1)
                                }
                                Spacer()
                                if i == state.selected && row.url != nil && !row.id.hasPrefix("place:") { Text("↩ Open  ⌘↩ Spyglass  ⌥↩ Finder").font(.caption2).foregroundStyle(.white.opacity(0.8)) }
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .foregroundStyle(i == state.selected ? .white : .primary)
                            .background(i == state.selected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                            .onTapGesture { state.selected = i; submit(0) }
                            .onDrag { row.url.map { NSItemProvider(object: $0 as NSURL) } ?? NSItemProvider() }
                            .id(i)
                        }
                    }.padding(8)
                }
                .onChange(of: state.selected) { _, s in proxy.scrollTo(s) }
            }
            .overlay { if state.rows.isEmpty && !state.text.isEmpty { Text("No results").foregroundStyle(.secondary) } }
        }
        .frame(width: 680, height: 460)
        .modifier(QuickSearchSurface())
        .onAppear { focus = true }
        .onChange(of: state.text) { _, _ in state.update() }
        .onChange(of: state.scope) { _, _ in state.update() }
        .onKeyPress(.downArrow) { state.selected = min(state.selected + 1, state.rows.count - 1); return .handled }
        .onKeyPress(.upArrow) { state.selected = max(state.selected - 1, 0); return .handled }
        .onKeyPress(.escape) { close(); return .handled }
        .onKeyPress(.return, phases: .down) { press in
            submit(press.modifiers.contains(.command) ? 1 : press.modifiers.contains(.option) ? 2 : 0); return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "123"), phases: .down) { press in
            guard press.modifiers.contains(.command), let n = Int(press.characters) else { return .ignored }
            state.scope = [.all, .files, .tools][n - 1]; return .handled
        }
    }

    func submit(_ mode: Int) {
        if state.rows.indices.contains(state.selected) { state.activate(state.rows[state.selected], mode: mode) }
        else if !state.text.isEmpty { QuickSearchPanel.shared.hide(); AppModel.shared.searchText = state.text; AppModel.shared.show(.search(state.text)) }
    }
}

/// The panel's background: the original material, or Liquid Glass when the glass theme is on.
private struct QuickSearchSurface: ViewModifier {
    @Environment(\.glassOn) private var glassOn
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        if glassOn {
            content.glassPanel(true, in: shape)
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.1)))
        }
    }
}
