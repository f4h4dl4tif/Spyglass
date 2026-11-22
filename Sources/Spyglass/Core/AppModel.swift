import SwiftUI
import AppKit

enum Room: String, CaseIterable, Identifiable {
    case look, sweep, tools
    var id: String { rawValue }
    var title: String { switch self { case .look: "Look"; case .sweep: "Sweep"; case .tools: "Tools" } }
    var symbol: String { switch self { case .look: "eye"; case .sweep: "sparkles"; case .tools: "wrench.and.screwdriver" } }
}

enum Page: Hashable {
    case home, folder, recents, downloadedFrom, library(LibraryKind), search(String), cloud, photos, imageText
    case cleanup, duplicates, largeFiles, spaceMap, diskUsage, uninstaller, caches, startup, health, memory, activity, organize, assistant, routines
    case tools(ToolCategory?), tool(String)

    var room: Room {
        switch self {
        case .home, .folder, .recents, .downloadedFrom, .library, .search, .cloud, .photos, .imageText: .look
        case .tools, .tool: .tools
        default: .sweep
        }
    }
    var title: String {
        switch self {
        case .home: "Home"; case .folder: "Folder"; case .recents: "Recents"; case .downloadedFrom: "Downloaded From"
        case .library(let k): k.title; case .search(let q): q.isEmpty ? "Search" : "“\(q)”"; case .cloud: "Cloud Drives"
        case .photos: "Photos"; case .imageText: "Text in Images"; case .routines: "Routines"
        case .cleanup: "Clean Up"; case .duplicates: "Duplicates"; case .largeFiles: "Large Files"; case .spaceMap: "Space Map"
        case .diskUsage: "Disk Usage"; case .uninstaller: "App Uninstaller"; case .caches: "App Caches"; case .startup: "Startup Items"
        case .health: "Mac Health"; case .memory: "Memory"; case .activity: "Activity"; case .organize: "Organize"; case .assistant: "Assistant"
        case .tools(let c): c?.title ?? "All Tools"; case .tool(let id): ToolCatalog.tool(id)?.name ?? "Tool"
        }
    }
}

enum ViewMode: String, CaseIterable { case grid, list, columns
    var symbol: String { switch self { case .grid: "square.grid.2x2"; case .list: "list.bullet"; case .columns: "rectangle.split.3x1" } }
}

/// One browser tab: its own location, history, view mode and selection.
@MainActor final class BrowserTab: ObservableObject, Identifiable {
    let id = UUID()
    @Published private(set) var url: URL
    @Published var items: [FileItem] = []
    @Published var selection = Set<URL>()
    @Published var mode: ViewMode
    @Published var columnPath: [URL] = []
    private(set) var back: [URL] = []
    private(set) var forward: [URL] = []
    private var watcher: DispatchSourceFileSystemObject?
    private var loadToken = 0

    init(url: URL, mode: ViewMode = .grid) { self.url = url; self.mode = mode; load() }

    var title: String { url.path == "/" ? "Macintosh HD" : FileManager.default.displayName(atPath: url.path) }
    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }

    func go(_ u: URL, record: Bool = true) {
        guard u.standardizedFileURL != url.standardizedFileURL else { return }
        if record { back.append(url); forward.removeAll() }
        url = u; selection = []; load()
    }
    func goBack() { guard let u = back.popLast() else { return }; forward.append(url); url = u; selection = []; load() }
    func goForward() { guard let u = forward.popLast() else { return }; back.append(url); url = u; selection = []; load() }
    func goUp() { let p = url.deletingLastPathComponent(); if p.path != url.path { let old = url; go(p); selection = [old] } }

    func load() {
        loadToken += 1
        let token = loadToken, dir = url, hidden = UserDefaults.standard.bool(forKey: "showHidden")
        DispatchQueue.global(qos: .userInitiated).async {
            let list = FileItem.list(dir, hidden: hidden)
            DispatchQueue.main.async {
                guard token == self.loadToken else { return }
                self.items = list
                self.selection = self.selection.filter { s in list.contains { $0.url == s } }
                self.watch()
            }
        }
    }

    private func watch() {
        watcher?.cancel()
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self] in self?.load() }
        src.setCancelHandler { close(fd) }
        src.resume()
        watcher = src
    }
    deinit { watcher?.cancel() }
}

@MainActor final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var page: Page = .home
    @Published var room: Room = .look
    @Published var tabs: [BrowserTab] = []
    @Published var activeTabID: UUID?
    @Published var splitTab: BrowserTab?
    @Published var rightFocused = false
    @Published var showInspector = false
    @Published var inspected: URL?
    @Published var searchText = ""
    @Published var renameTarget: URL?
    @Published var bulkRename: [URL]?
    @Published var goToFolder = false
    @Published var pageHistory: [Page] = []

    @AppStorage("pinned") private var pinnedRaw = ""
    @AppStorage("savedSearches") private var savedRaw = ""
    @AppStorage("defaultViewMode") var defaultMode = ViewMode.grid.rawValue

    init() {
        let t = BrowserTab(url: Places.home, mode: ViewMode(rawValue: UserDefaults.standard.string(forKey: "defaultViewMode") ?? "") ?? .grid)
        tabs = [t]; activeTabID = t.id
    }

    var leftTab: BrowserTab { tabs.first { $0.id == activeTabID } ?? tabs[0] }
    /// The pane the user is working in (right pane when split view is on and focused).
    var tab: BrowserTab { rightFocused ? (splitTab ?? leftTab) : leftTab }
    var otherPane: BrowserTab? { guard let s = splitTab else { return nil }; return rightFocused ? leftTab : s }

    func toggleSplit() {
        if splitTab == nil { splitTab = BrowserTab(url: leftTab.url, mode: leftTab.mode == .columns ? .list : leftTab.mode); rightFocused = true }
        else { splitTab = nil; rightFocused = false }
        if page != .folder { show(.folder) }
    }
    func sendToOtherPane(copy: Bool) {
        guard let other = otherPane else { return }
        let s = selectedURLs
        if !s.isEmpty { FileOps.move(s, into: other.url, copy: copy) }
    }

    // Navigation
    func show(_ p: Page) {
        if p != page { pageHistory.append(page); if pageHistory.count > 50 { pageHistory.removeFirst() } }
        withAnimation(.easeOut(duration: 0.15)) { page = p; room = p.room }
        NSApp.activate(ignoringOtherApps: true)
        WindowOpener.openMain()
    }
    func open(folder u: URL, newTab: Bool = false) {
        if newTab { addTab(u) } else { tab.go(u) }
        show(.folder)
    }
    func reveal(_ u: URL) {
        open(folder: u.deletingLastPathComponent())
        let t = tab
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { t.selection = [u] }
    }
    func openItem(_ u: URL, newTab: Bool = false) {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir)
        let pkg = (try? u.resourceValues(forKeys: [.isPackageKey]).isPackage) ?? false
        if isDir.boolValue && !pkg { open(folder: u, newTab: newTab) } else { FileOps.open(u) }
    }
    func goBack() {
        if page == .folder, tab.canGoBack { tab.goBack() }
        else if let p = pageHistory.popLast() { withAnimation(.easeOut(duration: 0.15)) { page = p; room = p.room } }
    }

    // Tabs
    func addTab(_ u: URL? = nil) {
        let t = BrowserTab(url: u ?? tab.url, mode: tab.mode)
        tabs.append(t); activeTabID = t.id; rightFocused = false
        if page != .folder { show(.folder) }
    }
    func closeTab(_ id: UUID? = nil) {
        let id = id ?? activeTabID
        guard tabs.count > 1, let i = tabs.firstIndex(where: { $0.id == id }) else { if page == .folder { NSApp.keyWindow?.performClose(nil) }; return }
        tabs.remove(at: i)
        if activeTabID == id { activeTabID = tabs[min(i, tabs.count - 1)].id }
    }
    func nextTab() {
        guard let i = tabs.firstIndex(where: { $0.id == activeTabID }) else { return }
        activeTabID = tabs[(i + 1) % tabs.count].id
    }

    // Pinned & saved
    var pinned: [URL] { pinnedRaw.split(separator: "\n").map { URL(fileURLWithPath: String($0)) } }
    func togglePin(_ u: URL) {
        var p = pinned.map(\.path)
        if let i = p.firstIndex(of: u.path) { p.remove(at: i) } else { p.append(u.path) }
        pinnedRaw = p.joined(separator: "\n"); objectWillChange.send()
    }
    var savedSearches: [String] { savedRaw.split(separator: "\n").map(String.init) }
    func saveSearch(_ q: String) {
        guard !q.isEmpty, !savedSearches.contains(q) else { return }
        savedRaw = (savedSearches + [q]).joined(separator: "\n"); objectWillChange.send()
        ActivityLog.shared.show("Saved search “\(q)”")
    }
    func removeSearch(_ q: String) { savedRaw = savedSearches.filter { $0 != q }.joined(separator: "\n"); objectWillChange.send() }

    func toggleTheme() {
        let d = UserDefaults.standard
        d.set(d.string(forKey: "theme") == "minimal" ? "playful" : "minimal", forKey: "theme")
    }
    func toggleHidden() {
        let d = UserDefaults.standard
        d.set(!d.bool(forKey: "showHidden"), forKey: "showHidden")
        tabs.forEach { $0.load() }
    }

    // Edit actions on the active selection
    var selectedURLs: [URL] { page == .folder ? Array(tab.selection) : [] }
    func trashSelection() { let s = selectedURLs; if !s.isEmpty { FileOps.trash(s) } }
    func duplicateSelection() { let s = selectedURLs; if !s.isEmpty { FileOps.duplicate(s) } }
    func copySelection() { let s = selectedURLs; if !s.isEmpty { FileOps.copyToPasteboard(s); ActivityLog.shared.show("Copied \(s.count) item\(s.count == 1 ? "" : "s")") } }
    func paste(move: Bool) {
        let urls = FileOps.pasteboardURLs()
        guard page == .folder, !urls.isEmpty else { return }
        FileOps.move(urls, into: tab.url, copy: !move)
    }
    func newFolder() {
        guard page == .folder, let u = FileOps.newFolder(in: tab.url) else { return }
        let t = tab
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { t.selection = [u]; self.renameTarget = u }
    }
}

/// Lets non-view code (menu bar, hotkeys) bring the main window back.
@MainActor enum WindowOpener {
    static var action: (() -> Void)?
    static func openMain() {
        if let w = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" || $0.title == "Spyglass" }), w.isVisible || w.isMiniaturized {
            w.makeKeyAndOrderFront(nil); return
        }
        action?()
    }
}

/// Theme helper: Playful paints kinds in their colour, Minimal keeps the library grey.
struct Theme {
    static var playful: Bool { UserDefaults.standard.string(forKey: "theme") != "minimal" }
    static func tint(_ k: FileKind) -> Color { playful ? k.color : .secondary }
}
