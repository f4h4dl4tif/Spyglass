import SwiftUI

/// "When X happens, do Y to files matching Z." Everything a routine does is logged in Activity and can be undone.
struct Routine: Codable, Identifiable, Hashable {
    enum Trigger: String, Codable, CaseIterable { case hourly, daily, weekly, fileArrives, launch
        var title: String { switch self { case .hourly: "Every hour"; case .daily: "Every day"; case .weekly: "Every week"; case .fileArrives: "When files arrive"; case .launch: "When Spyglass opens" } }
    }
    enum Action: String, Codable, CaseIterable { case organize, trash, tag, move, cleanSafe, smartRename, convertJPEG, unzip
        var title: String {
            switch self {
            case .organize: "Organize into folders"; case .trash: "Move to Trash"; case .tag: "Add a tag"; case .move: "Move to a folder"
            case .cleanSafe: "Clean Safe items"; case .smartRename: "Smart Rename"; case .convertJPEG: "Convert images to JPEG"; case .unzip: "Unzip archives"
            }
        }
        var symbol: String {
            switch self {
            case .organize: "folder.badge.plus"; case .trash: "trash"; case .tag: "tag"; case .move: "arrow.right.doc.on.clipboard"
            case .cleanSafe: "sparkles"; case .smartRename: "wand.and.rays"; case .convertJPEG: "photo"; case .unzip: "archivebox"
            }
        }
    }

    var id = UUID()
    var name: String
    var enabled = true
    var trigger: Trigger
    var hour = 9                         // for daily / weekly
    var folder: String                   // where to look
    var kinds: [FileKind] = []           // empty = any
    var extensions = ""                  // "pdf, png"
    var nameContains = ""
    var olderThanDays = 0
    var largerThanMB = 0
    var action: Action
    var tag = "Red"
    var destination = ""
    var byMonth = false
    var lastRun: Date?
    var lastResult = ""

    var folderURL: URL { URL(fileURLWithPath: (folder as NSString).expandingTildeInPath) }

    var summary: String {
        var cond: [String] = []
        if !kinds.isEmpty { cond.append(kinds.map { $0.title.lowercased() + "s" }.joined(separator: " or ")) }
        if !extensions.isEmpty { cond.append(".\(extensions.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: ",", with: ", ."))") }
        if !nameContains.isEmpty { cond.append("named “\(nameContains)”") }
        if olderThanDays > 0 { cond.append("older than \(olderThanDays) days") }
        if largerThanMB > 0 { cond.append("over \(largerThanMB) MB") }
        let what = action == .cleanSafe ? "" : " — " + (cond.isEmpty ? "all files" : cond.joined(separator: ", ")) + " in \(Places.displayPath(folderURL))"
        return "\(trigger.title)\(trigger == .daily || trigger == .weekly ? " at \(hour):00" : ""): \(action.title.lowercased())\(action == .tag ? " \(tag)" : action == .move ? " to \(destination)" : "")\(what)"
    }

    func matches(_ u: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .contentModificationDateKey, .addedToDirectoryDateKey, .totalFileAllocatedSizeKey]
        guard let v = try? u.resourceValues(forKeys: keys) else { return false }
        if v.isDirectory == true && v.isPackage != true && action != .trash { return false }
        if ["download", "crdownload", "part"].contains(u.pathExtension) { return false }
        let k = FileKind.of(u, isDirectory: v.isDirectory ?? false, isPackage: v.isPackage ?? false)
        if !kinds.isEmpty && !kinds.contains(k) { return false }
        let exts = extensions.lowercased().split { $0 == "," || $0 == " " }.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
        if !exts.isEmpty && !exts.contains(u.pathExtension.lowercased()) { return false }
        if !nameContains.isEmpty && !u.lastPathComponent.localizedCaseInsensitiveContains(nameContains) { return false }
        let age = Date().timeIntervalSince(max(v.contentModificationDate ?? .distantPast, v.addedToDirectoryDate ?? .distantPast))
        if olderThanDays > 0 && age < Double(olderThanDays) * 86400 { return false }
        if age < 20 { return false }                                       // still being written
        if largerThanMB > 0 && Int64(v.totalFileAllocatedSize ?? 0) < Int64(largerThanMB) * 1_000_000 { return false }
        return true
    }

    static let templates: [Routine] = [
        Routine(name: "Tidy Downloads every day", trigger: .daily, hour: 18, folder: "~/Downloads", olderThanDays: 1, action: .organize),
        Routine(name: "Trash old installers weekly", trigger: .weekly, hour: 10, folder: "~/Downloads", extensions: "dmg, pkg", olderThanDays: 7, action: .trash),
        Routine(name: "Tag new PDFs in Downloads", trigger: .fileArrives, folder: "~/Downloads", extensions: "pdf", action: .tag, tag: "Blue"),
        Routine(name: "Unzip new archives", trigger: .fileArrives, folder: "~/Downloads", extensions: "zip", action: .unzip),
        Routine(name: "Move screenshots off the Desktop", trigger: .fileArrives, folder: "~/Desktop", nameContains: "Screenshot", action: .move, destination: "~/Pictures/Screenshots"),
        Routine(name: "Clean Safe items every week", trigger: .weekly, hour: 11, folder: "~", action: .cleanSafe),
        Routine(name: "Smart-rename new scans", trigger: .fileArrives, folder: "~/Downloads", nameContains: "Scan", action: .smartRename),
    ]
}

@MainActor final class RoutineEngine: ObservableObject {
    static let shared = RoutineEngine()
    @Published var routines: [Routine] = []
    @Published var running = Set<UUID>()
    private var watchers: [String: DispatchSourceFileSystemObject] = [:]
    private var debounce: [String: DispatchWorkItem] = [:]
    private var timer: Timer?
    private var file: URL { Places.support.appendingPathComponent("routines.json") }

    func start() {
        if let d = try? Data(contentsOf: file), let r = try? JSONDecoder().decode([Routine].self, from: d) { routines = r }
        for r in routines where r.enabled && r.trigger == .launch { Task { await run(r.id) } }
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in MainActor.assumeIsolated { self.tick() } }
        timer?.tolerance = 60
        rewatch()
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { self.tick() }
    }

    func save() {
        try? JSONEncoder().encode(routines).write(to: file, options: .atomic)
        rewatch()
    }

    func upsert(_ r: Routine) { if let i = routines.firstIndex(where: { $0.id == r.id }) { routines[i] = r } else { routines.append(r) }; save() }
    func delete(_ id: UUID) { routines.removeAll { $0.id == id }; save() }
    func setEnabled(_ id: UUID, _ on: Bool) { if let i = routines.firstIndex(where: { $0.id == id }) { routines[i].enabled = on; save() } }

    private func tick() {
        let cal = Calendar.current, now = Date()
        for r in routines where r.enabled {
            let last = r.lastRun ?? .distantPast
            let due: Bool
            switch r.trigger {
            case .hourly: due = now.timeIntervalSince(last) >= 3600
            case .daily: due = cal.component(.hour, from: now) >= r.hour && !cal.isDate(last, inSameDayAs: now)
            case .weekly: due = cal.component(.hour, from: now) >= r.hour && now.timeIntervalSince(last) >= 6.5 * 86400
            case .fileArrives: due = now.timeIntervalSince(last) >= 3600   // safety sweep in case an event was missed
            case .launch: due = false
            }
            if due { Task { await run(r.id) } }
        }
    }

    private func rewatch() {
        let folders = Set(routines.filter { $0.enabled && $0.trigger == .fileArrives }.map { $0.folderURL.path })
        for (p, w) in watchers where !folders.contains(p) { w.cancel(); watchers[p] = nil }
        for p in folders where watchers[p] == nil {
            let fd = open(p, O_EVTONLY)
            guard fd >= 0 else { continue }
            let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename], queue: .main)
            src.setEventHandler { [weak self] in self?.arrived(p) }
            src.setCancelHandler { close(fd) }
            src.resume()
            watchers[p] = src
        }
    }

    private func arrived(_ path: String) {
        debounce[path]?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            for r in self.routines where r.enabled && r.trigger == .fileArrives && r.folderURL.path == path { Task { await self.run(r.id) } }
        }
        debounce[path] = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 25, execute: w)   // wait for downloads to finish writing
    }

    func run(_ id: UUID) async {
        guard let i = routines.firstIndex(where: { $0.id == id }), !running.contains(id) else { return }
        let r = routines[i]
        running.insert(id); defer { running.remove(id) }
        var result = ""
        if r.action == .cleanSafe {
            await CleanupScanner.shared.scan()
            let before = CleanupScanner.shared.total
            CleanupScanner.shared.cleanSafe()
            result = "Freed \(Fmt.size(max(0, before - CleanupScanner.shared.total)))"
        } else {
            let dir = r.folderURL
            let files = await Task.detached { ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []).filter { r.matches($0) } }.value
            if files.isEmpty { result = "Nothing to do" }
            else {
                switch r.action {
                case .organize:
                    let set = Set(files)
                    let plan = Organizer.plan(dir, byMonth: r.byMonth, minAgeHours: 0).filter { set.contains($0.from) }
                    if !plan.isEmpty { Organizer.apply(plan, title: "Routine “\(r.name)”: organized \(plan.count) files") }
                    result = "Organized \(plan.count) files"
                case .trash:
                    FileOps.trash(files, kind: .cleanup, title: "Routine “\(r.name)”: moved \(files.count) items to the Trash")
                    result = "Trashed \(files.count) items"
                case .tag:
                    var n = 0
                    for u in files { var t = Tags.get(u); if !t.contains(r.tag) { t.append(r.tag); Tags.set(u, t); n += 1 } }
                    result = n == 0 ? "Nothing new to tag" : "Tagged \(n) files \(r.tag)"
                case .move:
                    let dest = URL(fileURLWithPath: (r.destination as NSString).expandingTildeInPath)
                    try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
                    FileOps.move(files, into: dest, copy: false, title: "Routine “\(r.name)”: moved \(files.count) files")
                    result = "Moved \(files.count) files"
                case .smartRename:
                    var moves: [Move] = []
                    for u in files where SmartNamer.isGeneric(u) {
                        let n = await SmartNamer.suggest(u)
                        let d = FileOps.uniqueURL(u.deletingLastPathComponent().appendingPathComponent(n))
                        if n != u.lastPathComponent, (try? FileManager.default.moveItem(at: u, to: d)) != nil { moves.append(Move(from: u.path, to: d.path)) }
                    }
                    ActivityLog.shared.record(.rename, "Routine “\(r.name)”: renamed \(moves.count) files", moves: moves, toast: false)
                    result = "Renamed \(moves.count) files"
                case .convertJPEG:
                    var made: [URL] = []
                    for u in files where Ext.image.contains(u.pathExtension.lowercased()) && !["jpg", "jpeg"].contains(u.pathExtension.lowercased()) {
                        if let cg = try? ImageTools.cgImage(u), let o = try? ImageTools.write(cg, to: u.deletingPathExtension().appendingPathExtension("jpg"), type: .jpeg, quality: 0.85) { made.append(o) }
                    }
                    FileOps.created(made, title: "Routine “\(r.name)”: converted \(made.count) images")
                    result = "Converted \(made.count) images"
                case .unzip:
                    var n = 0
                    for u in files where ArchiveTools.canExtract(u) { if await ArchiveTools.extract(u, into: dir) != nil { n += 1 } }
                    result = "Unzipped \(n) archives"
                case .cleanSafe: break
                }
            }
        }
        if let k = routines.firstIndex(where: { $0.id == id }) { routines[k].lastRun = Date(); routines[k].lastResult = result }
        try? JSONEncoder().encode(routines).write(to: file, options: .atomic)
    }

    func run(named name: String) async -> String {
        guard let r = routines.first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) ?? routines.first(where: { $0.name.localizedCaseInsensitiveContains(name) }) else { return "No routine called “\(name)”" }
        await run(r.id)
        return routines.first { $0.id == r.id }?.lastResult ?? "Done"
    }
}

// MARK: - UI

struct RoutinesView: View {
    @ObservedObject var e = RoutineEngine.shared
    @State private var editing: Routine?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Routines", subtitle: "Run cleanup, organizing, tagging and more on a schedule or when files arrive. Every change can be undone in Activity.", symbol: "repeat.circle", tint: .indigo) {
                Menu {
                    Button("Blank Routine…") { editing = Routine(name: "New Routine", trigger: .daily, folder: "~/Downloads", action: .organize) }
                    Divider()
                    ForEach(Routine.templates, id: \.name) { t in Button(t.name) { var c = t; c.id = UUID(); editing = c } }
                } label: { Label("New Routine", systemImage: "plus") }.frame(width: 150)
            }.padding(20)
            Divider()
            if e.routines.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "repeat.circle").font(.system(size: 42, weight: .light)).foregroundStyle(.tertiary).padding(.top, 40)
                    Text("No routines yet").font(.title3.weight(.medium))
                    Text("Start from a template, or make your own with New Routine.").foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260))], spacing: 10) {
                        ForEach(Routine.templates, id: \.name) { t in
                            Button { var c = t; c.id = UUID(); e.upsert(c) } label: {
                                Card(padding: 12) { HStack { Image(systemName: t.action.symbol).foregroundStyle(.indigo).frame(width: 22); VStack(alignment: .leading) { Text(t.name).font(.callout.weight(.semibold)); Text(t.trigger.title).font(.caption).foregroundStyle(.secondary) }; Spacer(); Image(systemName: "plus.circle") } }
                            }.buttonStyle(.plain)
                        }
                    }.padding(.horizontal, 30)
                    Spacer()
                }
            } else {
                List(e.routines) { r in
                    HStack(spacing: 12) {
                        Toggle("", isOn: Binding(get: { r.enabled }, set: { e.setEnabled(r.id, $0) })).toggleStyle(.switch).labelsHidden()
                        Image(systemName: r.action.symbol).font(.title3).foregroundStyle(.indigo).frame(width: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.name).font(.headline)
                            Text(r.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            if let l = r.lastRun { Text("Last run \(Fmt.ago(l)) · \(r.lastResult)").font(.caption2).foregroundStyle(.tertiary) }
                        }
                        Spacer()
                        if e.running.contains(r.id) { ProgressView().controlSize(.small) }
                        Button("Run Now") { Task { await e.run(r.id) } }.disabled(e.running.contains(r.id))
                        Button("Edit") { editing = r }
                    }
                    .padding(.vertical, 4)
                    .contextMenu { Button("Delete", role: .destructive) { e.delete(r.id) } }
                }
            }
        }
        .sheet(item: $editing) { RoutineEditor(routine: $0) }
    }
}

struct RoutineEditor: View {
    @State var routine: Routine
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                TextField("Name", text: $routine.name)
                Section("When") {
                    Picker("Run", selection: $routine.trigger) { ForEach(Routine.Trigger.allCases, id: \.self) { Text($0.title).tag($0) } }
                    if routine.trigger == .daily || routine.trigger == .weekly { Stepper("At \(routine.hour):00", value: $routine.hour, in: 0...23) }
                }
                Section("Which files") {
                    HStack { Text("In"); TextField("Folder", text: $routine.folder); Button("Choose…") { if let u = pickFolder() { routine.folder = Places.displayPath(u) } } }
                    HStack {
                        ForEach([FileKind.image, .video, .audio, .document, .archive, .app], id: \.self) { k in
                            Toggle(k.title + "s", isOn: Binding(get: { routine.kinds.contains(k) }, set: { if $0 { routine.kinds.append(k) } else { routine.kinds.removeAll { $0 == k } } })).toggleStyle(.checkbox)
                        }
                    }
                    TextField("Extensions (e.g. pdf, png)", text: $routine.extensions)
                    TextField("Name contains", text: $routine.nameContains)
                    Stepper(routine.olderThanDays == 0 ? "Any age" : "Older than \(routine.olderThanDays) days", value: $routine.olderThanDays, in: 0...365)
                    Stepper(routine.largerThanMB == 0 ? "Any size" : "Larger than \(routine.largerThanMB) MB", value: $routine.largerThanMB, in: 0...10000, step: 10)
                }
                Section("Do") {
                    Picker("Action", selection: $routine.action) { ForEach(Routine.Action.allCases, id: \.self) { Label($0.title, systemImage: $0.symbol).tag($0) } }
                    if routine.action == .tag { Picker("Tag", selection: $routine.tag) { ForEach(Tags.colors, id: \.0) { Text($0.0).tag($0.0) } } }
                    if routine.action == .move { HStack { TextField("Destination", text: $routine.destination); Button("Choose…") { if let u = pickFolder() { routine.destination = Places.displayPath(u) } } } }
                    if routine.action == .organize { Toggle("By month instead of kind", isOn: $routine.byMonth) }
                }
                Text(routine.summary).font(.callout).foregroundStyle(.secondary)
            }.formStyle(.grouped)
            HStack {
                if RoutineEngine.shared.routines.contains(where: { $0.id == routine.id }) { Button("Delete", role: .destructive) { RoutineEngine.shared.delete(routine.id); dismiss() } }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { RoutineEngine.shared.upsert(routine); dismiss() }.keyboardShortcut(.defaultAction)
            }.padding()
        }.frame(width: 620, height: 640)
    }
}
