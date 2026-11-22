import AppKit
import SwiftUI
import UniformTypeIdentifiers
import QuickLookThumbnailing
import CryptoKit

// MARK: - Kinds

enum FileKind: String, CaseIterable, Identifiable, Codable {
    case folder, image, video, audio, document, archive, app, code, other
    var id: String { rawValue }

    var title: String {
        switch self {
        case .folder: "Folder"; case .image: "Image"; case .video: "Video"; case .audio: "Audio"
        case .document: "Document"; case .archive: "Archive"; case .app: "App"; case .code: "Code"; case .other: "File"
        }
    }
    var symbol: String {
        switch self {
        case .folder: "folder.fill"; case .image: "photo.fill"; case .video: "film.fill"; case .audio: "music.note"
        case .document: "doc.text.fill"; case .archive: "archivebox.fill"; case .app: "app.fill"; case .code: "chevron.left.forwardslash.chevron.right"
        case .other: "doc.fill"
        }
    }
    var color: Color {
        switch self {
        case .folder: .blue; case .image: .pink; case .video: .purple; case .audio: .orange
        case .document: .indigo; case .archive: .brown; case .app: .teal; case .code: .green; case .other: .gray
        }
    }

    static func of(_ url: URL, isDirectory: Bool, isPackage: Bool = false) -> FileKind {
        if url.pathExtension.lowercased() == "app" { return .app }
        if isDirectory && !isPackage { return .folder }
        guard let t = UTType(filenameExtension: url.pathExtension.lowercased()) else { return isDirectory ? .folder : .other }
        if t.conforms(to: .image) { return .image }
        if t.conforms(to: .movie) || t.conforms(to: .video) { return .video }
        if t.conforms(to: .audio) { return .audio }
        if t.conforms(to: .archive) || t.conforms(to: .diskImage) || ["dmg", "pkg", "7z", "rar", "xz"].contains(url.pathExtension.lowercased()) { return .archive }
        if t.conforms(to: .application) || t.conforms(to: .applicationBundle) { return .app }
        if t.conforms(to: .sourceCode) || t.conforms(to: .script) || t.conforms(to: .json) || t.conforms(to: .xml) || t.conforms(to: .yaml) { return .code }
        if t.conforms(to: .pdf) || t.conforms(to: .text) || t.conforms(to: .presentation) || t.conforms(to: .spreadsheet) || t.conforms(to: .rtf)
            || ["doc", "docx", "pages", "numbers", "key", "xls", "xlsx", "ppt", "pptx", "epub", "md"].contains(url.pathExtension.lowercased()) { return .document }
        return isDirectory ? .folder : .other
    }
}

// MARK: - Items

struct FileItem: Identifiable, Hashable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let isPackage: Bool
    let isHidden: Bool
    let size: Int64
    let modified: Date
    let created: Date
    let kind: FileKind
    var id: URL { url }
    var isFolderLike: Bool { isDirectory && !isPackage }

    static let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isHiddenKey, .fileSizeKey, .totalFileAllocatedSizeKey,
                                         .contentModificationDateKey, .creationDateKey, .localizedNameKey]

    init?(url: URL) {
        guard let v = try? url.resourceValues(forKeys: Set(Self.keys)) else { return nil }
        self.url = url
        name = v.localizedName ?? url.lastPathComponent
        isDirectory = v.isDirectory ?? false
        isPackage = v.isPackage ?? false
        isHidden = v.isHidden ?? url.lastPathComponent.hasPrefix(".")
        size = Int64(v.totalFileAllocatedSize ?? v.fileSize ?? 0)
        modified = v.contentModificationDate ?? .distantPast
        created = v.creationDate ?? .distantPast
        kind = FileKind.of(url, isDirectory: isDirectory, isPackage: isPackage)
    }

    static func list(_ dir: URL, hidden: Bool) -> [FileItem] {
        let opts: FileManager.DirectoryEnumerationOptions = hidden ? [] : [.skipsHiddenFiles]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: opts) else { return [] }
        return urls.compactMap(FileItem.init(url:))
    }
}

// MARK: - Formatting

enum Fmt {
    static let bytes: ByteCountFormatter = { let f = ByteCountFormatter(); f.countStyle = .file; return f }()
    static func size(_ b: Int64) -> String { bytes.string(fromByteCount: b) }
    static let date: DateFormatter = { let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; f.doesRelativeDateFormatting = true; return f }()
    static let relative = RelativeDateTimeFormatter()
    static func when(_ d: Date) -> String { d == .distantPast ? "--" : date.string(from: d) }
    static func ago(_ d: Date) -> String { relative.localizedString(for: d, relativeTo: Date()) }
    static func count(_ n: Int) -> String { n.formatted() }
}

// MARK: - Well known places

enum Places {
    static let fm = FileManager.default
    static var home: URL { fm.homeDirectoryForCurrentUser }
    static var desktop: URL { home.appendingPathComponent("Desktop") }
    static var documents: URL { home.appendingPathComponent("Documents") }
    static var downloads: URL { home.appendingPathComponent("Downloads") }
    static var pictures: URL { home.appendingPathComponent("Pictures") }
    static var movies: URL { home.appendingPathComponent("Movies") }
    static var music: URL { home.appendingPathComponent("Music") }
    static var applications: URL { URL(fileURLWithPath: "/Applications") }
    static var library: URL { home.appendingPathComponent("Library") }
    static var iCloud: URL { library.appendingPathComponent("Mobile Documents/com~apple~CloudDocs") }
    static var support: URL {
        let u = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Spyglass")
        try? fm.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    struct Cloud: Identifiable, Hashable { let name: String; let url: URL; let symbol: String; var id: URL { url } }
    static func cloudDrives() -> [Cloud] {
        var out: [Cloud] = []
        if fm.fileExists(atPath: iCloud.path) { out.append(Cloud(name: "iCloud Drive", url: iCloud, symbol: "icloud")) }
        let cs = library.appendingPathComponent("CloudStorage")
        for u in (try? fm.contentsOfDirectory(at: cs, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [] {
            let n = u.lastPathComponent
            let name: String
            if n.hasPrefix("GoogleDrive") { name = "Google Drive" }
            else if n.hasPrefix("Dropbox") { name = "Dropbox" }
            else if n.hasPrefix("OneDrive") { name = n.contains("-") ? "OneDrive " + n.split(separator: "-", maxSplits: 1)[1] : "OneDrive" }
            else if n.hasPrefix("Box") { name = "Box" }
            else { name = n.replacingOccurrences(of: "-", with: " ") }
            out.append(Cloud(name: name, url: u, symbol: "cloud"))
        }
        let legacyDropbox = home.appendingPathComponent("Dropbox")
        if fm.fileExists(atPath: legacyDropbox.path), !out.contains(where: { $0.name == "Dropbox" }) {
            out.append(Cloud(name: "Dropbox", url: legacyDropbox, symbol: "cloud"))
        }
        return out
    }

    struct Volume: Identifiable, Hashable { let name: String; let url: URL; let free: Int64; let total: Int64; let ejectable: Bool; var id: URL { url } }
    static func volumes() -> [Volume] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeAvailableCapacityKey, .volumeTotalCapacityKey, .volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsInternalKey]
        let urls = fm.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { u in
            guard u.path.hasPrefix("/Volumes/"), let v = try? u.resourceValues(forKeys: Set(keys)) else { return nil }
            return Volume(name: v.volumeName ?? u.lastPathComponent, url: u, free: Int64(v.volumeAvailableCapacity ?? 0),
                          total: Int64(v.volumeTotalCapacity ?? 0), ejectable: (v.volumeIsEjectable ?? false) || (v.volumeIsRemovable ?? false) || !(v.volumeIsInternal ?? true))
        }
    }

    static func startupDisk() -> (free: Int64, total: Int64, important: Int64) {
        let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        let free = Int64(v?.volumeAvailableCapacity ?? 0)
        return (free, Int64(v?.volumeTotalCapacity ?? 0), v?.volumeAvailableCapacityForImportantUsage ?? free)
    }

    static func displayPath(_ url: URL) -> String { url.path.replacingOccurrences(of: home.path, with: "~", options: .anchored) }
}

// MARK: - Thumbnails (bounded memory cache)

final class Thumbs {
    static let shared = Thumbs()
    private let cache: NSCache<NSString, NSImage> = { let c = NSCache<NSString, NSImage>(); c.countLimit = 300; c.totalCostLimit = 48 << 20; return c }()

    func cached(_ url: URL, _ side: CGFloat) -> NSImage? { cache.object(forKey: key(url, side)) }
    private func key(_ url: URL, _ side: CGFloat) -> NSString { "\(url.path)#\(Int(side))" as NSString }

    func load(_ url: URL, side: CGFloat) async -> NSImage {
        if let c = cached(url, side) { return c }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side, height: side), scale: scale, representationTypes: .thumbnail)
        let img: NSImage
        if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req) {
            img = rep.nsImage
        } else {
            img = NSWorkspace.shared.icon(forFile: url.path)
        }
        cache.setObject(img, forKey: key(url, side), cost: Int(side * side * scale * scale * 4))
        return img
    }
}

struct Thumb: View {
    let url: URL
    var side: CGFloat = 64
    var iconOnly = false
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fit) }
            else { Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().aspectRatio(contentMode: .fit).opacity(0.6) }
        }
        .frame(width: side, height: side)
        .task(id: url) {
            if iconOnly { image = NSWorkspace.shared.icon(forFile: url.path); return }
            if let c = Thumbs.shared.cached(url, side) { image = c; return }
            let img = await Thumbs.shared.load(url, side: side)
            withAnimation(.easeOut(duration: 0.18)) { image = img }
        }
    }
}

// MARK: - Sizes & hashing

enum Sizer {
    /// Allocated size of a folder (or file). Cooperative cancellation aware.
    static func size(of url: URL, cancel: (() -> Bool)? = nil) -> Int64 {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue { return Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0) }
        var total: Int64 = 0
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else { return 0 }
        var n = 0
        for case let f as URL in e {
            n += 1
            if n & 1023 == 0, cancel?() == true { break }
            if let v = try? f.resourceValues(forKeys: Set(keys)), v.isRegularFile == true { total += Int64(v.totalFileAllocatedSize ?? 0) }
        }
        return total
    }

    static func sha256(_ url: URL, limit: Int? = nil) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        var read = 0
        while true {
            let chunk = autoreleasepool { h.readData(ofLength: 1 << 20) }
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
            read += chunk.count
            if let limit, read >= limit { break }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Background folder-size cache used by list view.
@MainActor final class FolderSizes: ObservableObject {
    static let shared = FolderSizes()
    @Published private(set) var sizes: [URL: Int64] = [:]
    private var pending = Set<URL>()
    private let queue = DispatchQueue(label: "spyglass.sizes", qos: .utility)

    func size(_ url: URL) -> Int64? {
        if let s = sizes[url] { return s }
        if !pending.contains(url) {
            pending.insert(url)
            queue.async {
                let s = Sizer.size(of: url)
                DispatchQueue.main.async { self.sizes[url] = s; self.pending.remove(url) }
            }
        }
        return nil
    }
    func invalidate(_ url: URL) { sizes[url] = nil }
}

// MARK: - Metadata helpers

enum Meta {
    static func whereFroms(_ url: URL) -> [String] {
        guard let item = MDItemCreateWithURL(nil, url as CFURL),
              let v = MDItemCopyAttribute(item, kMDItemWhereFroms) as? [String] else { return [] }
        return v
    }
    static func lastUsed(_ url: URL) -> Date? {
        guard let item = MDItemCreateWithURL(nil, url as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }
    static func attr(_ url: URL, _ key: CFString) -> Any? {
        guard let item = MDItemCreateWithURL(nil, url as CFURL) else { return nil }
        return MDItemCopyAttribute(item, key)
    }
    static func sourceName(for froms: [String]) -> String? {
        let urls = froms.compactMap { URL(string: $0) }
        guard let host = (urls.count > 1 ? urls[1].host : nil) ?? urls.first?.host else { return nil }
        return friendlySource(host)
    }
    static func friendlySource(_ host: String) -> String {
        let h = host.lowercased().replacingOccurrences(of: "www.", with: "")
        let map: [(String, String)] = [("mail.google", "Gmail"), ("drive.google", "Google Drive"), ("docs.google", "Google Docs"),
            ("googleusercontent", "Google"), ("chatgpt", "ChatGPT"), ("openai", "ChatGPT"), ("claude.ai", "Claude"), ("canva", "Canva"),
            ("twitter", "X"), ("x.com", "X"), ("twimg", "X"), ("slack", "Slack"), ("whatsapp", "WhatsApp"), ("github", "GitHub"),
            ("dropbox", "Dropbox"), ("icloud", "iCloud"), ("apple.com", "Apple"), ("outlook", "Outlook"), ("live.com", "Outlook"),
            ("notion", "Notion"), ("figma", "Figma"), ("telegram", "Telegram"), ("discord", "Discord"), ("youtube", "YouTube"),
            ("wetransfer", "WeTransfer"), ("zoom", "Zoom"), ("linkedin", "LinkedIn"), ("facebook", "Facebook"), ("fbcdn", "Facebook"),
            ("instagram", "Instagram"), ("reddit", "Reddit"), ("amazon", "Amazon")]
        for (k, v) in map where h.contains(k) { return v }
        let parts = h.split(separator: ".")
        return parts.count >= 2 ? parts.suffix(2).joined(separator: ".") : h
    }
    static func gitBranch(near url: URL) -> String? {
        var dir = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
        for _ in 0..<12 {
            let head = dir.appendingPathComponent(".git/HEAD")
            if let s = try? String(contentsOf: head, encoding: .utf8) {
                return s.hasPrefix("ref: refs/heads/") ? String(s.dropFirst(16)).trimmingCharacters(in: .whitespacesAndNewlines) : String(s.prefix(8))
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }
}

// MARK: - Tags

enum Tags {
    static let colors: [(String, Color)] = [("Red", .red), ("Orange", .orange), ("Yellow", .yellow), ("Green", .green), ("Blue", .blue), ("Purple", .purple), ("Gray", .gray)]
    static func get(_ url: URL) -> [String] { (try? url.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? [] }
    static func set(_ url: URL, _ tags: [String]) { try? (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey) }
    static func color(_ name: String) -> Color { colors.first { $0.0 == name }?.1 ?? .secondary }
}
