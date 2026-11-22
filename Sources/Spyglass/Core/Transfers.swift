import SwiftUI
import Darwin

/// Sequential copy/move queue with progress and Finder-style conflict handling.
@MainActor final class TransferQueue: ObservableObject {
    static let shared = TransferQueue()

    enum Resolution { case skip, replace, keepBoth, merge }
    enum State { case waiting, running, done, cancelled }

    struct Job: Identifiable {
        let id = UUID()
        let items: [URL]
        let dest: URL
        let copy: Bool
        let title: String?
        var total: Int64 = 0
        var done: Int64 = 0
        var current = ""
        var state = State.waiting
        var errors = 0
        var label: String { title ?? "\(copy ? "Copying" : "Moving") \(items.count) item\(items.count == 1 ? "" : "s") to “\(dest.lastPathComponent)”" }
    }

    struct Conflict: Identifiable {
        let id = UUID()
        let item: URL
        let existing: URL
        let bothFolders: Bool
        let answer: (Resolution, Bool) -> Void
    }

    @Published var jobs: [Job] = []
    @Published var conflict: Conflict?
    private var running = false
    private var cancelled = Set<UUID>()

    func add(_ urls: [URL], into dest: URL, copy: Bool, title: String? = nil) {
        let items = urls.filter { u in
            !dest.standardizedFileURL.path.hasPrefix(u.standardizedFileURL.path + "/") && dest.standardizedFileURL != u.standardizedFileURL
                && (copy || u.deletingLastPathComponent().standardizedFileURL != dest.standardizedFileURL)
        }
        guard !items.isEmpty else { return }
        jobs.append(Job(items: items, dest: dest, copy: copy, title: title))
        if !running { Task { await pump() } }
    }

    func cancel(_ id: UUID) { cancelled.insert(id); if let i = jobs.firstIndex(where: { $0.id == id }), jobs[i].state == .waiting { jobs[i].state = .cancelled } }

    var active: Bool { jobs.contains { $0.state == .running || $0.state == .waiting } }

    private func pump() async {
        running = true
        while let i = jobs.firstIndex(where: { $0.state == .waiting }) {
            jobs[i].state = .running
            let job = jobs[i]
            let moves = await Self.run(job, queue: self)
            if let k = jobs.firstIndex(where: { $0.id == job.id }) {
                jobs[k].state = cancelled.contains(job.id) ? .cancelled : .done
                let e = jobs[k].errors
                let count = moves.filter { $0.from == nil || !$0.to.contains("/.Trash/") }.count
                ActivityLog.shared.record(job.copy ? .copy : .move, job.title ?? "\(job.copy ? "Copied" : "Moved") \(count) item\(count == 1 ? "" : "s") to “\(job.dest.lastPathComponent)”" + (e > 0 ? " (\(e) failed)" : ""), moves: moves)
            }
            FileOps.changed()
            NSApp.dockTile.badgeLabel = nil
            let id = job.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.jobs.removeAll { $0.id == id && $0.state != .running && $0.state != .waiting } }
        }
        running = false
    }

    fileprivate func update(_ id: UUID, done: Int64? = nil, total: Int64? = nil, current: String? = nil, error: Bool = false) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        if let done { jobs[i].done = done }
        if let total { jobs[i].total = total }
        if let current { jobs[i].current = current }
        if error { jobs[i].errors += 1 }
        if jobs[i].total > 0 { NSApp.dockTile.badgeLabel = "\(Int(Double(jobs[i].done) / Double(jobs[i].total) * 100))%" }
    }
    fileprivate func isCancelled(_ id: UUID) -> Bool { cancelled.contains(id) }

    fileprivate func ask(_ item: URL, _ existing: URL, folders: Bool) async -> (Resolution, Bool) {
        await withCheckedContinuation { c in
            NSApp.activate(ignoringOtherApps: true)
            conflict = Conflict(item: item, existing: existing, bothFolders: folders) { r, all in
                self.conflict = nil
                c.resume(returning: (r, all))
            }
        }
    }

    // MARK: Worker (off the main thread)

    nonisolated private static func run(_ job: Job, queue: TransferQueue) async -> [Move] {
        let fm = FileManager.default
        var moves: [Move] = []
        var applyAll: Resolution?
        let total = job.items.reduce(Int64(0)) { $0 + Sizer.size(of: $1) }
        await queue.update(job.id, total: total)
        var done: Int64 = 0
        var lastTick = Date.distantPast

        func progress(_ name: String) async {
            if Date().timeIntervalSince(lastTick) > 0.15 { lastTick = Date(); await queue.update(job.id, done: done, current: name) }
        }
        func sameVolume(_ a: URL, _ b: URL) -> Bool {
            let va = try? a.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject
            let vb = try? b.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject
            return va != nil && va == vb
        }
        func copyTree(_ src: URL, _ dst: URL) async -> Bool {
            var isDir: ObjCBool = false
            fm.fileExists(atPath: src.path, isDirectory: &isDir)
            let pkg = (try? src.resourceValues(forKeys: [.isPackageKey]).isPackage) ?? false
            if !isDir.boolValue || pkg {
                let ok = copyfile(src.path, dst.path, nil, copyfile_flags_t(COPYFILE_ALL | COPYFILE_CLONE | (pkg ? COPYFILE_RECURSIVE : 0))) == 0
                done += Sizer.size(of: src)
                await progress(src.lastPathComponent)
                return ok
            }
            guard (try? fm.createDirectory(at: dst, withIntermediateDirectories: true)) != nil else { return false }
            var ok = true
            for c in (try? fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil)) ?? [] {
                if await queue.isCancelled(job.id) { return false }
                ok = await copyTree(c, dst.appendingPathComponent(c.lastPathComponent)) && ok
            }
            return ok
        }
        /// Merge: folder contents go into the existing folder; clashing files keep the newer one.
        func merge(_ src: URL, into dst: URL) async {
            for c in (try? fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil)) ?? [] {
                let t = dst.appendingPathComponent(c.lastPathComponent)
                var d1: ObjCBool = false, d2: ObjCBool = false
                let exists = fm.fileExists(atPath: t.path, isDirectory: &d2)
                fm.fileExists(atPath: c.path, isDirectory: &d1)
                if exists && d1.boolValue && d2.boolValue { await merge(c, into: t); continue }
                if exists {
                    let m1 = (try? c.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let m2 = (try? t.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    if m1 <= m2 { done += Sizer.size(of: c); continue }
                    var r: NSURL?
                    if (try? fm.trashItem(at: t, resultingItemURL: &r)) != nil, let r = r as URL? { moves.append(Move(from: t.path, to: r.path)) }
                }
                await transfer(c, to: t)
            }
            if !job.copy { try? fm.removeItem(at: src) }
        }
        func transfer(_ src: URL, to dst: URL) async {
            if !job.copy && sameVolume(src, dst.deletingLastPathComponent()) {
                do { try fm.moveItem(at: src, to: dst); moves.append(Move(from: src.path, to: dst.path)); done += Sizer.size(of: dst); await progress(src.lastPathComponent) }
                catch { await queue.update(job.id, error: true) }
                return
            }
            if await copyTree(src, dst) {
                if job.copy { moves.append(Move(from: nil, to: dst.path)) }
                else if (try? fm.removeItem(at: src)) != nil { moves.append(Move(from: src.path, to: dst.path)) }
                else { moves.append(Move(from: nil, to: dst.path)) }
            } else {
                try? fm.removeItem(at: dst)
                await queue.update(job.id, error: true)
            }
        }

        for u in job.items {
            if await queue.isCancelled(job.id) { break }
            var target = job.dest.appendingPathComponent(u.lastPathComponent)
            if fm.fileExists(atPath: target.path) {
                if job.copy && u.deletingLastPathComponent().standardizedFileURL == job.dest.standardizedFileURL {
                    target = FileOps.uniqueURL(target)          // pasting into the same folder makes a copy
                } else {
                    var d1: ObjCBool = false, d2: ObjCBool = false
                    fm.fileExists(atPath: u.path, isDirectory: &d1); fm.fileExists(atPath: target.path, isDirectory: &d2)
                    let folders = d1.boolValue && d2.boolValue
                    var r: Resolution
                    if let a = applyAll { r = (a == .merge && !folders) ? .keepBoth : a }
                    else { let (res, all) = await queue.ask(u, target, folders: folders); r = res; if all { applyAll = res } }
                    switch r {
                    case .skip: done += Sizer.size(of: u); continue
                    case .keepBoth: target = FileOps.uniqueURL(target)
                    case .replace:
                        var t: NSURL?
                        if (try? fm.trashItem(at: target, resultingItemURL: &t)) != nil, let t = t as URL? { moves.append(Move(from: target.path, to: t.path)) }
                    case .merge:
                        await merge(u, into: target); continue
                    }
                }
            }
            await transfer(u, to: target)
        }
        await queue.update(job.id, done: done)
        return moves
    }
}

// MARK: - UI

struct TransfersOverlay: View {
    @ObservedObject var q = TransferQueue.shared
    var body: some View {
        if !q.jobs.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(q.jobs) { j in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: j.state == .done ? "checkmark.circle.fill" : j.copy ? "doc.on.doc" : "arrow.right.doc.on.clipboard")
                                .foregroundStyle(j.state == .done ? .green : .accentColor)
                            Text(j.label).font(.callout.weight(.medium)).lineLimit(1)
                            Spacer()
                            if j.state == .running || j.state == .waiting {
                                Button { q.cancel(j.id) } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless).foregroundStyle(.secondary).help("Stop")
                            }
                        }
                        ProgressView(value: j.total > 0 ? min(1, Double(j.done) / Double(j.total)) : (j.state == .done ? 1 : 0))
                        Text(j.state == .waiting ? "Waiting…" : j.state == .cancelled ? "Stopped" : j.state == .done ? (j.errors > 0 ? "Finished — \(j.errors) couldn't be transferred" : "Done")
                             : "\(Fmt.size(j.done)) of \(Fmt.size(j.total)) · \(j.current)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .padding(14).frame(width: 340)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator))
            .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
            .padding(16)
            .transition(.move(edge: .trailing).combined(with: .opacity))
        }
    }
}

struct ConflictSheet: View {
    let c: TransferQueue.Conflict
    @State private var all = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("“\(c.item.lastPathComponent)” already exists in “\(c.existing.deletingLastPathComponent().lastPathComponent)”").font(.headline)
            HStack(spacing: 20) { side("Keeping", c.existing); Image(systemName: "arrow.left").foregroundStyle(.secondary); side("Incoming", c.item) }
            Toggle("Apply to all", isOn: $all).toggleStyle(.checkbox)
            HStack {
                Button("Skip") { c.answer(.skip, all) }.keyboardShortcut(.cancelAction)
                Spacer()
                if c.bothFolders { Button("Merge") { c.answer(.merge, all) } }
                Button("Keep Both") { c.answer(.keepBoth, all) }
                Button("Replace") { c.answer(.replace, all) }.keyboardShortcut(.defaultAction)
            }
            Text("Replaced items go to the Trash. Merge combines folders and keeps the newer copy of each file.").font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(width: 500)
    }
    func side(_ t: String, _ u: URL) -> some View {
        let i = FileItem(url: u)
        return VStack(spacing: 4) {
            Text(t).font(.caption).foregroundStyle(.secondary)
            Thumb(url: u, side: 64)
            Text(i.map { $0.isFolderLike ? "Folder" : Fmt.size($0.size) } ?? "").font(.caption)
            Text(i.map { Fmt.when($0.modified) } ?? "").font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity)
    }
}
