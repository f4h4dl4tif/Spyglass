import SwiftUI
import QuickLook

struct BrowserView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            if model.tabs.count > 1 { TabStrip() }
            if let right = model.splitTab {
                HSplitView {
                    BrowserPane(tab: model.leftTab, isRight: false).frame(minWidth: 280)
                    BrowserPane(tab: right, isRight: true).frame(minWidth: 280)
                }
            } else {
                BrowserPane(tab: model.leftTab, isRight: false)
            }
        }
        .alert("Rename", isPresented: Binding(get: { model.renameTarget != nil }, set: { if !$0 { model.renameTarget = nil } })) {
            RenameField(url: model.renameTarget)
        }
    }
}

struct BrowserPane: View {
    @ObservedObject var tab: BrowserTab
    let isRight: Bool
    @EnvironmentObject var model: AppModel
    @AppStorage("cardSize") private var cardSize = 96.0
    @State private var qlURL: URL?

    var focused: Bool { model.splitTab == nil || model.rightFocused == isRight }

    var body: some View {
        VStack(spacing: 0) {
            if model.splitTab != nil { Rectangle().fill(focused ? Color.accentColor : .clear).frame(height: 2) }
            PathBar(url: tab.url)
            Divider()
            Group {
                if tab.items.isEmpty {
                    EmptyState(symbol: "folder", title: "This folder is empty", message: "Drop files here to copy them in. Hold ⌘ to move instead.")
                        .contextMenu { Button("New Folder") { model.newFolder() }; Button("Paste") { model.paste(move: false) } }
                } else {
                    switch tab.mode {
                    case .grid: FileGrid(tab: tab, qlURL: $qlURL, cardSize: cardSize)
                    case .list: FileTable(tab: tab, qlURL: $qlURL)
                    case .columns: ColumnBrowser(tab: tab, qlURL: $qlURL)
                    }
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                FileOps.move(urls, into: tab.url, copy: !NSEvent.modifierFlags.contains(.command)); return true
            }
            Divider()
            BrowserFooter(tab: tab, cardSize: $cardSize)
        }
        .quickLookPreview($qlURL, in: tab.items.map(\.url))
        .simultaneousGesture(TapGesture().onEnded { if model.splitTab != nil && model.rightFocused != isRight { model.rightFocused = isRight } })
        .onChange(of: tab.selection) { _, s in
            if !s.isEmpty && model.splitTab != nil { model.rightFocused = isRight }
            model.inspected = s.count == 1 ? s.first : nil
        }
        .onReceive(NotificationCenter.default.publisher(for: FileOps.changedNote)) { _ in tab.load() }
    }
}

private struct RenameField: View {
    let url: URL?
    @State private var name = ""
    @EnvironmentObject var model: AppModel
    var body: some View {
        TextField("Name", text: $name).onAppear { name = url?.lastPathComponent ?? "" }
        Button("Rename") { if let url, let n = FileOps.rename(url, to: name) { model.tab.selection = [n] }; model.renameTarget = nil }
        Button("Cancel", role: .cancel) { model.renameTarget = nil }
    }
}

// MARK: - Tabs & path

struct TabStrip: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack(spacing: 1) {
            ForEach(model.tabs) { t in TabButton(tab: t, active: t.id == model.activeTabID) }
            Button { model.addTab() } label: { Image(systemName: "plus").frame(width: 28, height: 26) }.buttonStyle(.borderless).help("New Tab (⌘T)")
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(.bar)
    }
}

private struct TabButton: View {
    @ObservedObject var tab: BrowserTab
    let active: Bool
    @EnvironmentObject var model: AppModel
    @State private var hover = false
    var body: some View {
        HStack(spacing: 6) {
            Button { model.closeTab(tab.id) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                .buttonStyle(.borderless).opacity(hover ? 1 : 0)
            Image(nsImage: NSWorkspace.shared.icon(forFile: tab.url.path)).resizable().frame(width: 14, height: 14)
            Text(tab.title).lineLimit(1).font(.callout)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).frame(height: 26).frame(maxWidth: .infinity)
        .background(active ? Color(nsColor: .controlBackgroundColor) : (hover ? Color.primary.opacity(0.05) : .clear), in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { model.activeTabID = tab.id }
        .onHover { hover = $0 }
        .dropDestination(for: URL.self) { urls, _ in FileOps.move(urls, into: tab.url, copy: false); return true }
    }
}

struct PathBar: View {
    let url: URL
    @EnvironmentObject var model: AppModel
    var crumbs: [URL] {
        var out: [URL] = [], u = url.standardizedFileURL
        let home = Places.home.standardizedFileURL
        while true {
            out.insert(u, at: 0)
            if u.path == home.path || u.path == "/" { break }
            let p = u.deletingLastPathComponent()
            if p.path == u.path { break }
            u = p
        }
        return out
    }
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Array(crumbs.enumerated()), id: \.offset) { i, c in
                    if i > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                    Button { model.open(folder: c) } label: {
                        HStack(spacing: 4) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: c.path)).resizable().frame(width: 14, height: 14)
                            Text(c.path == "/" ? "Macintosh HD" : FileManager.default.displayName(atPath: c.path)).font(.callout)
                        }
                        .padding(.horizontal, 6).padding(.vertical, 3).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(i == crumbs.count - 1 ? .primary : .secondary)
                    .dropDestination(for: URL.self) { urls, _ in FileOps.move(urls, into: c, copy: false); return true }
                }
            }.padding(.horizontal, 10)
        }
        .frame(height: 30)
    }
}

struct BrowserFooter: View {
    @ObservedObject var tab: BrowserTab
    @Binding var cardSize: Double
    var body: some View {
        HStack {
            let sel = tab.items.filter { tab.selection.contains($0.url) }
            if sel.isEmpty { Text("\(tab.items.count) items") }
            else {
                let files = sel.filter { !$0.isFolderLike }.reduce(Int64(0)) { $0 + $1.size }
                Text("\(sel.count) of \(tab.items.count) selected" + (files > 0 ? " · \(Fmt.size(files))" : ""))
            }
            Text("· \(Fmt.size(Places.startupDisk().important)) available").foregroundStyle(.secondary)
            Spacer()
            if tab.mode == .grid {
                Image(systemName: "square.grid.3x3").font(.caption).foregroundStyle(.secondary)
                Slider(value: $cardSize, in: 56...200).frame(width: 110).controlSize(.mini)
                Image(systemName: "square.grid.2x2").foregroundStyle(.secondary)
            }
        }
        .font(.callout).padding(.horizontal, 12).frame(height: 26).background(.bar)
    }
}

// MARK: - Selection helpers

@MainActor func handleClick(_ url: URL, in tab: BrowserTab, order: [URL], model: AppModel) {
    let flags = NSEvent.modifierFlags
    if NSApp.currentEvent?.clickCount == 2 {
        model.openItem(url, newTab: flags.contains(.command)); return
    }
    if flags.contains(.command) {
        if tab.selection.contains(url) { tab.selection.remove(url) } else { tab.selection.insert(url) }
    } else if flags.contains(.shift), let anchor = tab.selection.first, let a = order.firstIndex(of: anchor), let b = order.firstIndex(of: url) {
        tab.selection = Set(order[min(a, b)...max(a, b)])
    } else {
        tab.selection = [url]
    }
}

// MARK: - Grid

struct FileGrid: View {
    @ObservedObject var tab: BrowserTab
    @Binding var qlURL: URL?
    let cardSize: Double
    @EnvironmentObject var model: AppModel
    @AppStorage("gridSort") private var sort = "name"
    @State private var typed = ""
    @State private var typedAt = Date.distantPast
    @FocusState private var focused: Bool

    var body: some View {
        let items = sortedItems()
        let order = items.map(\.url)
        GeometryReader { geo in
            let cols = max(1, Int((geo.size.width - 24) / (cardSize + 36)))
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: cols), spacing: 10) {
                        ForEach(items) { item in
                            FileCard(item: item, side: cardSize, selected: tab.selection.contains(item.url))
                                .id(item.url)
                                .onTapGesture { focused = true; handleClick(item.url, in: tab, order: order, model: model) }
                                .contextMenu { FileMenu(urls: tab.selection.contains(item.url) ? Array(tab.selection) : [item.url]) }
                                .onDrag { NSItemProvider(object: item.url as NSURL) }
                                .modifier(FolderDrop(item: item))
                        }
                    }
                    .padding(12)
                }
                .background(Color(nsColor: .textBackgroundColor).opacity(0.001))
                .onTapGesture { tab.selection = []; focused = true }
                .contextMenu { BackgroundMenu(tab: tab, sort: $sort) }
                .focusable().focused($focused).focusEffectDisabled()
                .onKeyPress(.space) { qlURL = qlURL == nil ? tab.selection.first : nil; return .handled }
                .onKeyPress(.return) { if tab.selection.count == 1 { model.renameTarget = tab.selection.first } else if tab.selection.count > 1 { model.bulkRename = Array(tab.selection) }; return .handled }
                .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
                    guard !press.modifiers.contains(.command) else { return .ignored }
                    let cur = tab.selection.first.flatMap { order.firstIndex(of: $0) } ?? -1
                    var next = cur
                    switch press.key { case .leftArrow: next -= 1; case .rightArrow: next += 1; case .upArrow: next -= cols; default: next += cols }
                    next = max(0, min(order.count - 1, cur < 0 ? 0 : next))
                    if order.indices.contains(next) { tab.selection = [order[next]]; withAnimation { proxy.scrollTo(order[next]) } }
                    return .handled
                }
                .onKeyPress(characters: .alphanumerics) { press in
                    typed = Date().timeIntervalSince(typedAt) > 1 ? press.characters : typed + press.characters
                    typedAt = Date()
                    if let m = items.first(where: { $0.name.lowercased().hasPrefix(typed.lowercased()) }) { tab.selection = [m.url]; proxy.scrollTo(m.url) }
                    return .handled
                }
                .onAppear { focused = true }
            }
        }
    }

    private func sortedItems() -> [FileItem] {
        switch sort {
        case "date": return tab.items.sorted { $0.modified > $1.modified }
        case "size": return tab.items.sorted { $0.size > $1.size }
        case "kind": return tab.items.sorted { $0.kind.title == $1.kind.title ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : $0.kind.title < $1.kind.title }
        default: return tab.items.sorted { a, b in
            if a.isFolderLike != b.isFolderLike { return a.isFolderLike }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        }
    }
}

struct FolderDrop: ViewModifier {
    let item: FileItem
    @State private var targeted = false
    func body(content: Content) -> some View {
        if item.isFolderLike {
            content
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, lineWidth: targeted ? 2 : 0))
                .dropDestination(for: URL.self) { urls, _ in
                    FileOps.move(urls, into: item.url, copy: NSEvent.modifierFlags.contains(.option)); return true
                } isTargeted: { targeted = $0 }
        } else { content }
    }
}

struct FileCard: View {
    let item: FileItem
    let side: Double
    let selected: Bool
    @State private var hover = false
    var tags: [String] { Tags.get(item.url) }

    var body: some View {
        VStack(spacing: 6) {
            Thumb(url: item.url, side: side, iconOnly: item.isFolderLike)
                .shadow(color: .black.opacity(item.kind == .image || item.kind == .video ? 0.18 : 0), radius: 2, y: 1)
                .frame(width: side, height: side)
            VStack(spacing: 1) {
                HStack(spacing: 3) {
                    ForEach(tags.prefix(3), id: \.self) { Circle().fill(Tags.color($0)).frame(width: 7, height: 7) }
                    Text(item.name).font(.system(size: 12)).lineLimit(2).multilineTextAlignment(.center)
                }
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(selected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 4))
                .foregroundStyle(selected ? .white : .primary)
                if side >= 80 {
                    Text(item.isFolderLike ? Fmt.ago(item.modified) : Fmt.size(item.size)).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(8)
        .frame(width: side + 30)
        .background(selected ? Color.accentColor.opacity(0.15) : (hover ? Color.primary.opacity(0.05) : .clear), in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .help(item.name)
    }
}

// MARK: - List (Table)

struct FileTable: View {
    @ObservedObject var tab: BrowserTab
    @Binding var qlURL: URL?
    @EnvironmentObject var model: AppModel
    @ObservedObject private var sizes = FolderSizes.shared
    @State private var order = [KeyPathComparator(\FileItem.name, comparator: .localizedStandard)]

    var body: some View {
        Table(tab.items.sorted(using: order), selection: $tab.selection, sortOrder: $order) {
            TableColumn("Name", value: \.name, comparator: .localizedStandard) { item in
                HStack(spacing: 6) {
                    Thumb(url: item.url, side: 18, iconOnly: true)
                    Text(item.name).lineLimit(1)
                    ForEach(Tags.get(item.url).prefix(3), id: \.self) { Circle().fill(Tags.color($0)).frame(width: 7, height: 7) }
                }
                .onDrag { NSItemProvider(object: item.url as NSURL) }
            }.width(min: 200, ideal: 340)
            TableColumn("Date Modified", value: \.modified) { Text(Fmt.when($0.modified)).foregroundStyle(.secondary) }.width(min: 120, ideal: 160)
            TableColumn("Size", value: \.size) { item in
                Group {
                    if item.isFolderLike { if let s = sizes.size(item.url) { Text(Fmt.size(s)) } else { Text("Calculating…").foregroundStyle(.tertiary) } }
                    else { Text(Fmt.size(item.size)) }
                }.foregroundStyle(.secondary).monospacedDigit()
            }.width(min: 70, ideal: 90)
            TableColumn("Kind", value: \.kind.title) { item in
                Label(item.kind.title, systemImage: item.kind.symbol).foregroundStyle(Theme.tint(item.kind)).labelStyle(.titleAndIcon).font(.callout)
            }.width(min: 80, ideal: 110)
        }
        .contextMenu(forSelectionType: URL.self) { urls in FileMenu(urls: Array(urls)) } primaryAction: { urls in
            if let u = urls.first { model.openItem(u, newTab: NSEvent.modifierFlags.contains(.command)) }
        }
        .onKeyPress(.space) { qlURL = qlURL == nil ? tab.selection.first : nil; return .handled }
    }
}

// MARK: - Columns

struct ColumnBrowser: View {
    @ObservedObject var tab: BrowserTab
    @Binding var qlURL: URL?
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    let dirs = [tab.url] + tab.columnPath.filter { isDir($0) }
                    ForEach(Array(dirs.enumerated()), id: \.element) { i, dir in
                        BrowserColumn(dir: dir, selected: i < tab.columnPath.count ? tab.columnPath[i] : nil) { picked in
                            tab.columnPath = Array(tab.columnPath.prefix(i)) + [picked]
                            tab.selection = [picked]
                            withAnimation { proxy.scrollTo("end", anchor: .trailing) }
                        } open: { model.openItem($0) }
                        Divider()
                    }
                    if let last = tab.columnPath.last, !isDir(last) {
                        ColumnPreview(url: last).frame(width: 280)
                    }
                    Color.clear.frame(width: 1).id("end")
                }
            }
        }
        .onChange(of: tab.url) { _, _ in tab.columnPath = [] }
        .onKeyPress(.space) { qlURL = qlURL == nil ? tab.columnPath.last : nil; return .handled }
    }
    private func isDir(_ u: URL) -> Bool {
        let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return (v?.isDirectory ?? false) && !(v?.isPackage ?? false)
    }
}

private struct BrowserColumn: View {
    let dir: URL
    let selected: URL?
    let pick: (URL) -> Void
    let open: (URL) -> Void
    @State private var items: [FileItem] = []
    @AppStorage("showHidden") private var hidden = false

    var body: some View {
        List(selection: Binding(get: { selected }, set: { if let u = $0 { pick(u) } })) {
            ForEach(items) { item in
                HStack(spacing: 6) {
                    Thumb(url: item.url, side: 16, iconOnly: true)
                    Text(item.name).lineLimit(1)
                    Spacer()
                    if item.isFolderLike { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary) }
                }
                .tag(item.url)
                .contextMenu { FileMenu(urls: [item.url]) }
                .onDrag { NSItemProvider(object: item.url as NSURL) }
            }
        }
        .contextMenu(forSelectionType: URL.self) { _ in } primaryAction: { s in if let u = s.first { open(u) } }
        .frame(width: 230)
        .task(id: dir.path + "\(hidden)") {
            let d = dir, h = hidden
            items = await Task.detached { FileItem.list(d, hidden: h).sorted { a, b in
                if a.isFolderLike != b.isFolderLike { return a.isFolderLike }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending } }.value
        }
    }
}

private struct ColumnPreview: View {
    let url: URL
    var body: some View {
        VStack(spacing: 10) {
            Thumb(url: url, side: 180)
            Text(url.lastPathComponent).font(.headline).multilineTextAlignment(.center)
            if let item = FileItem(url: url) {
                Text("\(item.kind.title) · \(Fmt.size(item.size))").foregroundStyle(.secondary)
                Text("Modified \(Fmt.when(item.modified))").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }.padding()
    }
}

// MARK: - Menus

struct FileMenu: View {
    let urls: [URL]
    @EnvironmentObject var model: AppModel
    @AppStorage("devFeatures") private var dev = false

    var body: some View {
        if let first = urls.first {
            Button("Open") { urls.forEach { model.openItem($0) } }
            if urls.count == 1, isFolder(first) { Button("Open in New Tab") { model.open(folder: first, newTab: true) } }
            Menu("Open With") {
                ForEach(NSWorkspace.shared.urlsForApplications(toOpen: first).prefix(12), id: \.self) { app in
                    Button(FileManager.default.displayName(atPath: app.path)) {
                        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: .init())
                    }
                }
            }
            Divider()
            Button(urls.count == 1 ? "Rename…" : "Rename \(urls.count) Items…") {
                if urls.count == 1 { model.renameTarget = first } else { model.bulkRename = urls }
            }
            Button("Duplicate") { FileOps.duplicate(urls) }
            Button("Copy") { FileOps.copyToPasteboard(urls) }
            Button("Compress to ZIP") { Task { await ArchiveTools.zip(urls) } }
            if urls.count == 1, ArchiveTools.canExtract(first) { Button("Extract Here") { Task { await ArchiveTools.extract(first, into: first.deletingLastPathComponent()) } } }
            Divider()
            Menu("Tags") {
                ForEach(Tags.colors, id: \.0) { t in
                    Button { toggleTag(t.0) } label: { Label(t.0, systemImage: urls.allSatisfy { Tags.get($0).contains(t.0) } ? "checkmark.circle.fill" : "circle.fill") }
                }
            }
            Menu("Copy Path As") {
                Button("Path") { FileOps.copyPath(urls, style: 0) }
                Button("Terminal-ready Path") { FileOps.copyPath(urls, style: 1) }
                Button("File URL") { FileOps.copyPath(urls, style: 2) }
            }
            if urls.count == 1, isFolder(first) {
                Button(model.pinned.contains(first) ? "Unpin from Sidebar" : "Pin to Sidebar") { model.togglePin(first) }
                Button("Show in Disk Usage") { DiskScan.shared.scan(first); model.show(.diskUsage) }
            }
            if model.splitTab != nil {
                Button("Copy to Other Pane") { model.sendToOtherPane(copy: true) }
                Button("Move to Other Pane") { model.sendToOtherPane(copy: false) }
            }
            Button("Get Info") { model.inspected = first; model.showInspector = true }
            Button("Show in Finder") { FileOps.reveal(urls) }
            if dev {
                Button("Open in Terminal") { NSWorkspace.shared.open([isFolder(first) ? first : first.deletingLastPathComponent()], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"), configuration: .init()) }
            }
            Menu("Tools") {
                ForEach(ToolCatalog.tools(for: urls).prefix(14)) { t in
                    Button { ToolInbox.shared.files = urls; model.show(.tool(t.id)) } label: { Label(t.name, systemImage: t.symbol) }
                }
            }
            Divider()
            Button("Move to Trash", role: .destructive) { FileOps.trash(urls) }
        }
    }
    private func isFolder(_ u: URL) -> Bool {
        let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]); return (v?.isDirectory ?? false) && !(v?.isPackage ?? false)
    }
    private func toggleTag(_ t: String) {
        let all = urls.allSatisfy { Tags.get($0).contains(t) }
        for u in urls { var tags = Tags.get(u); if all { tags.removeAll { $0 == t } } else if !tags.contains(t) { tags.append(t) }; Tags.set(u, tags) }
        FileOps.changed()
    }
}

struct BackgroundMenu: View {
    @ObservedObject var tab: BrowserTab
    @Binding var sort: String
    @EnvironmentObject var model: AppModel
    var body: some View {
        Button("New Folder") { model.newFolder() }
        Button("Paste") { model.paste(move: false) }.disabled(FileOps.pasteboardURLs().isEmpty)
        Divider()
        Picker("Sort By", selection: $sort) { Text("Name").tag("name"); Text("Date Modified").tag("date"); Text("Size").tag("size"); Text("Kind").tag("kind") }
        Button("Organize This Folder…") { OrganizeState.shared.folder = tab.url; model.show(.organize) }
        Button("Show in Finder") { NSWorkspace.shared.open(tab.url) }
    }
}
