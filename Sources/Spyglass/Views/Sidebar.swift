import SwiftUI

struct Sidebar: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("showCloudDrives") private var showCloud = true
    @AppStorage("theme") private var theme = "playful"
    @StateObject private var lib = LibraryStats.shared
    @State private var volumes = Places.volumes()
    @State private var clouds = Places.cloudDrives()

    var body: some View {
        VStack(spacing: 0) {
            Picker("Room", selection: Binding(get: { model.room }, set: { r in
                model.room = r
                switch r { case .look: model.show(.home); case .sweep: model.show(.cleanup); case .tools: model.show(.tools(nil)) }
            })) {
                ForEach(Room.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 4)

            List(selection: Binding<Page?>(get: { model.page == .folder ? nil : model.page }, set: { if let p = $0 { model.show(p) } })) {
                switch model.room {
                case .look: lookSections
                case .sweep: sweepSections
                case .tools: toolSections
                }
            }
            .listStyle(.sidebar)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWorkspace.didMountNotification, object: nil)) { _ in volumes = Places.volumes() }
        .onReceive(NotificationCenter.default.publisher(for: NSWorkspace.didUnmountNotification, object: nil)) { _ in volumes = Places.volumes() }
        .task { lib.refreshIfNeeded() }
    }

    private func tint(_ c: Color) -> Color { theme == "minimal" ? .secondary : c }

    @ViewBuilder var lookSections: some View {
        Section {
            row("Home", "house.fill", .blue, .home)
            row("Recents", "clock.fill", .orange, .recents)
            row("Downloaded From", "arrow.down.circle.fill", .green, .downloadedFrom)
            row("Photos", "photo.stack.fill", .orange, .photos)
            row("Text in Images", "text.viewfinder", .teal, .imageText)
        }
        Section("Library") {
            ForEach(LibraryKind.allCases) { k in
                Label { HStack { Text(k.title); Spacer(); if let c = lib.counts[k] { Text(Fmt.count(c)).foregroundStyle(.secondary).font(.caption).monospacedDigit() } } }
                icon: { Image(systemName: k.symbol).foregroundStyle(tint(k.fileKind.color)) }
                .tag(Page.library(k))
            }
        }
        Section("Places") {
            place("Home", "house", Places.home)
            place("Desktop", "menubar.dock.rectangle", Places.desktop)
            place("Documents", "doc", Places.documents)
            place("Downloads", "arrow.down.circle", Places.downloads)
            place("Applications", "square.grid.2x2", Places.applications)
            ForEach(model.pinned, id: \.self) { u in
                place(u.lastPathComponent, "pin", u).contextMenu { Button("Unpin") { model.togglePin(u) } }
            }
        }
        if showCloud && !clouds.isEmpty {
            Section("Cloud Drives") { ForEach(clouds) { place($0.name, $0.symbol, $0.url) } }
        }
        Section("Drives") {
            place("Macintosh HD", "internaldrive", URL(fileURLWithPath: "/"))
            ForEach(volumes) { v in
                Button { model.open(folder: v.url) } label: {
                    Label {
                        HStack {
                            VStack(alignment: .leading, spacing: 0) { Text(v.name); Text("\(Fmt.size(v.free)) free").font(.caption2).foregroundStyle(.secondary) }
                            Spacer()
                            if v.ejectable {
                                Button { eject(v.url) } label: { Image(systemName: "eject.fill") }.buttonStyle(.borderless).help("Eject")
                            }
                        }
                    } icon: { Image(systemName: "externaldrive") }
                }.buttonStyle(.plain)
            }
        }
        if !model.savedSearches.isEmpty {
            Section("Saved Searches") {
                ForEach(model.savedSearches, id: \.self) { q in
                    Label(q, systemImage: "magnifyingglass").tag(Page.search(q)).contextMenu { Button("Remove") { model.removeSearch(q) } }
                }
            }
        }
    }

    @ViewBuilder var sweepSections: some View {
        Section("Free Up Space") {
            row("Clean Up", "sparkles", .pink, .cleanup)
            row("Duplicates", "square.on.square", .purple, .duplicates)
            row("Large Files", "doc.badge.arrow.up", .orange, .largeFiles)
            row("Space Map", "chart.pie.fill", .blue, .spaceMap)
            row("Disk Usage", "internaldrive.fill", .indigo, .diskUsage)
        }
        Section("Apps") {
            row("App Uninstaller", "xmark.app.fill", .red, .uninstaller)
            row("App Caches", "shippingbox.fill", .brown, .caches)
            row("Startup Items", "power", .teal, .startup)
        }
        Section("Mac") {
            row("Mac Health", "heart.text.square.fill", .red, .health)
            row("Memory", "memorychip.fill", .green, .memory)
        }
        Section("Tidy") {
            row("Organize", "square.grid.3x1.folder.badge.plus", .mint, .organize)
            row("Routines", "repeat.circle.fill", .indigo, .routines)
            row("Assistant", "wand.and.stars", .purple, .assistant)
            row("Activity", "clock.arrow.circlepath", .gray, .activity)
        }
    }

    @ViewBuilder var toolSections: some View {
        Section {
            row("All Tools", "square.grid.3x3.fill", .accentColor, .tools(nil))
        }
        Section("Categories") {
            ForEach(ToolCategory.allCases) { c in
                Label { HStack { Text(c.title); Spacer(); Text("\(ToolCatalog.tools(in: c).count)").font(.caption).foregroundStyle(.secondary) } }
                icon: { Image(systemName: c.symbol).foregroundStyle(tint(c.color)) }
                .tag(Page.tools(c))
            }
        }
        Section("Favorites") {
            ForEach(ToolCatalog.favorites) { t in
                Label { Text(t.name) } icon: { Image(systemName: t.symbol).foregroundStyle(tint(t.category.color)) }.tag(Page.tool(t.id))
            }
        }
    }

    private func row(_ title: String, _ symbol: String, _ color: Color, _ page: Page) -> some View {
        Label { Text(title) } icon: { Image(systemName: symbol).foregroundStyle(tint(color)) }.tag(page)
    }

    private func place(_ title: String, _ symbol: String, _ url: URL) -> some View {
        let active = model.page == .folder && model.tab.url.standardizedFileURL == url.standardizedFileURL
        return Button { model.open(folder: url) } label: {
            Label(title, systemImage: symbol).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 1)
        .listRowBackground(active ? RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.18)).padding(.horizontal, 10) : nil)
        .dropDestination(for: URL.self) { urls, _ in
            FileOps.move(urls, into: url, copy: NSEvent.modifierFlags.contains(.option)); return true
        }
        .contextMenu {
            Button("Open in New Tab") { model.open(folder: url, newTab: true) }
            Button("Show in Finder") { NSWorkspace.shared.open(url) }
        }
    }

    private func eject(_ u: URL) {
        do { try NSWorkspace.shared.unmountAndEjectDevice(at: u); ActivityLog.shared.show("Ejected \(u.lastPathComponent)") }
        catch { ActivityLog.shared.show("Couldn't eject: \(error.localizedDescription)") }
    }
}

/// Library counts + sizes, computed once per launch and cached on disk for an instant sidebar.
@MainActor final class LibraryStats: ObservableObject {
    static let shared = LibraryStats()
    @Published var counts: [LibraryKind: Int] = [:]
    @Published var bytes: [LibraryKind: Int64] = [:]
    @Published var loading = false
    private var loaded = false
    private var cacheURL: URL { Places.support.appendingPathComponent("library.json") }

    init() {
        if let d = try? Data(contentsOf: cacheURL), let c = try? JSONDecoder().decode([String: [Int64]].self, from: d) {
            for (k, v) in c { if let kind = LibraryKind(rawValue: k), v.count == 2 { counts[kind] = Int(v[0]); bytes[kind] = v[1] } }
        }
    }

    func refreshIfNeeded() { if !loaded { loaded = true; Task { await refresh() } } }

    func refresh() async {
        loading = true
        for k in LibraryKind.allCases {
            let s = await Spotlight.stats(k.query, scopes: k.scopes)
            counts[k] = s.count; bytes[k] = s.bytes
        }
        loading = false
        var out: [String: [Int64]] = [:]
        for k in LibraryKind.allCases { out[k.rawValue] = [Int64(counts[k] ?? 0), bytes[k] ?? 0] }
        try? JSONEncoder().encode(out).write(to: cacheURL)
    }
}
