import Foundation
import NaturalLanguage

/// One-shot Spotlight query. Runs NSMetadataQuery on the main run loop and returns the first `limit` hits.
@MainActor final class Spotlight {
    struct Hit: Identifiable, Hashable {
        let url: URL
        let name: String
        let size: Int64
        let date: Date
        var id: URL { url }
    }

    private static var live: Set<ObjectIdentifier> = []
    private static var holders: [ObjectIdentifier: AnyObject] = [:]

    static func run(_ query: String, scopes: [Any] = [NSMetadataQueryUserHomeScope], sort: String = NSMetadataItemFSContentChangeDateKey,
                    ascending: Bool = false, limit: Int = 500) async -> (hits: [Hit], total: Int) {
        guard let pred = NSPredicate(fromMetadataQueryString: query) else { return ([], 0) }
        let q = NSMetadataQuery()
        q.predicate = pred
        q.searchScopes = scopes
        q.sortDescriptors = [NSSortDescriptor(key: sort, ascending: ascending)]
        q.notificationBatchingInterval = 0.2
        return await withCheckedContinuation { cont in
            var token: NSObjectProtocol?
            token = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: q, queue: .main) { _ in
                q.disableUpdates()
                q.stop()
                let total = q.resultCount
                var hits: [Hit] = []
                hits.reserveCapacity(min(total, limit))
                for i in 0..<min(total, limit) {
                    guard let item = q.result(at: i) as? NSMetadataItem,
                          let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
                    hits.append(Hit(url: URL(fileURLWithPath: path),
                                    name: item.value(forAttribute: NSMetadataItemFSNameKey) as? String ?? (path as NSString).lastPathComponent,
                                    size: (item.value(forAttribute: NSMetadataItemFSSizeKey) as? NSNumber)?.int64Value ?? 0,
                                    date: item.value(forAttribute: sort) as? Date ?? item.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date ?? .distantPast))
                }
                if let token { NotificationCenter.default.removeObserver(token) }
                holders[ObjectIdentifier(q)] = nil
                cont.resume(returning: (hits, total))
            }
            holders[ObjectIdentifier(q)] = q
            if !q.start() { holders[ObjectIdentifier(q)] = nil; cont.resume(returning: ([], 0)) }
        }
    }

    /// Count + summed size of all matches (walks results without materializing them).
    static func stats(_ query: String, scopes: [Any] = [NSMetadataQueryUserHomeScope]) async -> (count: Int, bytes: Int64) {
        guard let pred = NSPredicate(fromMetadataQueryString: query) else { return (0, 0) }
        let q = NSMetadataQuery()
        q.predicate = pred
        q.searchScopes = scopes
        return await withCheckedContinuation { cont in
            var token: NSObjectProtocol?
            token = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: q, queue: .main) { _ in
                q.disableUpdates(); q.stop()
                let n = q.resultCount
                var bytes: Int64 = 0
                for i in 0..<n {
                    autoreleasepool {
                        if let item = q.result(at: i) as? NSMetadataItem, let s = item.value(forAttribute: NSMetadataItemFSSizeKey) as? NSNumber { bytes += s.int64Value }
                    }
                }
                if let token { NotificationCenter.default.removeObserver(token) }
                holders[ObjectIdentifier(q)] = nil
                cont.resume(returning: (n, bytes))
            }
            holders[ObjectIdentifier(q)] = q
            if !q.start() { holders[ObjectIdentifier(q)] = nil; cont.resume(returning: (0, 0)) }
        }
    }

    nonisolated static func iso(_ d: Date) -> String { "$time.iso(\(ISO8601DateFormatter().string(from: d)))" }
    nonisolated static func esc(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
}

// MARK: - Library categories

enum LibraryKind: String, CaseIterable, Identifiable, Codable {
    case images, videos, music, documents, archives, apps, screenshots
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .images: "photo.on.rectangle"; case .videos: "film"; case .music: "music.note.list"; case .documents: "doc.richtext"
        case .archives: "archivebox"; case .apps: "square.grid.2x2"; case .screenshots: "camera.viewfinder"
        }
    }
    var fileKind: FileKind {
        switch self {
        case .images, .screenshots: .image; case .videos: .video; case .music: .audio; case .documents: .document; case .archives: .archive; case .apps: .app
        }
    }
    var query: String {
        switch self {
        case .images: "kMDItemContentTypeTree == \"public.image\" && kMDItemIsScreenCapture != 1"
        case .videos: "kMDItemContentTypeTree == \"public.movie\""
        case .music: "kMDItemContentTypeTree == \"public.audio\""
        case .documents: "(kMDItemContentTypeTree == \"public.composite-content\" || kMDItemContentTypeTree == \"public.text\" || kMDItemContentTypeTree == \"com.adobe.pdf\" || kMDItemContentTypeTree == \"public.spreadsheet\" || kMDItemContentTypeTree == \"public.presentation\") && kMDItemContentTypeTree != \"public.source-code\" && kMDItemContentTypeTree != \"public.script\""
        case .archives: "kMDItemContentTypeTree == \"public.archive\" || kMDItemContentTypeTree == \"public.disk-image\" || kMDItemFSName == \"*.pkg\""
        case .apps: "kMDItemContentType == \"com.apple.application-bundle\""
        case .screenshots: "kMDItemIsScreenCapture == 1"
        }
    }
    var scopes: [Any] {
        self == .apps ? [Places.applications.path, Places.home.appendingPathComponent("Applications").path, "/System/Applications"] : [NSMetadataQueryUserHomeScope]
    }
}

// MARK: - Plain-English search parser

struct SearchChip: Identifiable, Hashable {
    let id: String       // stable key, used for removal
    let label: String
    let symbol: String
    let clause: String   // Spotlight query fragment
}

struct ParsedSearch {
    var chips: [SearchChip] = []
    var words: [String] = []
    var scope: URL?

    func query(excluding removed: Set<String>, meaning: Bool, contents: Bool) -> String? {
        var parts = chips.filter { !removed.contains($0.id) }.map { "(\($0.clause))" }
        for w in words where !removed.contains("w:" + w) {
            var alts = [w]
            if meaning { alts += Self.related(w) }
            let ors = alts.map { a -> String in
                let e = Spotlight.esc(a)
                return contents ? "kMDItemDisplayName == \"*\(e)*\"cdw || kMDItemTextContent == \"\(e)\"cdw || kMDItemUserTags == \"\(e)\"cd"
                                : "kMDItemDisplayName == \"*\(e)*\"cdw || kMDItemUserTags == \"\(e)\"cd"
            }
            parts.append("(" + ors.joined(separator: " || ") + ")")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " && ")
    }

    /// On-device "search by meaning": nearest neighbours from the macOS word model.
    static func related(_ w: String) -> [String] {
        guard w.count > 2, let emb = NLEmbedding.wordEmbedding(for: .english) else { return [] }
        return emb.neighbors(for: w.lowercased(), maximumCount: 4).filter { $0.1 < 1.0 }.map(\.0)
    }

    static func parse(_ text: String, now: Date = Date()) -> ParsedSearch {
        var r = ParsedSearch()
        let cal = Calendar.current
        var tokens = text.lowercased().replacingOccurrences(of: ",", with: " ").split(separator: " ").map(String.init)
        var i = 0
        func peek(_ k: Int) -> String? { i + k < tokens.count ? tokens[i + k] : nil }
        func add(_ id: String, _ label: String, _ sym: String, _ clause: String) {
            if !r.chips.contains(where: { $0.id == id }) { r.chips.append(SearchChip(id: id, label: label, symbol: sym, clause: clause)) }
        }
        func dateChip(_ label: String, from: Date, to: Date? = nil) {
            var c = "kMDItemFSContentChangeDate >= \(Spotlight.iso(from))"
            if let to { c += " && kMDItemFSContentChangeDate < \(Spotlight.iso(to))" }
            add("date", label, "calendar", c)
        }
        let kindWords: [String: (String, String, String)] = [
            "pdf": ("PDFs", "doc.richtext", "kMDItemContentType == \"com.adobe.pdf\""),
            "image": ("Images", "photo", "kMDItemContentTypeTree == \"public.image\""), "photo": ("Images", "photo", "kMDItemContentTypeTree == \"public.image\""),
            "picture": ("Images", "photo", "kMDItemContentTypeTree == \"public.image\""), "pic": ("Images", "photo", "kMDItemContentTypeTree == \"public.image\""),
            "video": ("Videos", "film", "kMDItemContentTypeTree == \"public.movie\""), "movie": ("Videos", "film", "kMDItemContentTypeTree == \"public.movie\""),
            "song": ("Music", "music.note", "kMDItemContentTypeTree == \"public.audio\""), "music": ("Music", "music.note", "kMDItemContentTypeTree == \"public.audio\""),
            "audio": ("Audio", "waveform", "kMDItemContentTypeTree == \"public.audio\""),
            "document": ("Documents", "doc.text", LibraryKind.documents.query), "doc": ("Documents", "doc.text", LibraryKind.documents.query),
            "archive": ("Archives", "archivebox", LibraryKind.archives.query), "zip": ("ZIPs", "archivebox", "kMDItemFSName == \"*.zip\"c"),
            "app": ("Apps", "app", "kMDItemContentType == \"com.apple.application-bundle\""), "application": ("Apps", "app", "kMDItemContentType == \"com.apple.application-bundle\""),
            "screenshot": ("Screenshots", "camera.viewfinder", "kMDItemIsScreenCapture == 1"),
            "spreadsheet": ("Spreadsheets", "tablecells", "kMDItemContentTypeTree == \"public.spreadsheet\""),
            "presentation": ("Presentations", "rectangle.on.rectangle", "kMDItemContentTypeTree == \"public.presentation\""),
            "code": ("Code", "chevron.left.forwardslash.chevron.right", "kMDItemContentTypeTree == \"public.source-code\""),
            "installer": ("Installers", "shippingbox", "kMDItemFSName == \"*.dmg\"c || kMDItemFSName == \"*.pkg\"c"),
            "folder": ("Folders", "folder", "kMDItemContentType == \"public.folder\""),
            "recording": ("Screen recordings", "record.circle", "kMDItemFSName == \"Screen Recording*\"c"),
        ]
        let months = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]
        let stop: Set<String> = ["from", "the", "a", "an", "of", "and", "my", "all", "files", "file", "with", "that", "are", "is", "show", "find", "me", "than", "on", "at", "to", "for", "made", "created", "modified", "named", "called"]
        let places: [String: URL] = ["downloads": Places.downloads, "desktop": Places.desktop, "documents": Places.documents, "pictures": Places.pictures,
                                     "movies": Places.movies, "music": Places.music, "applications": Places.applications, "home": Places.home]
        func sizeValue(_ s: String, _ unit: String?) -> Int64? {
            var num = s, u = unit ?? ""
            if let idx = s.firstIndex(where: { $0.isLetter }) { num = String(s[..<idx]); u = String(s[idx...]) }
            guard let v = Double(num) else { return nil }
            let mult: Double = u.hasPrefix("g") ? 1e9 : u.hasPrefix("k") ? 1e3 : u.hasPrefix("t") ? 1e12 : 1e6
            return Int64(v * mult)
        }

        while i < tokens.count {
            let t = tokens[i]
            let singular = t.hasSuffix("s") && t.count > 3 ? String(t.dropLast()) : t
            // tokens
            if let c = t.firstIndex(of: ":"), c != t.startIndex {
                let key = String(t[..<c]), val = String(t[t.index(after: c)...])
                switch key {
                case "ext": add("ext:" + val, "." + val, "doc", "kMDItemFSName == \"*.\(Spotlight.esc(val))\"c")
                case "kind": if let k = kindWords[val] ?? kindWords[String(val.dropLast())] { add("kind", k.0, k.1, k.2) }
                case "name": add("name:" + val, "Name has “\(val)”", "textformat", "kMDItemFSName == \"*\(Spotlight.esc(val))*\"cd")
                case "path", "in":
                    if let p = places[val] { r.scope = p; add("scope", "In \(val.capitalized)", "folder", "kMDItemPath == \"\(p.path)/*\"") }
                    else { add("path:" + val, "Path has “\(val)”", "folder", "kMDItemPath == \"*\(Spotlight.esc(val))*\"cd") }
                case "tag": add("tag:" + val, "Tag \(val)", "tag", "kMDItemUserTags == \"\(Spotlight.esc(val))\"cd")
                case "from": add("from:" + val, "From \(val)", "arrow.down.circle", "kMDItemWhereFroms == \"*\(Spotlight.esc(val))*\"cd")
                case "hidden": break
                default: r.words.append(t)
                }
                i += 1; continue
            }
            if let k = kindWords[t] ?? kindWords[singular] { add("kind", k.0, k.1, k.2); i += 1; continue }
            if places[t] != nil, i > 0, ["in", "on", "inside"].contains(tokens[i - 1]) {
                let p = places[t]!; r.scope = p; add("scope", "In \(t.capitalized)", "folder", "kMDItemPath == \"\(p.path)/*\""); i += 1; continue
            }
            // dates
            switch t {
            case "today": dateChip("Today", from: cal.startOfDay(for: now)); i += 1; continue
            case "yesterday": let s = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: now))!; dateChip("Yesterday", from: s, to: cal.startOfDay(for: now)); i += 1; continue
            case "this", "last", "past":
                if let u = peek(1) {
                    let unitMap: [String: Calendar.Component] = ["week": .weekOfYear, "month": .month, "year": .year, "day": .day]
                    if let comp = unitMap[u] {
                        let start = cal.dateInterval(of: comp, for: now)!.start
                        if t == "this" { dateChip("This \(u)", from: start) }
                        else if t == "last" && comp != .day { let s = cal.date(byAdding: comp, value: -1, to: start)!; dateChip("Last \(u)", from: s, to: start) }
                        else { dateChip("Past \(u)", from: cal.date(byAdding: comp, value: -1, to: now)!) }
                        i += 2; continue
                    }
                    if let n = Int(u), let unit = peek(2) {
                        let base = unit.hasSuffix("s") ? String(unit.dropLast()) : unit
                        let unitMap2: [String: Calendar.Component] = ["day": .day, "week": .weekOfYear, "month": .month, "year": .year, "hour": .hour]
                        if let comp = unitMap2[base] { dateChip("Past \(n) \(unit)", from: cal.date(byAdding: comp, value: -n, to: now)!); i += 3; continue }
                    }
                }
            case "recent", "recently", "new", "newest": dateChip("Past week", from: cal.date(byAdding: .day, value: -7, to: now)!); i += 1; continue
            case "old", "older", "oldest": add("date", "Older than a year", "calendar", "kMDItemFSContentChangeDate < \(Spotlight.iso(cal.date(byAdding: .year, value: -1, to: now)!))"); i += 1; continue
            default: break
            }
            if let m = months.firstIndex(of: t) ?? months.firstIndex(where: { $0.prefix(3) == t && t.count == 3 }) {
                var y = cal.component(.year, from: now)
                if let yy = peek(1), let yv = Int(yy), yv > 1990 { y = yv; i += 1 }
                else if m + 1 > cal.component(.month, from: now) { y -= 1 }
                let s = cal.date(from: DateComponents(year: y, month: m + 1, day: 1))!
                dateChip("\(months[m].capitalized) \(y)", from: s, to: cal.date(byAdding: .month, value: 1, to: s)!); i += 1; continue
            }
            if let y = Int(t), (1990...2100).contains(y), i > 0, ["in", "from", "during"].contains(tokens[i - 1]) {
                let s = cal.date(from: DateComponents(year: y, month: 1, day: 1))!
                dateChip("In \(y)", from: s, to: cal.date(byAdding: .year, value: 1, to: s)!); i += 1; continue
            }
            // sizes
            if ["over", "above", "larger", "bigger", ">", "under", "below", "smaller", "<"].contains(t) {
                var j = i + 1
                if peek(1) == "than" { j += 1 }
                if j < tokens.count, let v = sizeValue(tokens[j], j + 1 < tokens.count ? tokens[j + 1] : nil) {
                    let unitConsumed = tokens[j].allSatisfy({ $0.isNumber || $0 == "." }) && j + 1 < tokens.count && ["kb", "mb", "gb", "tb", "k", "m", "g"].contains(tokens[j + 1])
                    let over = ["over", "above", "larger", "bigger", ">"].contains(t)
                    add("size", "\(over ? "Over" : "Under") \(Fmt.size(v))", "scalemass", "kMDItemFSSize \(over ? ">" : "<") \(v)")
                    i = j + (unitConsumed ? 2 : 1); continue
                }
            }
            if ["big", "large", "huge"].contains(t) { add("size", "Over 100 MB", "scalemass", "kMDItemFSSize > 100000000"); i += 1; continue }
            // source
            if t == "from", let s = peek(1), !months.contains(s), Int(s) == nil, !["last", "this", "the", "past"].contains(s) {
                add("from:" + s, "Downloaded from \(s.capitalized)", "arrow.down.circle", "kMDItemWhereFroms == \"*\(Spotlight.esc(s))*\"cd"); i += 2; continue
            }
            if t == "downloaded" { i += 1; continue }
            if !stop.contains(t), t.count > 1 { r.words.append(tokens[i]) }
            i += 1
        }
        tokens.removeAll()
        return r
    }
}
