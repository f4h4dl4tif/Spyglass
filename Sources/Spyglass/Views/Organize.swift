import SwiftUI

@MainActor final class OrganizeState: ObservableObject {
    static let shared = OrganizeState()
    @Published var folder = Places.downloads
}

enum Organizer {
    struct Plan: Identifiable { let id = UUID(); let from: URL; let to: URL }

    /// Loose files (not folders, apps, code projects or anything touched in the last hour) sorted into subfolders.
    static func plan(_ dir: URL, byMonth: Bool, minAgeHours: Double = 1) -> [Plan] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .contentModificationDateKey, .addedToDirectoryDateKey]
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])) ?? []
        if items.contains(where: { [".git", "package.json", "Package.swift", "Cargo.toml"].contains($0.lastPathComponent) }) { return [] }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM MMMM"
        let cutoff = Date().addingTimeInterval(-minAgeHours * 3600)
        return items.compactMap { u in
            guard let v = try? u.resourceValues(forKeys: keys), v.isDirectory != true else { return nil }
            let mod = v.contentModificationDate ?? Date()
            guard mod < cutoff, (v.addedToDirectoryDate ?? .distantPast) < cutoff else { return nil }
            if u.pathExtension == "download" || u.pathExtension == "crdownload" || u.pathExtension == "part" { return nil }
            let folder: String
            if byMonth { folder = f.string(from: mod) }
            else {
                let k = FileKind.of(u, isDirectory: false)
                folder = u.pathExtension.lowercased() == "pdf" ? "PDFs" : (k == .other ? "Other" : (k == .audio ? "Music" : k.title + "s"))
            }
            return Plan(from: u, to: dir.appendingPathComponent(folder).appendingPathComponent(u.lastPathComponent))
        }
    }

    @MainActor static func apply(_ plans: [Plan], title: String) {
        var moves: [Move] = []
        for p in plans {
            try? FileManager.default.createDirectory(at: p.to.deletingLastPathComponent(), withIntermediateDirectories: true)
            let dest = FileOps.uniqueURL(p.to)
            if (try? FileManager.default.moveItem(at: p.from, to: dest)) != nil { moves.append(Move(from: p.from.path, to: dest.path)) }
        }
        ActivityLog.shared.record(.organize, title, moves: moves)
        FileOps.changed()
    }

    @MainActor static func runKeepOrganized() {
        let d = UserDefaults.standard
        guard d.bool(forKey: "keepOrganized") else { return }
        for path in (d.string(forKey: "keepOrganizedFolders") ?? Places.downloads.path).split(separator: "\n") {
            let u = URL(fileURLWithPath: String(path))
            let plans = plan(u, byMonth: d.bool(forKey: "organizeByMonth"), minAgeHours: 24)
            if !plans.isEmpty { apply(plans, title: "Kept \(u.lastPathComponent) organized (\(plans.count) files)") }
        }
    }
}

struct OrganizeView: View {
    @ObservedObject var state = OrganizeState.shared
    @State private var byMonth = false
    @State private var plans: [Organizer.Plan] = []
    @AppStorage("keepOrganized") private var keep = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(title: "Organize", subtitle: "Sort loose files into folders by kind or month. Preview first; undo any time.", symbol: "square.grid.3x1.folder.badge.plus", tint: .mint)
            HStack {
                Button { if let u = pickFolder() { state.folder = u } } label: { Label(Places.displayPath(state.folder), systemImage: "folder") }
                Picker("Sort by", selection: $byMonth) { Text("Kind").tag(false); Text("Month").tag(true) }.pickerStyle(.segmented).frame(width: 180)
                Spacer()
                Toggle("Keep Organized (every few hours)", isOn: $keep).toggleStyle(.switch)
                    .onChange(of: keep) { _, on in if on { UserDefaults.standard.set(state.folder.path, forKey: "keepOrganizedFolders"); UserDefaults.standard.set(byMonth, forKey: "organizeByMonth") } }
            }
            if plans.isEmpty { EmptyState(symbol: "checkmark.circle", title: "Nothing to organize", message: "Spyglass leaves folders, apps, code projects and files you're still using alone.") }
            else {
                let grouped = Dictionary(grouping: plans) { $0.to.deletingLastPathComponent().lastPathComponent }
                List {
                    ForEach(grouped.keys.sorted(), id: \.self) { k in
                        Section("\(k) · \(grouped[k]!.count)") {
                            ForEach(grouped[k]!) { p in HStack { Thumb(url: p.from, side: 20); Text(p.from.lastPathComponent).lineLimit(1) } }
                        }
                    }
                }
                HStack { Spacer(); Button("Organize \(plans.count) Files") { Organizer.apply(plans, title: "Organized \(state.folder.lastPathComponent) (\(plans.count) files)"); reload() }.buttonStyle(.borderedProminent) }
            }
        }
        .padding(20)
        .task(id: "\(state.folder.path)\(byMonth)") { reload() }
    }
    func reload() { plans = Organizer.plan(state.folder, byMonth: byMonth) }
}

// MARK: - Bulk rename

struct BulkRenameSheet: View {
    let urls: [URL]
    @Environment(\.dismiss) var dismiss
    @State private var mode = 0
    @State private var find = ""
    @State private var replace = ""
    @State private var addText = ""
    @State private var addAfter = false
    @State private var format = "{name} {n}"
    @State private var start = 1
    @State private var caseMode = 0

    func newName(_ u: URL, _ i: Int) -> String {
        let base = u.deletingPathExtension().lastPathComponent, ext = u.pathExtension
        var n: String
        switch mode {
        case 0: n = find.isEmpty ? base : base.replacingOccurrences(of: find, with: replace)
        case 1: n = addAfter ? base + addText : addText + base
        case 2:
            let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
            let mod = (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            n = format.replacingOccurrences(of: "{name}", with: base)
                .replacingOccurrences(of: "{n}", with: String(format: "%0\(max(2, String(urls.count + start).count))d", i + start))
                .replacingOccurrences(of: "{date}", with: df.string(from: mod))
                .replacingOccurrences(of: "{ext}", with: ext)
        default:
            n = caseMode == 0 ? base.lowercased() : caseMode == 1 ? base.uppercased() : caseMode == 2 ? base.capitalized
                : base.lowercased().replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: "_", with: "-")
        }
        return ext.isEmpty ? n : n + "." + ext
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename \(urls.count) Items").font(.headline)
            Picker("", selection: $mode) { Text("Replace Text").tag(0); Text("Add Text").tag(1); Text("Format").tag(2); Text("Change Case").tag(3) }.pickerStyle(.segmented)
            Group {
                switch mode {
                case 0: HStack { TextField("Find", text: $find); TextField("Replace with", text: $replace) }
                case 1: HStack { TextField("Text", text: $addText); Picker("", selection: $addAfter) { Text("Before name").tag(false); Text("After name").tag(true) }.frame(width: 140) }
                case 2: HStack { TextField("Format", text: $format); Stepper("Start at \(start)", value: $start, in: 0...9999) }
                    Text("Tokens: {name} {n} {date} {ext}").font(.caption).foregroundStyle(.secondary)
                default: Picker("", selection: $caseMode) { Text("lowercase").tag(0); Text("UPPERCASE").tag(1); Text("Title Case").tag(2); Text("kebab-case").tag(3) }.pickerStyle(.segmented)
                }
            }.textFieldStyle(.roundedBorder)
            List(Array(urls.enumerated()), id: \.offset) { i, u in
                HStack { Text(u.lastPathComponent).foregroundStyle(.secondary).lineLimit(1); Image(systemName: "arrow.right").font(.caption); Text(newName(u, i)).lineLimit(1) }
            }.frame(height: 220)
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Button("Rename") { apply() }.keyboardShortcut(.defaultAction) }
        }.padding(20).frame(width: 560)
    }

    func apply() {
        var moves: [Move] = []
        for (i, u) in urls.enumerated() {
            let n = newName(u, i)
            guard n != u.lastPathComponent, !n.contains("/") else { continue }
            let dest = FileOps.uniqueURL(u.deletingLastPathComponent().appendingPathComponent(n))
            if (try? FileManager.default.moveItem(at: u, to: dest)) != nil { moves.append(Move(from: u.path, to: dest.path)) }
        }
        ActivityLog.shared.record(.rename, "Renamed \(moves.count) items", moves: moves)
        FileOps.changed()
        dismiss()
    }
}

// MARK: - Assistant (on-device, plan → review → run)

struct AssistantView: View {
    struct Step: Identifiable { let id = UUID(); let text: String; let symbol: String }
    enum Action { case trash([URL]), zip([URL]), move([URL], URL), organize(URL, Bool), tag([URL], String), show(String) }
    @State private var prompt = ""
    @State private var steps: [Step] = []
    @State private var files: [Spotlight.Hit] = []
    @State private var action: Action?
    @State private var working = false
    @State private var understood: String?
    @EnvironmentObject var model: AppModel

    let examples = ["find invoices from last month and zip them", "tidy my desktop", "move screenshots from last week to Documents",
                    "trash installers older than 30 days", "tag pdfs from this week red", "show videos over 500 MB"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(title: "Assistant", subtitle: "Ask in plain language. Spyglass drafts a plan; nothing runs until you press Run.", symbol: "wand.and.stars", tint: .purple)
            HStack {
                TextField("What should I do?", text: $prompt).textFieldStyle(.roundedBorder).controlSize(.large).onSubmit { Task { await draft() } }
                Button("Plan") { Task { await draft() } }.buttonStyle(.borderedProminent).disabled(prompt.isEmpty)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack { ForEach(examples, id: \.self) { e in Button(e) { prompt = e; Task { await draft() } }.buttonStyle(.bordered).controlSize(.small) } }
            }
            Label(AI.statusText, systemImage: AI.available ? "sparkles" : "cpu").font(.caption).foregroundStyle(.secondary)
            if working { ProgressView() }
            if let understood { Text("Understood as: \(understood)").font(.callout).foregroundStyle(.secondary) }
            if !steps.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Plan").font(.headline)
                        ForEach(Array(steps.enumerated()), id: \.element.id) { i, s in
                            HStack(alignment: .top) { Text("\(i + 1).").foregroundStyle(.secondary).monospacedDigit(); Image(systemName: s.symbol).frame(width: 18); Text(s.text) }
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                        if !files.isEmpty {
                            Text("\(files.count) files").font(.subheadline.weight(.semibold)).padding(.top, 4)
                            ScrollView { VStack(alignment: .leading, spacing: 3) { ForEach(files.prefix(200)) { f in HStack { Thumb(url: f.url, side: 18); Text(f.name).lineLimit(1); Spacer(); Text(Fmt.size(f.size)).foregroundStyle(.secondary) }.font(.callout) } } }.frame(maxHeight: 220)
                        }
                        HStack { Spacer(); Button("Cancel") { steps = []; files = []; action = nil }
                            Button("Run") { run() }.buttonStyle(.borderedProminent).disabled(action == nil) }
                    }
                }
            }
            Spacer()
        }
        .padding(20)
        .animation(.spring(duration: 0.35), value: steps.count)
    }

    func draft() async {
        working = true; defer { working = false }
        steps = []; files = []; action = nil; understood = nil
        var p = prompt.lowercased()
        if AI.available, let r = try? await AI.respond(instructions: """
            You turn a request about files on a Mac into ONE command line. Allowed forms:
            find <search>
            zip <search>
            trash <search>
            move <search> to <desktop|downloads|documents|pictures|~/path>
            tag <search> <red|orange|yellow|green|blue|purple|gray>
            tidy <desktop|downloads|documents> [by month]
            <search> uses plain words like: pdfs, images, videos, screenshots, installers, documents, "from last week", "this month", "over 50 mb", "older than 30 days", "in downloads", file name words.
            Reply with the command only.
            """, prompt: prompt) {
            let line = r.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines).first?.lowercased() ?? ""
            if ["find ", "zip ", "trash ", "move ", "tag ", "tidy "].contains(where: line.hasPrefix) { p = line; understood = line }
        }
        let places: [(String, URL)] = [("desktop", Places.desktop), ("downloads", Places.downloads), ("documents", Places.documents), ("pictures", Places.pictures)]
        if p.hasPrefix("tidy") || p.hasPrefix("organize") || p.hasPrefix("clean up my") {
            let dir = places.first { p.contains($0.0) }?.1 ?? Places.desktop
            let byMonth = p.contains("month")
            let plan = Organizer.plan(dir, byMonth: byMonth)
            steps = [Step(text: "Look at loose files in \(dir.lastPathComponent)", symbol: "eye"),
                     Step(text: "Sort \(plan.count) files into folders by \(byMonth ? "month" : "kind")", symbol: "folder.badge.plus"),
                     Step(text: "Record it in Activity so you can undo", symbol: "clock.arrow.circlepath")]
            action = plan.isEmpty ? nil : .organize(dir, byMonth)
            return
        }
        // Split "find X and <verb>" into a search and an action.
        var search = p
        for prefix in ["find ", "show ", "trash ", "delete ", "remove ", "move ", "zip ", "compress ", "tag ", "get "] where search.hasPrefix(prefix) { search = String(search.dropFirst(prefix.count)); break }
        var verb = p.hasPrefix("trash") || p.hasPrefix("delete") || p.hasPrefix("remove") ? "trash" : p.hasPrefix("move") ? "move" : p.hasPrefix("zip") || p.hasPrefix("compress") ? "zip" : p.hasPrefix("tag") ? "tag" : "show"
        for (k, v) in [(" and zip them", "zip"), (" and compress them", "zip"), (" and trash them", "trash"), (" and delete them", "trash"), (" and move them", "move")] where search.contains(k) {
            verb = v; search = search.components(separatedBy: k)[0]
        }
        var dest: URL?
        if verb == "move", let r = search.range(of: " to ", options: .backwards) {
            let target = String(search[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            dest = places.first { target.contains($0.0) }?.1 ?? URL(fileURLWithPath: (target as NSString).expandingTildeInPath)
            search = String(search[..<r.lowerBound])
        }
        var color = "Red"
        if verb == "tag" { for c in Tags.colors where search.contains(c.0.lowercased()) { color = c.0; search = search.replacingOccurrences(of: " " + c.0.lowercased(), with: "") } }
        if let r = search.range(of: "older than ") {
            let rest = search[r.upperBound...].split(separator: " ")
            if let n = rest.first.flatMap({ Int($0) }) { search = search.replacingCharacters(in: r.lowerBound..., with: "") + " before:\(n)" }
        }
        var parsed = ParsedSearch.parse(search.replacingOccurrences(of: " before:", with: " "))
        if let r = search.range(of: "before:"), let n = Int(search[r.upperBound...].prefix { $0.isNumber }) {
            parsed.chips.removeAll { $0.id == "date" }
            parsed.words.removeAll { Int($0) != nil || ["days", "day", "weeks", "months"].contains($0) }
            parsed.chips.append(SearchChip(id: "date", label: "Older than \(n) days", symbol: "calendar", clause: "kMDItemFSContentChangeDate < \(Spotlight.iso(Date().addingTimeInterval(-Double(n) * 86400)))"))
        }
        guard let q = parsed.query(excluding: [], meaning: true, contents: true) else { steps = [Step(text: "I couldn't tell which files you mean. Try naming a kind, date or size.", symbol: "questionmark.circle")]; return }
        let r = await Spotlight.run(q, scopes: [parsed.scope?.path ?? NSMetadataQueryUserHomeScope], limit: 500)
        files = r.hits
        let desc = (parsed.chips.map(\.label) + parsed.words.map { "“\($0)”" }).joined(separator: ", ")
        steps = [Step(text: "Find files: \(desc)", symbol: "magnifyingglass")]
        let urls = files.map(\.url)
        switch verb {
        case "zip": steps.append(Step(text: "Compress \(files.count) files into one ZIP in Downloads/Spyglass", symbol: "archivebox")); action = .zip(urls)
        case "trash": steps.append(Step(text: "Move \(files.count) files (\(Fmt.size(files.reduce(0) { $0 + $1.size }))) to the Trash", symbol: "trash")); action = .trash(urls)
        case "move": if let dest { steps.append(Step(text: "Move \(files.count) files to \(Places.displayPath(dest))", symbol: "folder")); action = .move(urls, dest) }
        case "tag": steps.append(Step(text: "Tag \(files.count) files \(color)", symbol: "tag")); action = .tag(urls, color)
        default: steps.append(Step(text: "Show the results in search", symbol: "list.bullet")); action = .show(search)
        }
        if verb != "show" { steps.append(Step(text: "Record it in Activity so you can undo", symbol: "clock.arrow.circlepath")) }
        if files.isEmpty { action = nil; steps.append(Step(text: "No files matched — nothing to run.", symbol: "exclamationmark.circle")) }
    }

    func run() {
        guard let a = action else { return }
        switch a {
        case .trash(let u): FileOps.trash(u)
        case .zip(let u): Task { await ArchiveTools.zip(u) }
        case .move(let u, let d): FileOps.move(u, into: d, copy: false)
        case .organize(let d, let m): Organizer.apply(Organizer.plan(d, byMonth: m), title: "Organized \(d.lastPathComponent)")
        case .tag(let u, let c): for x in u { var t = Tags.get(x); if !t.contains(c) { t.append(c) }; Tags.set(x, t) }; ActivityLog.shared.show("Tagged \(u.count) files \(c)")
        case .show(let q): model.searchText = q; model.show(.search(q))
        }
        steps = []; files = []; action = nil
    }
}
