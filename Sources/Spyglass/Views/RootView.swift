import SwiftUI

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("theme") private var theme = "playful"
    @State private var columns = NavigationSplitViewVisibility.all
    @ObservedObject private var transfers = TransferQueue.shared

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        } detail: {
            ZStack(alignment: .bottom) {
                Detail()
                    .id(theme)
                ToastView()
                TransfersOverlay().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
            .toolbar { MainToolbar() }
            .glassThemeRoot()
            .inspector(isPresented: $model.showInspector) {
                InspectorView(url: model.inspected).inspectorColumnWidth(min: 240, ideal: 280, max: 400)
            }
        }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search, e.g. pdfs from last week over 5 MB")
        .onSubmit(of: .search) { if !model.searchText.isEmpty { model.show(.search(model.searchText)) } }
        .sheet(isPresented: $model.goToFolder) { GoToFolderSheet() }
        .sheet(item: $transfers.conflict) { ConflictSheet(c: $0).interactiveDismissDisabled() }
        .sheet(item: Binding(get: { model.bulkRename.map(URLList.init) }, set: { model.bulkRename = $0?.urls })) { BulkRenameSheet(urls: $0.urls) }
        .navigationTitle(model.page == .folder ? model.tab.title : model.page.title)
    }
}

struct URLList: Identifiable { let urls: [URL]; var id: String { urls.map(\.path).joined() } }

struct Detail: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.glassOn) private var glassOn
    var body: some View {
        Group {
            switch model.page {
            case .home: HomeView()
            case .folder: BrowserView()
            case .recents: SpotlightListView(title: "Recents", subtitle: "Files you opened in the last 30 days", symbol: "clock",
                                             query: "kMDItemLastUsedDate >= \(Spotlight.iso(Date().addingTimeInterval(-30 * 86400)))", sort: "kMDItemLastUsedDate")
            case .library(let k): SpotlightListView(title: k.title, subtitle: nil, symbol: k.symbol, query: k.query, scopes: k.scopes, kind: k.fileKind)
            case .search(let q): SearchView(text: q)
            case .downloadedFrom: DownloadedFromView()
            case .cloud: CloudDrivesView()
            case .photos: PhotosView()
            case .imageText: ImageTextView()
            case .routines: RoutinesView()
            case .cleanup: CleanupView()
            case .duplicates: DuplicatesView()
            case .largeFiles: LargeFilesView()
            case .spaceMap: SpaceMapView()
            case .diskUsage: DiskUsageView()
            case .uninstaller: UninstallerView()
            case .caches: CachesView()
            case .startup: StartupItemsView()
            case .health: HealthView()
            case .memory: MemoryView()
            case .activity: ActivityView()
            case .organize: OrganizeView()
            case .assistant: AssistantView()
            case .tools(let c): ToolsGridView(category: c)
            case .tool(let id): ToolHost(id: id)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassBackdrop(glassOn && !Self.isFileList(model.page))
        .transition(.opacity)
    }

    /// Pages that are mostly a file list keep their plain, readable background.
    static func isFileList(_ p: Page) -> Bool {
        switch p {
        case .folder, .recents, .downloadedFrom, .library, .search, .cloud, .photos, .imageText: return true
        default: return false
        }
    }
}

struct MainToolbar: ToolbarContent {
    @EnvironmentObject var model: AppModel
    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { model.goBack() } label: { Image(systemName: "chevron.left") }
                .help("Back").disabled(model.page == .folder ? !model.tab.canGoBack && model.pageHistory.isEmpty : model.pageHistory.isEmpty)
            Button { model.tab.goForward() } label: { Image(systemName: "chevron.right") }
                .help("Forward").disabled(model.page != .folder || !model.tab.canGoForward)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if model.page == .folder {
                FolderToolbarItems(tab: model.tab)
            }
            if model.page == .folder {
                Button { model.toggleSplit() } label: { Image(systemName: model.splitTab == nil ? "rectangle.split.2x1" : "rectangle.split.2x1.fill") }.help("Split View (⌥⌘S)")
            }
            Button { QuickSearchPanel.shared.toggle() } label: { Image(systemName: "command") }.help("Quick Search (⌘K)")
            Button { model.showInspector.toggle() } label: { Image(systemName: "sidebar.right") }.help("Inspector (⌘I)")
        }
    }
}

struct FolderToolbarItems: View {
    @ObservedObject var tab: BrowserTab
    @EnvironmentObject var model: AppModel
    var body: some View {
        Picker("View", selection: $tab.mode) {
            ForEach(ViewMode.allCases, id: \.self) { Image(systemName: $0.symbol).tag($0) }
        }
        .pickerStyle(.segmented).help("View as icons, list or columns (⌘1, ⌘2, ⌘3)")
        Menu {
            Button("New Folder") { model.newFolder() }
            Button("New Tab") { model.addTab() }
            Divider()
            Button(model.pinned.contains(tab.url) ? "Unpin from Sidebar" : "Pin to Sidebar") { model.togglePin(tab.url) }
            Button("Organize This Folder…") { OrganizeState.shared.folder = tab.url; model.show(.organize) }
            Button("Open in Disk Usage") { DiskScan.shared.scan(tab.url); model.show(.diskUsage) }
            Button("Open in Terminal") { NSWorkspace.shared.open([tab.url], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"), configuration: .init()) }
            Button("Show in Finder") { NSWorkspace.shared.open(tab.url) }
            Divider()
            Button("Copy Path") { FileOps.copyPath([tab.url]) }
        } label: { Image(systemName: "ellipsis.circle") }
    }
}

struct GoToFolderSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var path = "~/"
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Go to Folder").font(.headline)
            TextField("Path", text: $path).textFieldStyle(.roundedBorder).frame(width: 380).onSubmit(go)
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Button("Go", action: go).keyboardShortcut(.defaultAction) }
        }.padding(20)
    }
    func go() {
        let u = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: u.path) else { NSSound.beep(); return }
        dismiss(); model.openItem(u)
    }
}

/// Shared page header used by dashboard-style pages.
struct PageHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    var symbol: String
    var tint: Color = .accentColor
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 40, height: 40).background(tint.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title2.weight(.semibold))
                if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary) }
            }
            Spacer()
            trailing
        }
    }
}
extension PageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, symbol: String, tint: Color = .accentColor) {
        self.init(title: title, subtitle: subtitle, symbol: symbol, tint: tint) { EmptyView() }
    }
}

struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content
    @Environment(\.glassOn) private var glassOn
    var body: some View {
        // Edge-to-edge cards (padding 0) hold lists, so they keep the solid, readable surface.
        if glassOn && padding > 0 {
            content
                .padding(padding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassPanel(true, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        } else {
            content
                .padding(padding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
                .shadow(color: .black.opacity(0.04), radius: 3, y: 1)
        }
    }
}

struct EmptyState: View {
    let symbol: String, title: String
    var message: String = ""
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 42, weight: .light)).foregroundStyle(.tertiary)
            Text(title).font(.title3.weight(.medium))
            if !message.isEmpty { Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding()
    }
}
