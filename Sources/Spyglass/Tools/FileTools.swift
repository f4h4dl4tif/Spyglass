import SwiftUI
import PDFKit
import ImageIO
import UniformTypeIdentifiers
import Vision
import AVFoundation
import CoreImage

private func stem(_ u: URL) -> String { u.deletingPathExtension().lastPathComponent }

// MARK: - PDF

enum PDFTools {
    static func load(_ u: URL) throws -> PDFDocument {
        guard let d = PDFDocument(url: u) else { throw ToolError("Couldn't open \(u.lastPathComponent)") }
        return d
    }
    static func save(_ d: PDFDocument, _ u: URL, options: [PDFDocumentWriteOption: Any] = [:]) throws -> URL {
        let dest = FileOps.uniqueURL(u)
        guard d.write(to: dest, withOptions: options) else { throw ToolError("Couldn't save \(dest.lastPathComponent)") }
        return dest
    }

    static func merge() -> some View {
        FileToolView(title: "Merge PDFs", accepts: Ext.pdf, actionTitle: "Merge") { Text("Drag files in the list to change their order.").font(.caption).foregroundStyle(.secondary) } run: { files, out, prog in
            let doc = PDFDocument()
            for (i, f) in files.enumerated() {
                let d = try load(f)
                for p in 0..<d.pageCount { if let page = d.page(at: p) { doc.insert(page, at: doc.pageCount) } }
                prog(Double(i + 1) / Double(files.count))
            }
            return [try save(doc, out.appendingPathComponent("Merged.pdf"))]
        }
    }

    static func split() -> some View {
        FileToolView(title: "Split PDF", accepts: Ext.pdf, actionTitle: "Split") { EmptyView() } run: { files, out, prog in
            var r: [URL] = []
            for f in files {
                let d = try load(f)
                for p in 0..<d.pageCount {
                    let one = PDFDocument()
                    if let page = d.page(at: p) { one.insert(page, at: 0) }
                    r.append(try save(one, out.appendingPathComponent("\(stem(f)) page \(p + 1).pdf")))
                    prog(Double(p + 1) / Double(d.pageCount))
                }
            }
            return r
        }
    }

    static func parsePages(_ s: String, count: Int) -> Set<Int> {
        var out = Set<Int>()
        for part in s.split(separator: ",") {
            let b = part.split(separator: "-").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            if b.count == 1 { out.insert(b[0] - 1) } else if b.count == 2, b[0] <= b[1] { for i in b[0]...b[1] { out.insert(i - 1) } }
        }
        return out.filter { $0 >= 0 && $0 < count }
    }

    static func deletePages() -> some View { DeletePagesView() }
    struct DeletePagesView: View {
        @State private var pages = "1"
        var body: some View {
            FileToolView(title: "Delete Pages", accepts: Ext.pdf, actionTitle: "Delete Pages") {
                HStack { Text("Pages to delete"); TextField("e.g. 2, 5-7", text: $pages).textFieldStyle(.roundedBorder).frame(width: 200) }
            } run: { [pages] files, out, _ in
                try files.map { f in
                    let d = try load(f)
                    for i in parsePages(pages, count: d.pageCount).sorted(by: >) { d.removePage(at: i) }
                    return try save(d, out.appendingPathComponent("\(stem(f)) edited.pdf"))
                }
            }
        }
    }

    static func rotate() -> some View { RotateView() }
    struct RotateView: View {
        @State private var deg = 90
        var body: some View {
            FileToolView(title: "Rotate Pages", accepts: Ext.pdf, actionTitle: "Rotate") {
                Picker("Rotate by", selection: $deg) { Text("90° right").tag(90); Text("180°").tag(180); Text("90° left").tag(270) }.pickerStyle(.segmented).frame(width: 320)
            } run: { [deg] files, out, _ in
                try files.map { f in
                    let d = try load(f)
                    for i in 0..<d.pageCount { if let p = d.page(at: i) { p.rotation = (p.rotation + deg) % 360 } }
                    return try save(d, out.appendingPathComponent("\(stem(f)) rotated.pdf"))
                }
            }
        }
    }

    static func protect() -> some View { PasswordView(unlock: false) }
    static func unlock() -> some View { PasswordView(unlock: true) }
    struct PasswordView: View {
        let unlock: Bool
        @State private var pw = ""
        var body: some View {
            FileToolView(title: unlock ? "Remove Password" : "Add Password", accepts: Ext.pdf, actionTitle: unlock ? "Unlock" : "Protect") {
                HStack { Text("Password"); SecureField("Password", text: $pw).textFieldStyle(.roundedBorder).frame(width: 240) }
            } run: { [pw, unlock] files, out, _ in
                guard !pw.isEmpty else { throw ToolError("Type a password first") }
                return try files.map { f in
                    let d = try load(f)
                    if unlock {
                        guard d.unlock(withPassword: pw) else { throw ToolError("Wrong password for \(f.lastPathComponent)") }
                        let plain = PDFDocument()
                        for i in 0..<d.pageCount { if let p = d.page(at: i) { plain.insert(p, at: plain.pageCount) } }
                        return try save(plain, out.appendingPathComponent("\(stem(f)) unlocked.pdf"))
                    }
                    return try save(d, out.appendingPathComponent("\(stem(f)) protected.pdf"), options: [.userPasswordOption: pw, .ownerPasswordOption: pw])
                }
            }
        }
    }

    static func compress() -> some View {
        FileToolView(title: "Compress PDF", accepts: Ext.pdf, actionTitle: "Compress") { Text("Images are re-saved as JPEG and sized for screens.").font(.caption).foregroundStyle(.secondary) } run: { files, out, prog in
            var r: [URL] = []
            for (i, f) in files.enumerated() {
                let d = try load(f)
                r.append(try save(d, out.appendingPathComponent("\(stem(f)) compressed.pdf"), options: [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true]))
                prog(Double(i + 1) / Double(files.count))
            }
            return r
        }
    }

    static func toImages() -> some View {
        FileToolView(title: "PDF to Images", accepts: Ext.pdf, actionTitle: "Export") { EmptyView() } run: { files, out, prog in
            var r: [URL] = []
            for f in files {
                let d = try load(f)
                for i in 0..<d.pageCount {
                    guard let p = d.page(at: i) else { continue }
                    let b = p.bounds(for: .mediaBox)
                    let img = p.thumbnail(of: CGSize(width: b.width * 2, height: b.height * 2), for: .mediaBox)
                    let dest = FileOps.uniqueURL(out.appendingPathComponent("\(stem(f)) \(i + 1).png"))
                    if let t = img.tiffRepresentation, let rep = NSBitmapImageRep(data: t), let png = rep.representation(using: .png, properties: [:]) { try png.write(to: dest); r.append(dest) }
                    prog(Double(i + 1) / Double(d.pageCount))
                }
            }
            return r
        }
    }

    static func fromImages() -> some View {
        FileToolView(title: "Images to PDF", accepts: Ext.image, actionTitle: "Make PDF") { Text("Pages follow the order in the list.").font(.caption).foregroundStyle(.secondary) } run: { files, out, prog in
            let doc = PDFDocument()
            for (i, f) in files.enumerated() {
                if let img = NSImage(contentsOf: f), let p = PDFPage(image: img) { doc.insert(p, at: doc.pageCount) }
                prog(Double(i + 1) / Double(files.count))
            }
            return [try save(doc, out.appendingPathComponent("Images.pdf"))]
        }
    }

    static func extractText() -> some View {
        FileToolView(title: "Extract Text", accepts: Ext.pdf, actionTitle: "Extract") { EmptyView() } run: { files, out, _ in
            try files.map { f in
                let d = try load(f)
                let dest = FileOps.uniqueURL(out.appendingPathComponent("\(stem(f)).txt"))
                try (d.string ?? "").write(to: dest, atomically: true, encoding: .utf8)
                return dest
            }
        }
    }
}

// MARK: - Images

enum ImageTools {
    static func write(_ img: CGImage, to u: URL, type: UTType, quality: Double = 0.9, props: [CFString: Any] = [:]) throws -> URL {
        let dest = FileOps.uniqueURL(u)
        guard let d = CGImageDestinationCreateWithURL(dest as CFURL, type.identifier as CFString, 1, nil) else { throw ToolError("Can't write \(type.preferredFilenameExtension ?? "image")") }
        var p = props; p[kCGImageDestinationLossyCompressionQuality] = quality
        CGImageDestinationAddImage(d, img, p as CFDictionary)
        guard CGImageDestinationFinalize(d) else { throw ToolError("Couldn't save \(dest.lastPathComponent)") }
        return dest
    }
    static func cgImage(_ u: URL, maxPixel: Int? = nil) throws -> CGImage {
        guard let src = CGImageSourceCreateWithURL(u as CFURL, nil) else { throw ToolError("Couldn't read \(u.lastPathComponent)") }
        if let maxPixel {
            let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxPixel, kCGImageSourceCreateThumbnailWithTransform: true]
            if let i = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) { return i }
        }
        guard let i = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw ToolError("Couldn't decode \(u.lastPathComponent)") }
        return i
    }

    static func convert() -> some View { ConvertView() }
    struct ConvertView: View {
        @State private var fmt = "png"
        @State private var quality = 0.85
        var body: some View {
            FileToolView(title: "Convert Image", accepts: Ext.image, actionTitle: "Convert") {
                HStack {
                    Picker("Format", selection: $fmt) { ForEach(["png", "jpeg", "heic", "tiff", "gif"], id: \.self) { Text($0.uppercased()).tag($0) } }.pickerStyle(.segmented).frame(width: 340)
                    if fmt == "jpeg" || fmt == "heic" { Text("Quality"); Slider(value: $quality, in: 0.3...1).frame(width: 140) }
                }
            } run: { [fmt, quality] files, out, prog in
                let t = UTType(filenameExtension: fmt == "jpeg" ? "jpg" : fmt)!
                var r: [URL] = []
                for (i, f) in files.enumerated() {
                    r.append(try write(try cgImage(f), to: out.appendingPathComponent("\(stem(f)).\(fmt == "jpeg" ? "jpg" : fmt)"), type: t, quality: quality))
                    prog(Double(i + 1) / Double(files.count))
                }
                return r
            }
        }
    }

    static func resize() -> some View { ResizeView() }
    struct ResizeView: View {
        @State private var px = 1600.0
        var body: some View {
            FileToolView(title: "Resize Image", accepts: Ext.image, actionTitle: "Resize") {
                HStack { Text("Longest side"); Slider(value: $px, in: 128...6000, step: 16).frame(width: 220); Text("\(Int(px)) px").monospacedDigit() }
            } run: { [px] files, out, prog in
                var r: [URL] = []
                for (i, f) in files.enumerated() {
                    let t = UTType(filenameExtension: f.pathExtension) ?? .png
                    let type: UTType = (t == .webP || t == .bmp) ? .png : t
                    r.append(try write(try cgImage(f, maxPixel: Int(px)), to: out.appendingPathComponent("\(stem(f)) \(Int(px)).\(type.preferredFilenameExtension ?? "png")"), type: type))
                    prog(Double(i + 1) / Double(files.count))
                }
                return r
            }
        }
    }

    static func compress() -> some View { CompressView() }
    struct CompressView: View {
        @State private var q = 0.7
        var body: some View {
            FileToolView(title: "Compress Image", accepts: Ext.image, actionTitle: "Compress") {
                HStack { Text("Quality"); Slider(value: $q, in: 0.2...0.95).frame(width: 220); Text("\(Int(q * 100))%").monospacedDigit() }
            } run: { [q] files, out, prog in
                var r: [URL] = []
                var before: Int64 = 0, after: Int64 = 0
                for (i, f) in files.enumerated() {
                    let u = try write(try cgImage(f), to: out.appendingPathComponent("\(stem(f)).jpg"), type: .jpeg, quality: q)
                    before += FileItem(url: f)?.size ?? 0; after += FileItem(url: u)?.size ?? 0
                    r.append(u); prog(Double(i + 1) / Double(files.count))
                }
                await MainActor.run { ActivityLog.shared.show("Saved \(Fmt.size(max(0, before - after))) (\(before > 0 ? Int(100 - after * 100 / before) : 0)% smaller)") }
                return r
            }
        }
    }

    static func strip() -> some View {
        FileToolView(title: "Remove Location & Camera Info", accepts: Ext.image, actionTitle: "Strip") { Text("Saves clean copies; originals are untouched.").font(.caption).foregroundStyle(.secondary) } run: { files, out, prog in
            var r: [URL] = []
            for (i, f) in files.enumerated() {
                guard let src = CGImageSourceCreateWithURL(f as CFURL, nil), let type = CGImageSourceGetType(src) else { continue }
                let dest = FileOps.uniqueURL(out.appendingPathComponent(f.lastPathComponent))
                guard let d = CGImageDestinationCreateWithURL(dest as CFURL, type, 1, nil) else { continue }
                let remove: [CFString: Any] = [kCGImagePropertyGPSDictionary: kCFNull!, kCGImagePropertyExifDictionary: kCFNull!, kCGImagePropertyTIFFDictionary: kCFNull!,
                                               kCGImagePropertyIPTCDictionary: kCFNull!, kCGImagePropertyMakerAppleDictionary: kCFNull!]
                CGImageDestinationAddImageFromSource(d, src, 0, remove as CFDictionary)
                if CGImageDestinationFinalize(d) { r.append(dest) }
                prog(Double(i + 1) / Double(files.count))
            }
            return r
        }
    }

    static func removeBackground() -> some View {
        FileToolView(title: "Remove Background", accepts: Ext.image, actionTitle: "Remove Background") { Text("Uses Apple's on-device subject detection.").font(.caption).foregroundStyle(.secondary) } run: { files, out, prog in
            var r: [URL] = []
            for (i, f) in files.enumerated() {
                let img = try cgImage(f)
                let req = VNGenerateForegroundInstanceMaskRequest()
                let h = VNImageRequestHandler(cgImage: img)
                try h.perform([req])
                guard let res = req.results?.first else { throw ToolError("No subject found in \(f.lastPathComponent)") }
                let buf = try res.generateMaskedImage(ofInstances: res.allInstances, from: h, croppedToInstancesExtent: false)
                let ci = CIImage(cvPixelBuffer: buf)
                guard let cg = CIContext().createCGImage(ci, from: ci.extent) else { continue }
                r.append(try write(cg, to: out.appendingPathComponent("\(stem(f)) cutout.png"), type: .png))
                prog(Double(i + 1) / Double(files.count))
            }
            return r
        }
    }

    static func watermark() -> some View { WatermarkView() }
    struct WatermarkView: View {
        @State private var text = "© \(Calendar.current.component(.year, from: Date()))"
        @State private var opacity = 0.6
        var body: some View {
            FileToolView(title: "Add Watermark", accepts: Ext.image, actionTitle: "Add Watermark") {
                HStack { TextField("Text", text: $text).textFieldStyle(.roundedBorder).frame(width: 220); Text("Opacity"); Slider(value: $opacity, in: 0.1...1).frame(width: 120) }
            } run: { [text, opacity] files, out, prog in
                var r: [URL] = []
                for (i, f) in files.enumerated() {
                    let cg = try cgImage(f)
                    let w = cg.width, h = cg.height
                    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
                    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
                    let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
                    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ns
                    let size = CGFloat(max(14, min(w, h) / 22))
                    let attr: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: .semibold), .foregroundColor: NSColor.white.withAlphaComponent(opacity),
                                                               .strokeColor: NSColor.black.withAlphaComponent(opacity * 0.5), .strokeWidth: -2]
                    let s = NSAttributedString(string: text, attributes: attr)
                    let sz = s.size()
                    s.draw(at: CGPoint(x: CGFloat(w) - sz.width - size, y: size * 0.8))
                    NSGraphicsContext.restoreGraphicsState()
                    guard let outImg = ctx.makeImage() else { continue }
                    let t = UTType(filenameExtension: f.pathExtension) ?? .png
                    r.append(try write(outImg, to: out.appendingPathComponent(f.lastPathComponent), type: t == .jpeg ? .jpeg : .png))
                    prog(Double(i + 1) / Double(files.count))
                }
                return r
            }
        }
    }
}

// MARK: - OCR

enum OCR {
    static func text(in img: CGImage) -> String {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        req.automaticallyDetectsLanguage = true
        try? VNImageRequestHandler(cgImage: img).perform([req])
        return (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
    static func text(of url: URL) -> String {
        if url.pathExtension.lowercased() == "pdf", let d = PDFDocument(url: url) {
            if let s = d.string, s.trimmingCharacters(in: .whitespacesAndNewlines).count > 20 { return s }
            return (0..<d.pageCount).compactMap { i -> String? in
                guard let p = d.page(at: i) else { return nil }
                let b = p.bounds(for: .mediaBox)
                guard let cg = p.thumbnail(of: CGSize(width: b.width * 2, height: b.height * 2), for: .mediaBox).cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
                return text(in: cg)
            }.joined(separator: "\n\n")
        }
        guard let cg = try? ImageTools.cgImage(url) else { return "" }
        return text(in: cg)
    }
}

struct OCRTool: View {
    @State private var files: [URL] = []
    @State private var result = ""
    @State private var working = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("Choose Images…") { files = pickFiles(Ext.image + Ext.pdf); run() }
                Button("Capture Screen Area…") { capture() }.help("Select part of the screen and read its text")
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Text("Drop images or PDFs anywhere here").foregroundStyle(.secondary).font(.callout)
            }
            TextPane(title: "Text found", text: $result, mono: false)
        }
        .padding(20)
        .dropDestination(for: URL.self) { urls, _ in files = urls; run(); return true }
        .onAppear { let f = ToolInbox.shared.take(); if !f.isEmpty { files = f; run() } }
    }
    func run() {
        guard !files.isEmpty else { return }
        working = true
        let f = files
        Task.detached {
            let t = f.map { u in f.count > 1 ? "— \(u.lastPathComponent) —\n" + OCR.text(of: u) : OCR.text(of: u) }.joined(separator: "\n\n")
            await MainActor.run {
                result = t; working = false
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(t, forType: .string)
                ActivityLog.shared.show("Copied text from \(f.count) file\(f.count == 1 ? "" : "s")")
            }
        }
    }
    func capture() {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("spyglass-ocr.png")
        try? FileManager.default.removeItem(at: tmp)
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture"); p.arguments = ["-i", "-x", tmp.path]
        p.terminationHandler = { _ in DispatchQueue.main.async { if FileManager.default.fileExists(atPath: tmp.path) { files = [tmp]; run() } } }
        try? p.run()
    }
}

struct ColorPickerTool: View {
    @State private var color = NSColor.systemBlue
    @State private var history: [NSColor] = []
    var hex: String { let c = color.usingColorSpace(.sRGB) ?? color; return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255)) }
    var rgb: String { let c = color.usingColorSpace(.sRGB) ?? color; return "rgb(\(Int(c.redComponent * 255)), \(Int(c.greenComponent * 255)), \(Int(c.blueComponent * 255)))" }
    var hsl: String {
        let c = color.usingColorSpace(.sRGB) ?? color
        let r = c.redComponent, g = c.greenComponent, b = c.blueComponent
        let mx = max(r, g, b), mn = min(r, g, b), l = (mx + mn) / 2
        var h: CGFloat = 0, s: CGFloat = 0
        if mx != mn {
            let d = mx - mn
            s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
            h = mx == r ? (g - b) / d + (g < b ? 6 : 0) : mx == g ? (b - r) / d + 2 : (r - g) / d + 4
            h /= 6
        }
        return "hsl(\(Int(h * 360)), \(Int(s * 100))%, \(Int(l * 100))%)"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 20) {
                RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: color)).frame(width: 120, height: 120).shadow(radius: 3)
                VStack(alignment: .leading, spacing: 8) {
                    CopyRow(label: "HEX", value: hex); CopyRow(label: "RGB", value: rgb); CopyRow(label: "HSL", value: hsl)
                    CopyRow(label: "SwiftUI", value: { let c = color.usingColorSpace(.sRGB) ?? color; return String(format: "Color(red: %.3f, green: %.3f, blue: %.3f)", c.redComponent, c.greenComponent, c.blueComponent) }())
                }
            }
            HStack {
                Button { NSColorSampler().show { c in if let c { color = c; history.insert(c, at: 0); history = Array(history.prefix(16)) } } } label: { Label("Pick from Screen", systemImage: "eyedropper") }.buttonStyle(.borderedProminent)
                ColorPicker("", selection: Binding(get: { Color(nsColor: color) }, set: { color = NSColor($0) })).labelsHidden()
            }
            HStack { ForEach(Array(history.enumerated()), id: \.offset) { _, c in Circle().fill(Color(nsColor: c)).frame(width: 22, height: 22).onTapGesture { color = c } } }
            Spacer()
        }.padding(20)
    }
}

// MARK: - Media (AVFoundation)

enum MediaTools {
    static func export(_ asset: AVAsset, preset: String, to u: URL, type: AVFileType, range: CMTimeRange? = nil, prog: @escaping (Double) -> Void) async throws -> URL {
        guard let s = AVAssetExportSession(asset: asset, presetName: preset) else { throw ToolError("This file can't be exported with that setting") }
        let dest = FileOps.uniqueURL(u)
        s.outputURL = dest
        s.outputFileType = s.supportedFileTypes.contains(type) ? type : s.supportedFileTypes.first
        if let range { s.timeRange = range }
        s.shouldOptimizeForNetworkUse = true
        let timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in prog(Double(s.progress)) }
        defer { timer.invalidate() }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in s.exportAsynchronously { c.resume() } }
        if s.status != .completed { throw ToolError(s.error?.localizedDescription ?? "Export failed") }
        return dest
    }

    static func convertMP4() -> some View {
        FileToolView(title: "Convert to MP4", accepts: Ext.video, actionTitle: "Convert") { EmptyView() } run: { files, out, prog in
            var r: [URL] = []
            for f in files { r.append(try await export(AVURLAsset(url: f), preset: AVAssetExportPresetHighestQuality, to: out.appendingPathComponent("\(stem(f)).mp4"), type: .mp4, prog: prog)) }
            return r
        }
    }

    static func compress() -> some View { CompressVideoView() }
    struct CompressVideoView: View {
        @State private var preset = AVAssetExportPreset1280x720
        var body: some View {
            FileToolView(title: "Compress Video", accepts: Ext.video, actionTitle: "Compress") {
                Picker("Size", selection: $preset) {
                    Text("1080p").tag(AVAssetExportPreset1920x1080); Text("720p").tag(AVAssetExportPreset1280x720); Text("540p").tag(AVAssetExportPreset960x540)
                    Text("Smallest").tag(AVAssetExportPresetMediumQuality); Text("HEVC 1080p").tag(AVAssetExportPresetHEVC1920x1080)
                }.pickerStyle(.segmented).frame(width: 460)
            } run: { [preset] files, out, prog in
                var r: [URL] = []
                for f in files { r.append(try await export(AVURLAsset(url: f), preset: preset, to: out.appendingPathComponent("\(stem(f)) small.mp4"), type: .mp4, prog: prog)) }
                return r
            }
        }
    }

    static func trim(audio: Bool) -> some View { TrimView(audio: audio) }
    struct TrimView: View {
        let audio: Bool
        @State private var start = "0:00"
        @State private var end = "0:30"
        func secs(_ s: String) -> Double { s.split(separator: ":").reduce(0) { $0 * 60 + (Double($1) ?? 0) } }
        var body: some View {
            FileToolView(title: audio ? "Trim Audio" : "Trim Video", accepts: audio ? Ext.audio : Ext.video, actionTitle: "Trim", multiple: false) {
                HStack { Text("From"); TextField("0:00", text: $start).frame(width: 80); Text("to"); TextField("0:30", text: $end).frame(width: 80); Text("(m:ss)").foregroundStyle(.secondary) }.textFieldStyle(.roundedBorder)
            } run: { [audio] files, out, prog in
                let a = AVURLAsset(url: files[0])
                let range = CMTimeRange(start: CMTime(seconds: secs(start), preferredTimescale: 600), end: CMTime(seconds: secs(end), preferredTimescale: 600))
                guard range.duration.seconds > 0 else { throw ToolError("The end must be after the start") }
                return [try await export(a, preset: audio ? AVAssetExportPresetAppleM4A : AVAssetExportPresetHighestQuality, to: out.appendingPathComponent("\(stem(files[0])) trimmed.\(audio ? "m4a" : "mp4")"),
                                         type: audio ? .m4a : .mp4, range: range, prog: prog)]
            }
        }
    }

    static func mute() -> some View {
        FileToolView(title: "Mute Video", accepts: Ext.video, actionTitle: "Mute") { EmptyView() } run: { files, out, prog in
            var r: [URL] = []
            for f in files {
                let a = AVURLAsset(url: f)
                let comp = AVMutableComposition()
                guard let v = try await a.loadTracks(withMediaType: .video).first, let ct = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
                let dur = try await a.load(.duration)
                try ct.insertTimeRange(CMTimeRange(start: .zero, duration: dur), of: v, at: .zero)
                ct.preferredTransform = try await v.load(.preferredTransform)
                r.append(try await export(comp, preset: AVAssetExportPresetPassthrough, to: out.appendingPathComponent("\(stem(f)) muted.mov"), type: .mov, prog: prog))
            }
            return r
        }
    }

    static func speed() -> some View { SpeedView() }
    struct SpeedView: View {
        @State private var rate = 2.0
        var body: some View {
            FileToolView(title: "Change Speed", accepts: Ext.video, actionTitle: "Change Speed") {
                Picker("Speed", selection: $rate) { ForEach([0.25, 0.5, 0.75, 1.5, 2, 3, 4], id: \.self) { Text("\($0, specifier: "%g")×").tag($0) } }.pickerStyle(.segmented).frame(width: 420)
            } run: { [rate] files, out, prog in
                var r: [URL] = []
                for f in files {
                    let a = AVURLAsset(url: f)
                    let comp = AVMutableComposition()
                    let dur = try await a.load(.duration)
                    let full = CMTimeRange(start: .zero, duration: dur)
                    for type in [AVMediaType.video, .audio] {
                        for t in try await a.loadTracks(withMediaType: type) {
                            let ct = comp.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid)
                            try ct?.insertTimeRange(full, of: t, at: .zero)
                            if type == .video { ct?.preferredTransform = try await t.load(.preferredTransform) }
                        }
                    }
                    comp.scaleTimeRange(full, toDuration: CMTimeMultiplyByFloat64(dur, multiplier: 1 / rate))
                    r.append(try await export(comp, preset: AVAssetExportPresetHighestQuality, to: out.appendingPathComponent("\(stem(f)) \(rate)x.mp4"), type: .mp4, prog: prog))
                }
                return r
            }
        }
    }

    static func gif() -> some View { GIFView() }
    struct GIFView: View {
        @State private var fps = 10.0
        @State private var width = 480.0
        @State private var maxSecs = 10.0
        var body: some View {
            FileToolView(title: "Video to GIF", accepts: Ext.video, actionTitle: "Make GIF") {
                HStack {
                    Text("Width"); Slider(value: $width, in: 200...1000, step: 20).frame(width: 120); Text("\(Int(width))").monospacedDigit()
                    Text("FPS"); Stepper("\(Int(fps))", value: $fps, in: 4...24)
                    Text("Max seconds"); Stepper("\(Int(maxSecs))", value: $maxSecs, in: 2...30)
                }
            } run: { [fps, width, maxSecs] files, out, prog in
                var r: [URL] = []
                for f in files {
                    let a = AVURLAsset(url: f)
                    let dur = min(try await a.load(.duration).seconds, maxSecs)
                    let gen = AVAssetImageGenerator(asset: a)
                    gen.appliesPreferredTrackTransform = true
                    gen.maximumSize = CGSize(width: width, height: width * 2)
                    gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
                    let n = max(1, Int(dur * fps))
                    let dest = FileOps.uniqueURL(out.appendingPathComponent("\(stem(f)).gif"))
                    guard let d = CGImageDestinationCreateWithURL(dest as CFURL, UTType.gif.identifier as CFString, n, nil) else { continue }
                    CGImageDestinationSetProperties(d, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
                    let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary
                    for i in 0..<n {
                        if let img = try? await gen.image(at: CMTime(seconds: Double(i) / fps, preferredTimescale: 600)).image { CGImageDestinationAddImage(d, img, frameProps) }
                        prog(Double(i + 1) / Double(n))
                    }
                    if CGImageDestinationFinalize(d) { r.append(dest) }
                }
                return r
            }
        }
    }

    static func frames() -> some View { FramesView() }
    struct FramesView: View {
        @State private var every = 5.0
        var body: some View {
            FileToolView(title: "Extract Frames", accepts: Ext.video, actionTitle: "Extract") {
                HStack { Text("One frame every"); Stepper("\(Int(every)) seconds", value: $every, in: 1...120) }
            } run: { [every] files, out, prog in
                var r: [URL] = []
                for f in files {
                    let a = AVURLAsset(url: f)
                    let dur = try await a.load(.duration).seconds
                    let gen = AVAssetImageGenerator(asset: a); gen.appliesPreferredTrackTransform = true
                    var t = 0.0, i = 1
                    while t < dur {
                        if let img = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image {
                            r.append(try ImageTools.write(img, to: out.appendingPathComponent("\(stem(f)) \(String(format: "%03d", i)).png"), type: .png))
                        }
                        prog(t / dur); t += every; i += 1
                    }
                }
                return r
            }
        }
    }

    static func extractAudio(title: String = "Extract Audio") -> some View {
        FileToolView(title: title, accepts: title == "Extract Audio" ? Ext.video : Ext.audio, actionTitle: title == "Extract Audio" ? "Extract" : "Convert") { EmptyView() } run: { files, out, prog in
            var r: [URL] = []
            for f in files { r.append(try await export(AVURLAsset(url: f), preset: AVAssetExportPresetAppleM4A, to: out.appendingPathComponent("\(stem(f)).m4a"), type: .m4a, prog: prog)) }
            return r
        }
    }
}

struct MediaInfoTool: View {
    @State private var rows: [(String, String)] = []
    @State private var file: URL?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Button("Choose File…") { if let f = pickFiles(Ext.media, multiple: false).first { load(f) } }; if let file { Text(file.lastPathComponent).font(.headline) } }
            if rows.isEmpty { EmptyState(symbol: "film", title: "Drop a video or audio file") }
            else { Form { ForEach(rows, id: \.0) { CopyRow(label: $0.0, value: $0.1) } }.formStyle(.grouped) }
        }
        .padding(20)
        .dropDestination(for: URL.self) { u, _ in if let f = u.first { load(f) }; return true }
        .onAppear { if let f = ToolInbox.shared.take().first { load(f) } }
    }
    func load(_ u: URL) {
        file = u
        Task {
            let a = AVURLAsset(url: u)
            var r: [(String, String)] = [("Size", Fmt.size(FileItem(url: u)?.size ?? 0))]
            if let d = try? await a.load(.duration) { let s = Int(d.seconds); r.append(("Duration", String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60))) }
            for t in (try? await a.loadTracks(withMediaType: .video)) ?? [] {
                if let s = try? await t.load(.naturalSize) { r.append(("Resolution", "\(Int(abs(s.width))) × \(Int(abs(s.height)))")) }
                if let f = try? await t.load(.nominalFrameRate) { r.append(("Frame rate", String(format: "%.2f fps", f))) }
                if let b = try? await t.load(.estimatedDataRate) { r.append(("Video bitrate", "\(Int(b / 1000)) kbps")) }
                if let fd = try? await t.load(.formatDescriptions).first { r.append(("Video codec", fourCC(CMFormatDescriptionGetMediaSubType(fd)))) }
            }
            for t in (try? await a.loadTracks(withMediaType: .audio)) ?? [] {
                if let b = try? await t.load(.estimatedDataRate) { r.append(("Audio bitrate", "\(Int(b / 1000)) kbps")) }
                if let fd = try? await t.load(.formatDescriptions).first {
                    r.append(("Audio codec", fourCC(CMFormatDescriptionGetMediaSubType(fd))))
                    if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee { r.append(("Sample rate", "\(Int(asbd.mSampleRate)) Hz · \(asbd.mChannelsPerFrame) ch")) }
                }
            }
            rows = r
        }
    }
    func fourCC(_ c: FourCharCode) -> String {
        let s = String([UInt8(c >> 24 & 255), UInt8(c >> 16 & 255), UInt8(c >> 8 & 255), UInt8(c & 255)].map { Character(UnicodeScalar($0)) })
        let names = ["avc1": "H.264", "hvc1": "HEVC (H.265)", "hev1": "HEVC (H.265)", "ap4h": "ProRes 4444", "apcn": "ProRes 422", "aac ": "AAC", ".mp3": "MP3", "lpcm": "PCM", "alac": "Apple Lossless", "av01": "AV1"]
        return names[s] ?? s
    }
}

struct RecordAudioTool: View {
    @State private var recorder: AVAudioRecorder?
    @State private var started: Date?
    @State private var last: URL?
    @State private var tick = Date()
    let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: recorder == nil ? "mic.circle" : "record.circle.fill").font(.system(size: 80)).foregroundStyle(recorder == nil ? Color.secondary : .red)
                .symbolEffect(.pulse, isActive: recorder != nil)
            Text(started.map { let s = Int(tick.timeIntervalSince($0)); return String(format: "%d:%02d", s / 60, s % 60) } ?? "Ready").font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
            Button(recorder == nil ? "Start Recording" : "Stop") { recorder == nil ? start() : stop() }.buttonStyle(.borderedProminent).controlSize(.large).tint(recorder == nil ? .accentColor : .red)
            if let last { Button("Show Recording") { FileOps.reveal([last]) } }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).onReceive(timer) { tick = $0 }
    }
    func start() {
        AVCaptureDevice.requestAccess(for: .audio) { ok in
            DispatchQueue.main.async {
                guard ok else { ActivityLog.shared.show("Allow the microphone in System Settings › Privacy"); return }
                let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
                let u = FileOps.outputFolder("Recordings").appendingPathComponent("Recording \(f.string(from: Date())).m4a")
                let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue]
                recorder = try? AVAudioRecorder(url: u, settings: settings)
                recorder?.record(); started = Date(); last = u
            }
        }
    }
    func stop() { recorder?.stop(); recorder = nil; started = nil; if let last { FileOps.created([last], title: "Recorded audio") } }
}

// MARK: - Archives (ditto + bsdtar, built into macOS)

enum ArchiveTools {
    static func canExtract(_ u: URL) -> Bool { Ext.archive.contains(u.pathExtension.lowercased()) || u.lastPathComponent.hasSuffix(".tar.gz") }

    @discardableResult
    static func runTool(_ path: String, _ args: [String]) async -> Int32 {
        await withCheckedContinuation { c in
            let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            p.terminationHandler = { c.resume(returning: $0.terminationStatus) }
            do { try p.run() } catch { c.resume(returning: -1) }
        }
    }

    @MainActor @discardableResult
    static func zip(_ urls: [URL], into dir: URL? = nil, record: Bool = true) async -> URL? {
        guard let first = urls.first else { return nil }
        let base = dir ?? first.deletingLastPathComponent()
        let name = urls.count == 1 ? first.lastPathComponent : "Archive"
        let dest = FileOps.uniqueURL(base.appendingPathComponent(name + ".zip"))
        let status: Int32
        if urls.count == 1 {
            status = await runTool("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", first.path, dest.path])
        } else {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("spyglass-zip-\(UUID().uuidString)/Archive")
            try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            for u in urls { try? FileManager.default.copyItem(at: u, to: tmp.appendingPathComponent(u.lastPathComponent)) }
            status = await runTool("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", tmp.path, dest.path])
            try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent())
        }
        if status == 0 { if record { FileOps.created([dest], title: "Compressed \(urls.count) item\(urls.count == 1 ? "" : "s") to \(dest.lastPathComponent)") }; return dest }
        ActivityLog.shared.show("Couldn't create the ZIP"); return nil
    }

    @MainActor @discardableResult
    static func extract(_ u: URL, into dir: URL, record: Bool = true) async -> URL? {
        let dest = FileOps.uniqueURL(dir.appendingPathComponent(u.deletingPathExtension().lastPathComponent.replacingOccurrences(of: ".tar", with: "")))
        try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let status = u.pathExtension.lowercased() == "zip"
            ? await runTool("/usr/bin/ditto", ["-x", "-k", u.path, dest.path])
            : await runTool("/usr/bin/bsdtar", ["-x", "-f", u.path, "-C", dest.path])
        if status == 0 { if record { FileOps.created([dest], title: "Extracted \(u.lastPathComponent)") }; return dest }
        try? FileManager.default.removeItem(at: dest)
        ActivityLog.shared.show("Couldn't extract \(u.lastPathComponent) (newer RAR5 archives may not be supported)")
        return nil
    }

    static func zipView() -> some View {
        FileToolView(title: "Compress to ZIP", accepts: [], actionTitle: "Compress") { Text("Files and folders go into one ZIP.").font(.caption).foregroundStyle(.secondary) } run: { files, out, _ in
            if let z = await zip(files, into: out, record: false) { return [z] }
            throw ToolError("Couldn't create the ZIP")
        }
    }
    static func unzipView() -> some View {
        FileToolView(title: "Extract Archive", accepts: Ext.archive, actionTitle: "Extract") { EmptyView() } run: { files, out, prog in
            var r: [URL] = []
            for (i, f) in files.enumerated() { if let d = await extract(f, into: out, record: false) { r.append(d) }; prog(Double(i + 1) / Double(files.count)) }
            return r
        }
    }
}
