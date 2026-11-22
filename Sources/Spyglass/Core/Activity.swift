import AppKit
import SwiftUI

/// Every change Spyglass makes is a list of moves, so each one can be undone.
struct Move: Codable, Hashable {
    var from: String?   // nil = item was created by Spyglass (undo trashes it)
    var to: String
}

struct ActivityEntry: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case trash, move, rename, organize, cleanup, uninstall, create, copy }
    var id = UUID()
    var date = Date()
    var kind: Kind
    var title: String
    var moves: [Move]
    var bytes: Int64 = 0
    var undone = false

    var symbol: String {
        switch kind {
        case .trash: "trash"; case .move: "arrow.right.doc.on.clipboard"; case .rename: "pencil"; case .organize: "square.grid.3x1.folder.badge.plus"
        case .cleanup: "sparkles"; case .uninstall: "xmark.app"; case .create: "plus.square.on.square"; case .copy: "doc.on.doc"
        }
    }
}

@MainActor final class ActivityLog: ObservableObject {
    static let shared = ActivityLog()
    @Published private(set) var entries: [ActivityEntry] = []
    @Published var toast: Toast?
    struct Toast: Identifiable, Equatable { let id = UUID(); let text: String; let entry: UUID? }

    private var file: URL { Places.support.appendingPathComponent("activity.json") }

    init() {
        if let d = try? Data(contentsOf: file), let e = try? JSONDecoder().decode([ActivityEntry].self, from: d) { entries = e }
    }

    private func save() {
        let snapshot = Array(entries.prefix(500))
        let url = file
        DispatchQueue.global(qos: .utility).async { try? JSONEncoder().encode(snapshot).write(to: url, options: .atomic) }
    }

    @discardableResult
    func record(_ kind: ActivityEntry.Kind, _ title: String, moves: [Move], bytes: Int64 = 0, toast: Bool = true) -> ActivityEntry? {
        guard !moves.isEmpty else { return nil }
        let e = ActivityEntry(kind: kind, title: title, moves: moves, bytes: bytes)
        entries.insert(e, at: 0)
        save()
        if toast { show(title, entry: e.id) }
        return e
    }

    func show(_ text: String, entry: UUID? = nil) {
        let t = Toast(text: text, entry: entry)
        withAnimation(.spring(duration: 0.3)) { toast = t }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            if self?.toast?.id == t.id { withAnimation { self?.toast = nil } }
        }
    }

    func undo(_ id: UUID) {
        guard let i = entries.firstIndex(where: { $0.id == id }), !entries[i].undone else { return }
        let fm = FileManager.default
        var failed = 0
        for m in entries[i].moves.reversed() {
            let to = URL(fileURLWithPath: m.to)
            if let from = m.from {
                let dest = URL(fileURLWithPath: from)
                try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                do { try fm.moveItem(at: to, to: dest) } catch { failed += 1 }
            } else {
                do { try fm.trashItem(at: to, resultingItemURL: nil) } catch { failed += 1 }
            }
        }
        entries[i].undone = true
        save()
        show(failed == 0 ? "Undid “\(entries[i].title)”" : "Undid with \(failed) item(s) that couldn't be put back")
        FileOps.changed()
    }

    func undoLast(of kinds: Set<ActivityEntry.Kind>? = nil) {
        if let e = entries.first(where: { !$0.undone && (kinds == nil || kinds!.contains($0.kind)) }) { undo(e.id) }
        else { show("Nothing to put back") }
    }

    func clear() { entries.removeAll(); save() }
}

// MARK: - File operations

@MainActor enum FileOps {
    static let changedNote = Notification.Name("SpyglassFilesChanged")
    static func changed() { NotificationCenter.default.post(name: changedNote, object: nil) }

    static func open(_ url: URL) { NSWorkspace.shared.open(url) }
    static func reveal(_ urls: [URL]) { NSWorkspace.shared.activateFileViewerSelecting(urls) }

    @discardableResult
    static func trash(_ urls: [URL], kind: ActivityEntry.Kind = .trash, title: String? = nil) -> Int64 {
        var moves: [Move] = []
        var bytes: Int64 = 0
        for u in urls {
            let size = Sizer.size(of: u)
            var result: NSURL?
            do {
                try FileManager.default.trashItem(at: u, resultingItemURL: &result)
                if let r = result as URL? { moves.append(Move(from: u.path, to: r.path)); bytes += size }
            } catch {
                ActivityLog.shared.show("Couldn't move “\(u.lastPathComponent)” to the Trash")
            }
        }
        let t = title ?? (moves.count == 1 ? "Moved “\(URL(fileURLWithPath: moves[0].from!).lastPathComponent)” to the Trash" : "Moved \(moves.count) items to the Trash")
        ActivityLog.shared.record(kind, t, moves: moves, bytes: bytes)
        changed()
        return bytes
    }

    nonisolated static func uniqueURL(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension, dir = url.deletingLastPathComponent()
        for i in 2...9999 {
            let name = ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)"
            let u = dir.appendingPathComponent(name)
            if !fm.fileExists(atPath: u.path) { return u }
        }
        return url
    }

    static func duplicate(_ urls: [URL]) {
        var moves: [Move] = []
        for u in urls {
            let base = u.deletingPathExtension().lastPathComponent + " copy"
            let target = uniqueURL(u.deletingLastPathComponent().appendingPathComponent(u.pathExtension.isEmpty ? base : base + "." + u.pathExtension))
            if (try? FileManager.default.copyItem(at: u, to: target)) != nil { moves.append(Move(from: nil, to: target.path)) }
        }
        ActivityLog.shared.record(.create, moves.count == 1 ? "Duplicated “\(urls[0].lastPathComponent)”" : "Duplicated \(moves.count) items", moves: moves)
        changed()
    }

    static func rename(_ url: URL, to name: String) -> URL? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != url.lastPathComponent, !trimmed.contains("/") else { return nil }
        let target = url.deletingLastPathComponent().appendingPathComponent(trimmed)
        do {
            try FileManager.default.moveItem(at: url, to: target)
            ActivityLog.shared.record(.rename, "Renamed to “\(trimmed)”", moves: [Move(from: url.path, to: target.path)])
            changed()
            return target
        } catch {
            ActivityLog.shared.show("Couldn't rename: \(error.localizedDescription)")
            return nil
        }
    }

    static func move(_ urls: [URL], into dir: URL, copy: Bool, kind: ActivityEntry.Kind? = nil, title: String? = nil) {
        TransferQueue.shared.add(urls, into: dir, copy: copy, title: title)
    }

    static func newFolder(in dir: URL) -> URL? {
        let u = uniqueURL(dir.appendingPathComponent("untitled folder"))
        guard (try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: false)) != nil else { return nil }
        ActivityLog.shared.record(.create, "New folder", moves: [Move(from: nil, to: u.path)], toast: false)
        changed()
        return u
    }

    /// Records the output files of a tool so they can be undone.
    static func created(_ urls: [URL], title: String) {
        ActivityLog.shared.record(.create, title, moves: urls.map { Move(from: nil, to: $0.path) })
        changed()
    }

    static func copyToPasteboard(_ urls: [URL]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
    }
    static func pasteboardURLs() -> [URL] {
        (NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
    static func copyPath(_ urls: [URL], style: Int = 0) {
        let s = urls.map { u -> String in
            switch style {
            case 1: return "'" + u.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
            case 2: return u.absoluteString
            default: return u.path
            }
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        ActivityLog.shared.show("Copied path")
    }

    /// Output folder for tools: ~/Downloads/Spyglass/<date>
    static func outputFolder(_ tool: String) -> URL {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let u = Places.downloads.appendingPathComponent("Spyglass/\(tool) \(f.string(from: Date()))")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
}

struct ToastView: View {
    @ObservedObject var log = ActivityLog.shared
    var body: some View {
        if let t = log.toast {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(t.text).lineLimit(2)
                if let e = t.entry {
                    Button("Undo") { log.undo(e); log.toast = nil }.buttonStyle(.borderless).fontWeight(.semibold)
                }
                Button { withAnimation { log.toast = nil } } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.separator))
            .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
            .padding(.bottom, 18)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
