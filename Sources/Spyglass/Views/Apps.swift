import SwiftUI

struct AppEntry: Identifiable, Hashable {
    let url: URL
    let name: String
    let bundleID: String
    let size: Int64
    let lastUsed: Date?
    var id: URL { url }
}

struct UninstallerView: View {
    @State private var apps: [AppEntry] = []
    @State private var picked: AppEntry?
    @State private var leftovers: [CleanItem] = []
    @State private var marked = Set<URL>()
    @State private var loading = true
    @State private var filter = ""
    @State private var sortBy = 0
    @AppStorage("resetPermissionsOnUninstall") private var resetPerms = true

    var shown: [AppEntry] {
        let f = apps.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }
        switch sortBy {
        case 1: return f.sorted { $0.size > $1.size }
        case 2: return f.sorted { ($0.lastUsed ?? .distantPast) < ($1.lastUsed ?? .distantPast) }
        default: return f.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "App Uninstaller", subtitle: "Removes an app and the files it left behind. Apple apps are never listed.", symbol: "xmark.app.fill", tint: .red).padding(20)
            HSplitView {
                VStack(spacing: 6) {
                    HStack {
                        TextField("Filter", text: $filter).textFieldStyle(.roundedBorder)
                        Picker("", selection: $sortBy) { Text("Name").tag(0); Text("Size").tag(1); Text("Last Used").tag(2) }.frame(width: 100)
                    }.padding(.horizontal, 8)
                    if loading { ProgressView().frame(maxHeight: .infinity) }
                    List(shown, selection: $picked) { a in
                        HStack(spacing: 8) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: a.url.path)).resizable().frame(width: 28, height: 28)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(a.name)
                                Text(a.lastUsed.map { "Opened \(Fmt.ago($0))" } ?? "Never opened").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(Fmt.size(a.size)).foregroundStyle(.secondary).monospacedDigit()
                        }.tag(a)
                    }
                }.frame(minWidth: 300, idealWidth: 340)
                Group {
                    if let a = picked {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 12) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: a.url.path)).resizable().frame(width: 56, height: 56)
                                VStack(alignment: .leading) { Text(a.name).font(.title2.weight(.semibold)); Text(a.bundleID).font(.caption).foregroundStyle(.secondary) }
                            }
                            Text("\(leftovers.count + 1) items · \(Fmt.size(leftovers.filter { marked.contains($0.url) }.reduce(a.size) { $0 + $1.size }))").foregroundStyle(.secondary)
                            List {
                                HStack { Image(systemName: "checkmark.square.fill").foregroundStyle(.secondary); Text(a.url.lastPathComponent); Spacer(); Text(Fmt.size(a.size)).foregroundStyle(.secondary) }
                                ForEach(leftovers) { l in
                                    HStack {
                                        Toggle("", isOn: Binding(get: { marked.contains(l.url) }, set: { if $0 { marked.insert(l.url) } else { marked.remove(l.url) } })).toggleStyle(.checkbox).labelsHidden()
                                        VStack(alignment: .leading) { Text(l.url.lastPathComponent); Text(Places.displayPath(l.url.deletingLastPathComponent())).font(.caption).foregroundStyle(.secondary) }
                                        Spacer()
                                        Text(Fmt.size(l.size)).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            Toggle("Also reset its privacy permissions (camera, microphone, files…)", isOn: $resetPerms).toggleStyle(.checkbox)
                            HStack {
                                Spacer()
                                Button(role: .destructive) { uninstall(a) } label: { Label("Uninstall", systemImage: "trash") }.buttonStyle(.borderedProminent).tint(.red)
                            }
                        }.padding(16)
                    } else { EmptyState(symbol: "app.dashed", title: "Pick an app", message: "Spyglass finds its caches, preferences, containers and support files.") }
                }.frame(minWidth: 380)
            }
        }
        .task { await load() }
        .onChange(of: picked) { _, a in if let a { findLeftovers(a) } }
    }

    func load() async {
        apps = await Task.detached {
            var out: [AppEntry] = []
            for dir in [Places.applications, Places.home.appendingPathComponent("Applications"), Places.applications.appendingPathComponent("Utilities")] {
                for u in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [] where u.pathExtension == "app" {
                    let b = Bundle(url: u)
                    let id = b?.bundleIdentifier ?? ""
                    if id.hasPrefix("com.apple.") || id == Bundle.main.bundleIdentifier { continue }
                    if (try? FileManager.default.attributesOfItem(atPath: u.path)[.ownerAccountName] as? String) == "root" && id.isEmpty { continue }
                    out.append(AppEntry(url: u, name: FileManager.default.displayName(atPath: u.path).replacingOccurrences(of: ".app", with: ""), bundleID: id, size: Sizer.size(of: u), lastUsed: Meta.lastUsed(u)))
                }
            }
            return out
        }.value
        loading = false
    }

    func findLeftovers(_ a: AppEntry) {
        let id = a.bundleID, name = a.name
        Task {
            let found = await Task.detached { () -> [CleanItem] in
                var out: [CleanItem] = []
                let lib = Places.library
                let dirs = ["Application Support", "Caches", "Preferences", "Containers", "Group Containers", "Saved Application State", "Logs", "HTTPStorages", "WebKit", "LaunchAgents", "Application Scripts", "Cookies"]
                for d in dirs {
                    let base = lib.appendingPathComponent(d)
                    for u in (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? [] {
                        let n = u.lastPathComponent
                        let match = (!id.isEmpty && (n == id || n.hasPrefix(id + ".") || n.hasSuffix("." + id) || n.contains(id))) || n == name || n == name + ".savedState"
                        if match { out.append(CleanItem(url: u, size: Sizer.size(of: u), date: .distantPast)) }
                    }
                }
                return out
            }.value
            leftovers = found; marked = Set(found.map(\.url))
        }
    }

    func uninstall(_ a: AppEntry) {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: a.bundleID).first { running.terminate(); Thread.sleep(forTimeInterval: 0.6) }
        let urls = [a.url] + leftovers.filter { marked.contains($0.url) }.map(\.url)
        FileOps.trash(urls, kind: .uninstall, title: "Uninstalled \(a.name)")
        if resetPerms, !a.bundleID.isEmpty {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil"); p.arguments = ["reset", "All", a.bundleID]; try? p.run()
        }
        apps.removeAll { $0.id == a.id }; picked = nil; leftovers = []
    }
}

struct CachesView: View {
    @State private var items: [CleanItem] = []
    @State private var selection = Set<URL>()
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "App Caches", subtitle: "\(Fmt.size(items.reduce(0) { $0 + $1.size })) in \(items.count) caches · apps rebuild these when needed", symbol: "shippingbox.fill", tint: .brown) {
                HStack {
                    Button("Select Safe") { selection = Set(items.filter(\.safe).map(\.url)) }
                    Button { FileOps.trash(Array(selection), kind: .cleanup, title: "Cleared \(selection.count) caches"); items.removeAll { selection.contains($0.url) }; selection = [] } label: { Label("Move to Trash", systemImage: "trash") }.disabled(selection.isEmpty)
                }
            }.padding(20)
            Divider()
            if loading { ProgressView().frame(maxHeight: .infinity) }
            else {
                Table(items, selection: $selection) {
                    TableColumn("Cache") { i in VStack(alignment: .leading) { Text(i.url.lastPathComponent); Text(Places.displayPath(i.url.deletingLastPathComponent())).font(.caption).foregroundStyle(.secondary) } }
                    TableColumn("Status") { i in Text(i.safe ? "Safe" : "Check First").font(.caption).padding(.horizontal, 6).padding(.vertical, 2).background((i.safe ? Color.green : .orange).opacity(0.2), in: Capsule()).help(i.note ?? "") }.width(100)
                    TableColumn("Size") { Text(Fmt.size($0.size)).monospacedDigit() }.width(90)
                }
            }
        }
        .task {
            items = await Task.detached {
                var out: [CleanItem] = []
                for base in [Places.library.appendingPathComponent("Caches"), Places.library.appendingPathComponent("Logs")] {
                    for u in (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? [] {
                        let s = Sizer.size(of: u)
                        guard s > 1_000_000 else { continue }
                        let n = u.lastPathComponent.lowercased()
                        let risky = n.hasPrefix("com.apple.") || n.contains("cloudkit") || n.contains("spotlight") || n.contains("keychain") || n.contains("sync") || n.contains("signin") || n.contains("auth")
                        out.append(CleanItem(url: u, size: s, date: .distantPast, safe: !risky, note: risky ? "May hold sign-ins, sync state or a search index" : nil))
                    }
                }
                return out.sorted { $0.size > $1.size }
            }.value
            loading = false
        }
    }
}
