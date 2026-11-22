import SwiftUI
import AVFoundation
import ImageIO

struct InspectorView: View {
    let url: URL?
    var body: some View {
        if let url, let item = FileItem(url: url) {
            InspectorContent(item: item).id(url)
        } else {
            EmptyState(symbol: "info.circle", title: "No Selection", message: "Select one item to see its details.")
        }
    }
}

private struct InspectorContent: View {
    let item: FileItem
    @State private var info: [(String, String)] = []
    @State private var hash: String?
    @State private var hashing = false
    @State private var tags: [String] = []
    @State private var folderSize: Int64?
    @State private var newTag = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Thumb(url: item.url, side: 220).frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name).font(.headline).textSelection(.enabled)
                    Text("\(item.kind.title) · \(Fmt.size(folderSize ?? item.size))").foregroundStyle(.secondary).font(.callout)
                }
                section("Tags") {
                    FlowTags(tags: $tags) { Tags.set(item.url, tags); FileOps.changed() }
                    HStack(spacing: 6) {
                        ForEach(Tags.colors, id: \.0) { t in
                            Button { toggle(t.0) } label: {
                                Circle().fill(t.1).frame(width: 14, height: 14).overlay(Circle().strokeBorder(.white, lineWidth: tags.contains(t.0) ? 2 : 0))
                            }.buttonStyle(.plain).help(t.0)
                        }
                        TextField("Add tag", text: $newTag).textFieldStyle(.roundedBorder).controlSize(.small)
                            .onSubmit { if !newTag.isEmpty { toggle(newTag); newTag = "" } }
                    }
                }
                section("Information") {
                    ForEach(info, id: \.0) { k, v in
                        HStack(alignment: .top) {
                            Text(k).foregroundStyle(.secondary).frame(width: 92, alignment: .leading)
                            Text(v).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }.font(.callout)
                    }
                }
                if !item.isFolderLike {
                    section("SHA-256") {
                        if let hash { Text(hash).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                        else {
                            Button(hashing ? "Computing…" : "Compute Checksum") {
                                hashing = true
                                let u = item.url
                                Task.detached { let h = Sizer.sha256(u); await MainActor.run { hash = h; hashing = false } }
                            }.disabled(hashing)
                        }
                    }
                }
                HStack {
                    Button("Open") { FileOps.open(item.url) }
                    Button("Show in Finder") { FileOps.reveal([item.url]) }
                }
            }.padding(14)
        }
        .task { await load() }
    }

    private func toggle(_ t: String) {
        if let i = tags.firstIndex(of: t) { tags.remove(at: i) } else { tags.append(t) }
        Tags.set(item.url, tags); FileOps.changed()
    }

    @ViewBuilder private func section<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            c()
        }
        Divider()
    }

    private func load() async {
        tags = Tags.get(item.url)
        let u = item.url
        var rows: [(String, String)] = [("Created", Fmt.when(item.created)), ("Modified", Fmt.when(item.modified))]
        if let lu = Meta.lastUsed(u) { rows.append(("Last opened", Fmt.when(lu))) }
        if item.kind == .image, let src = CGImageSourceCreateWithURL(u as CFURL, nil),
           let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            if let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int { rows.append(("Dimensions", "\(w) × \(h)")) }
            if let tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                let cam = [tiff[kCGImagePropertyTIFFMake] as? String, tiff[kCGImagePropertyTIFFModel] as? String].compactMap { $0 }.joined(separator: " ")
                if !cam.isEmpty { rows.append(("Camera", cam)) }
            }
            if let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any] {
                var parts: [String] = []
                if let f = exif[kCGImagePropertyExifFNumber] as? Double { parts.append("ƒ/\(String(format: "%.1f", f))") }
                if let e = exif[kCGImagePropertyExifExposureTime] as? Double, e > 0 { parts.append(e < 1 ? "1/\(Int((1 / e).rounded()))s" : "\(e)s") }
                if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first { parts.append("ISO \(iso)") }
                if let fl = exif[kCGImagePropertyExifFocalLength] as? Double { parts.append("\(Int(fl))mm") }
                if !parts.isEmpty { rows.append(("Exposure", parts.joined(separator: "  "))) }
            }
            if p[kCGImagePropertyGPSDictionary] != nil { rows.append(("Location", "Has GPS location")) }
        }
        if item.kind == .video || item.kind == .audio {
            let asset = AVURLAsset(url: u)
            if let d = try? await asset.load(.duration), d.seconds.isFinite {
                let s = Int(d.seconds); rows.append(("Duration", String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)))
            }
            if let t = try? await asset.loadTracks(withMediaType: .video).first, let size = try? await t.load(.naturalSize) {
                rows.append(("Dimensions", "\(Int(abs(size.width))) × \(Int(abs(size.height)))"))
            }
        }
        let froms = Meta.whereFroms(u)
        if let src = Meta.sourceName(for: froms) { rows.append(("Downloaded", src)); if let f = froms.first { rows.append(("From URL", f)) } }
        rows.append(("Where", Places.displayPath(u.deletingLastPathComponent())))
        if let a = try? FileManager.default.attributesOfItem(atPath: u.path) {
            if let p = a[.posixPermissions] as? Int { rows.append(("Permissions", permString(p, dir: item.isDirectory))) }
            if let o = a[.ownerAccountName] as? String { rows.append(("Owner", o)) }
        }
        if let b = Meta.gitBranch(near: u) { rows.append(("Git branch", b)) }
        info = rows
        if item.isFolderLike {
            folderSize = await Task.detached { Sizer.size(of: u) }.value
        }
    }

    private func permString(_ p: Int, dir: Bool) -> String {
        let chars = Array("rwxrwxrwx")
        return (dir ? "d" : "-") + (0..<9).map { p & (1 << (8 - $0)) != 0 ? String(chars[$0]) : "-" }.joined() + String(format: " (%o)", p)
    }
}

private struct FlowTags: View {
    @Binding var tags: [String]
    let changed: () -> Void
    var body: some View {
        if tags.isEmpty { Text("No tags").foregroundStyle(.tertiary).font(.callout) }
        else {
            HStack {
                ForEach(tags, id: \.self) { t in
                    HStack(spacing: 4) {
                        Circle().fill(Tags.color(t)).frame(width: 8, height: 8)
                        Text(t).font(.caption)
                        Button { tags.removeAll { $0 == t }; changed() } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }.buttonStyle(.borderless)
                    }
                    .padding(.horizontal, 7).padding(.vertical, 3).background(.quaternary, in: Capsule())
                }
            }
        }
    }
}
