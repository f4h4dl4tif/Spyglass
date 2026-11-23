import SwiftUI
import UniformTypeIdentifiers

enum ToolCategory: String, CaseIterable, Identifiable, Hashable {
    case pdf, image, video, audio, text, mac, developer, archive
    var id: String { rawValue }
    var title: String {
        switch self {
        case .pdf: "PDF"; case .image: "Image"; case .video: "Video"; case .audio: "Audio"; case .text: "Text & Speech"
        case .mac: "Mac Utilities"; case .developer: "Developer"; case .archive: "Archives"
        }
    }
    var symbol: String {
        switch self {
        case .pdf: "doc.richtext"; case .image: "photo"; case .video: "film"; case .audio: "waveform"; case .text: "text.bubble"
        case .mac: "desktopcomputer"; case .developer: "curlybraces"; case .archive: "archivebox"
        }
    }
    var color: Color {
        switch self {
        case .pdf: .red; case .image: .pink; case .video: .purple; case .audio: .orange; case .text: .blue
        case .mac: .gray; case .developer: .green; case .archive: .brown
        }
    }
}

struct Tool: Identifiable {
    let id: String
    let name: String
    let symbol: String
    let category: ToolCategory
    let detail: String
    var accepts: [String] = []          // file extensions this tool takes (for "Tools" menus and drops)
    let view: () -> AnyView
}

/// Files handed to a tool from a context menu or drop.
@MainActor final class ToolInbox: ObservableObject {
    static let shared = ToolInbox()
    @Published var files: [URL] = []
    func take() -> [URL] { let f = files; files = []; return f }
}

enum Ext {
    static let pdf = ["pdf"]
    static let image = ["png", "jpg", "jpeg", "heic", "heif", "tiff", "tif", "gif", "bmp", "webp"]
    static let video = ["mov", "mp4", "m4v", "avi", "mkv", "webm"]
    static let audio = ["mp3", "m4a", "wav", "aiff", "aif", "caf", "flac", "aac"]
    static let media = video + audio
    static let docs = ["txt", "md", "rtf", "doc", "docx", "html", "htm", "odt", "csv", "json"]
    static let archive = ["zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "cpio", "iso"]
}

enum ToolCatalog {
    static let all: [Tool] = [
        // PDF
        Tool(id: "pdfmerge", name: "Merge PDFs", symbol: "doc.on.doc", category: .pdf, detail: "Combine PDFs into one, in the order you choose", accepts: Ext.pdf) { AnyView(PDFTools.merge()) },
        Tool(id: "pdfsplit", name: "Split PDF", symbol: "scissors", category: .pdf, detail: "Save every page as its own PDF", accepts: Ext.pdf) { AnyView(PDFTools.split()) },
        Tool(id: "pdfdelete", name: "Delete Pages", symbol: "minus.rectangle", category: .pdf, detail: "Remove pages like 2, 5-7", accepts: Ext.pdf) { AnyView(PDFTools.deletePages()) },
        Tool(id: "pdfrotate", name: "Rotate Pages", symbol: "rotate.right", category: .pdf, detail: "Turn every page 90°, 180° or 270°", accepts: Ext.pdf) { AnyView(PDFTools.rotate()) },
        Tool(id: "pdfprotect", name: "Add Password", symbol: "lock.doc", category: .pdf, detail: "Encrypt a PDF with a password", accepts: Ext.pdf) { AnyView(PDFTools.protect()) },
        Tool(id: "pdfunlock", name: "Remove Password", symbol: "lock.open", category: .pdf, detail: "Save an unlocked copy (you need the password)", accepts: Ext.pdf) { AnyView(PDFTools.unlock()) },
        Tool(id: "pdfcompress", name: "Compress PDF", symbol: "arrow.down.right.and.arrow.up.left", category: .pdf, detail: "Shrink images inside a PDF", accepts: Ext.pdf) { AnyView(PDFTools.compress()) },
        Tool(id: "pdftoimages", name: "PDF to Images", symbol: "photo.stack", category: .pdf, detail: "Export each page as PNG", accepts: Ext.pdf) { AnyView(PDFTools.toImages()) },
        Tool(id: "imagestopdf", name: "Images to PDF", symbol: "doc.badge.plus", category: .pdf, detail: "Turn photos or scans into one PDF", accepts: Ext.image) { AnyView(PDFTools.fromImages()) },
        Tool(id: "pdfsign", name: "Sign PDF", symbol: "signature", category: .pdf, detail: "Draw or type your signature and place it", accepts: Ext.pdf) { AnyView(SignPDFTool()) },
        Tool(id: "pdfredact", name: "Redact PDF", symbol: "rectangle.fill.badge.minus", category: .pdf, detail: "Black out text for good — boxes, words, emails, phones", accepts: Ext.pdf) { AnyView(RedactPDFTool()) },
        Tool(id: "pdftext", name: "Extract Text", symbol: "text.viewfinder", category: .pdf, detail: "Pull all text out of PDFs to .txt", accepts: Ext.pdf) { AnyView(PDFTools.extractText()) },
        // Image
        Tool(id: "imgconvert", name: "Convert Image", symbol: "arrow.triangle.2.circlepath", category: .image, detail: "PNG, JPEG, HEIC, TIFF, GIF", accepts: Ext.image) { AnyView(ImageTools.convert()) },
        Tool(id: "imgresize", name: "Resize Image", symbol: "arrow.up.left.and.arrow.down.right", category: .image, detail: "Fit images within a size", accepts: Ext.image) { AnyView(ImageTools.resize()) },
        Tool(id: "imgcompress", name: "Compress Image", symbol: "rectangle.compress.vertical", category: .image, detail: "Smaller JPEGs with a quality slider", accepts: Ext.image) { AnyView(ImageTools.compress()) },
        Tool(id: "imgstrip", name: "Remove Location & Camera Info", symbol: "location.slash", category: .image, detail: "Strip GPS and EXIF before sharing", accepts: Ext.image) { AnyView(ImageTools.strip()) },
        Tool(id: "imgbg", name: "Remove Background", symbol: "person.crop.rectangle", category: .image, detail: "Cut out the subject to a transparent PNG", accepts: Ext.image) { AnyView(ImageTools.removeBackground()) },
        Tool(id: "imgwatermark", name: "Add Watermark", symbol: "signature", category: .image, detail: "Stamp text on the corner of images", accepts: Ext.image) { AnyView(ImageTools.watermark()) },
        Tool(id: "ocr", name: "Copy Text from Images", symbol: "text.viewfinder", category: .image, detail: "Read text in photos and screenshots on-device", accepts: Ext.image + Ext.pdf) { AnyView(OCRTool()) },
        Tool(id: "colorpicker", name: "Color Picker", symbol: "eyedropper", category: .image, detail: "Pick any pixel on screen: HEX, RGB, HSL") { AnyView(ColorPickerTool()) },
        // Video
        Tool(id: "vidconvert", name: "Convert to MP4", symbol: "film.stack", category: .video, detail: "Make videos play anywhere", accepts: Ext.video) { AnyView(MediaTools.convertMP4()) },
        Tool(id: "vidcompress", name: "Compress Video", symbol: "rectangle.compress.vertical", category: .video, detail: "Smaller files at 1080p, 720p or 540p", accepts: Ext.video) { AnyView(MediaTools.compress()) },
        Tool(id: "vidtrim", name: "Trim Video", symbol: "timeline.selection", category: .video, detail: "Keep just the part you want", accepts: Ext.video) { AnyView(MediaTools.trim(audio: false)) },
        Tool(id: "vidmute", name: "Mute Video", symbol: "speaker.slash", category: .video, detail: "Remove the sound track", accepts: Ext.video) { AnyView(MediaTools.mute()) },
        Tool(id: "vidspeed", name: "Change Speed", symbol: "gauge.with.dots.needle.67percent", category: .video, detail: "0.25× to 4×", accepts: Ext.video) { AnyView(MediaTools.speed()) },
        Tool(id: "vidgif", name: "Video to GIF", symbol: "photo.on.rectangle.angled", category: .video, detail: "Short clips to animated GIFs", accepts: Ext.video) { AnyView(MediaTools.gif()) },
        Tool(id: "vidframes", name: "Extract Frames", symbol: "square.stack.3d.down.right", category: .video, detail: "Save a still every few seconds", accepts: Ext.video) { AnyView(MediaTools.frames()) },
        Tool(id: "screenrecord", name: "Record Screen", symbol: "record.circle", category: .video, detail: "Record your screen to a movie") { AnyView(ScreenRecordTool()) },
        Tool(id: "transcribe", name: "Transcribe", symbol: "captions.bubble", category: .audio, detail: "Speech to text or SRT subtitles, on-device", accepts: Ext.media) { AnyView(TranscribeTool()) },
        Tool(id: "mediainfo", name: "Media Info", symbol: "info.circle", category: .video, detail: "Codec, resolution, frame rate, bitrate", accepts: Ext.media) { AnyView(MediaInfoTool()) },
        // Audio
        Tool(id: "audextract", name: "Extract Audio", symbol: "waveform.badge.plus", category: .audio, detail: "Save a video's sound as M4A", accepts: Ext.video) { AnyView(MediaTools.extractAudio()) },
        Tool(id: "audconvert", name: "Convert Audio", symbol: "arrow.triangle.2.circlepath", category: .audio, detail: "Any audio to M4A (AAC)", accepts: Ext.audio) { AnyView(MediaTools.extractAudio(title: "Convert Audio")) },
        Tool(id: "audtrim", name: "Trim Audio", symbol: "timeline.selection", category: .audio, detail: "Cut the start or end", accepts: Ext.audio) { AnyView(MediaTools.trim(audio: true)) },
        Tool(id: "audrecord", name: "Record Audio", symbol: "mic.circle", category: .audio, detail: "Record your microphone to M4A") { AnyView(RecordAudioTool()) },
        // Text
        Tool(id: "summarize", name: "Summarize", symbol: "text.append", category: .text, detail: "Key points of any PDF, document or text", accepts: Ext.pdf + Ext.docs) { AnyView(DocumentAITool(ask: false)) },
        Tool(id: "askdoc", name: "Ask About a Document", symbol: "questionmark.bubble", category: .text, detail: "Ask questions; answers come from the file", accepts: Ext.pdf + Ext.docs) { AnyView(DocumentAITool(ask: true)) },
        Tool(id: "smartrename", name: "Smart Rename", symbol: "wand.and.rays", category: .text, detail: "Name IMG_1234-style files from what's in them", accepts: Ext.image + Ext.pdf + Ext.docs) { AnyView(SmartRenameTool()) },
        Tool(id: "readaloud", name: "Read Aloud", symbol: "speaker.wave.2", category: .text, detail: "Hear any text in a natural voice") { AnyView(ReadAloudTool()) },
        Tool(id: "translate", name: "Translate", symbol: "translate", category: .text, detail: "On-device translation") { AnyView(TranslateTool()) },
        Tool(id: "wordcount", name: "Word Count", symbol: "number", category: .text, detail: "Words, characters, lines and reading time") { AnyView(WordCountTool()) },
        Tool(id: "changecase", name: "Change Case", symbol: "textformat", category: .text, detail: "UPPER, lower, Title, camelCase, snake_case") { AnyView(ChangeCaseTool()) },
        Tool(id: "qrcode", name: "QR Codes", symbol: "qrcode", category: .text, detail: "Make a QR code from text or a link") { AnyView(QRTool()) },
        // Mac
        Tool(id: "keepawake", name: "Keep Awake", symbol: "cup.and.saucer", category: .mac, detail: "Stop your Mac from sleeping for a while") { AnyView(KeepAwakeTool()) },
        Tool(id: "clipboard", name: "Clipboard History", symbol: "list.clipboard", category: .mac, detail: "Your last 50 copies, ⌃⌥V from anywhere") { AnyView(ClipboardTool()) },
        Tool(id: "battery", name: "Battery Health", symbol: "battery.75", category: .mac, detail: "Charge, health and cycle count") { AnyView(BatteryTool()) },
        Tool(id: "networkspeed", name: "Network Speed", symbol: "speedometer", category: .mac, detail: "Download, upload and responsiveness") { AnyView(NetworkSpeedTool()) },
        Tool(id: "diskspeed", name: "Disk Speed", symbol: "internaldrive", category: .mac, detail: "Read and write speed of any drive") { AnyView(DiskSpeedTool()) },
        Tool(id: "cleankeyboard", name: "Clean Keyboard", symbol: "keyboard", category: .mac, detail: "Lock the keyboard while you wipe it") { AnyView(CleanKeyboardTool()) },
        Tool(id: "pixeltest", name: "Display Pixel Test", symbol: "display", category: .mac, detail: "Full-screen colours to spot dead pixels") { AnyView(PixelTestTool()) },
        Tool(id: "ejectall", name: "Eject All Disks", symbol: "eject", category: .mac, detail: "Safely eject every external drive") { AnyView(EjectAllTool()) },
        Tool(id: "cleardesktop", name: "Clear Desktop", symbol: "menubar.dock.rectangle", category: .mac, detail: "Hide desktop icons for screen sharing") { AnyView(ClearDesktopTool()) },
        Tool(id: "wifi", name: "Share Wi-Fi", symbol: "wifi", category: .mac, detail: "A QR code guests can scan to join") { AnyView(WiFiTool()) },
        Tool(id: "unblock", name: "Unblock App", symbol: "checkmark.shield", category: .mac, detail: "Open an app macOS says is from an unidentified developer") { AnyView(UnblockTool()) },
        Tool(id: "shortcuts", name: "Keyboard Shortcuts", symbol: "command", category: .mac, detail: "Every Spyglass shortcut") { AnyView(ShortcutsTool()) },
        // Developer
        Tool(id: "json", name: "JSON Formatter", symbol: "curlybraces", category: .developer, detail: "Pretty-print, minify and validate") { AnyView(JSONTool()) },
        Tool(id: "base64", name: "Base64", symbol: "textformat.abc", category: .developer, detail: "Encode and decode") { AnyView(Base64Tool()) },
        Tool(id: "hash", name: "Hash Generator", symbol: "number.square", category: .developer, detail: "MD5, SHA-1, SHA-256, SHA-512 of text or files") { AnyView(HashTool()) },
        Tool(id: "uuid", name: "UUID Generator", symbol: "dice", category: .developer, detail: "Random UUIDs in bulk") { AnyView(UUIDTool()) },
        Tool(id: "jwt", name: "JWT Decoder", symbol: "key.horizontal", category: .developer, detail: "Read a token's header and claims") { AnyView(JWTTool()) },
        Tool(id: "timestamp", name: "Timestamp Converter", symbol: "clock", category: .developer, detail: "Unix time ⇄ dates") { AnyView(TimestampTool()) },
        Tool(id: "diff", name: "Compare Text", symbol: "arrow.left.arrow.right", category: .developer, detail: "Line-by-line differences") { AnyView(DiffTool()) },
        Tool(id: "regex", name: "Regex Tester", symbol: "asterisk", category: .developer, detail: "Live matches and groups") { AnyView(RegexTool()) },
        Tool(id: "url", name: "Tidy Links", symbol: "link", category: .developer, detail: "Strip tracking, encode and decode URLs") { AnyView(URLTool()) },
        Tool(id: "unicode", name: "Unicode Inspector", symbol: "character.magnify", category: .developer, detail: "Code points of every character") { AnyView(UnicodeTool()) },
        Tool(id: "lorem", name: "Placeholder Text", symbol: "text.alignleft", category: .developer, detail: "Lorem ipsum paragraphs") { AnyView(LoremTool()) },
        Tool(id: "password", name: "Password Generator", symbol: "key", category: .developer, detail: "Strong random passwords") { AnyView(PasswordTool()) },
        Tool(id: "csvjson", name: "CSV & JSON", symbol: "tablecells", category: .developer, detail: "Convert between CSV and JSON") { AnyView(CSVJSONTool()) },
        // Archives
        Tool(id: "zip", name: "Compress to ZIP", symbol: "archivebox", category: .archive, detail: "Zip files and folders") { AnyView(ArchiveTools.zipView()) },
        Tool(id: "unzip", name: "Extract Archive", symbol: "archivebox.circle", category: .archive, detail: "ZIP, TAR, GZ, 7Z, RAR and more", accepts: Ext.archive) { AnyView(ArchiveTools.unzipView()) },
    ]

    static func tool(_ id: String) -> Tool? { all.first { $0.id == id } }
    static func tools(in c: ToolCategory) -> [Tool] { all.filter { $0.category == c } }
    static func tools(for urls: [URL]) -> [Tool] {
        let exts = Set(urls.map { $0.pathExtension.lowercased() })
        return all.filter { t in !t.accepts.isEmpty && exts.allSatisfy { t.accepts.contains($0) } }
    }
    static var favorites: [Tool] { ["ocr", "summarize", "pdfmerge", "smartrename", "transcribe", "keepawake"].compactMap(tool) }
}

// MARK: - Grid & host

struct ToolsGridView: View {
    let category: ToolCategory?
    @EnvironmentObject var model: AppModel
    @State private var filter = ""
    @State private var dropTarget: String?
    @Environment(\.glassOn) private var glassOn

    var body: some View {
        let list = (category.map(ToolCatalog.tools(in:)) ?? ToolCatalog.all).filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) || $0.detail.localizedCaseInsensitiveContains(filter) }
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(title: category?.title ?? "Tools", subtitle: "\(list.count) tools · everything runs on this Mac · drop files on a tool", symbol: category?.symbol ?? "wrench.and.screwdriver", tint: category?.color ?? .accentColor) {
                    TextField("Filter tools", text: $filter).textFieldStyle(.roundedBorder).frame(width: 200)
                }
                ForEach(category.map { [$0] } ?? ToolCategory.allCases) { c in
                    let tools = list.filter { $0.category == c }
                    if !tools.isEmpty {
                        if category == nil { Text(c.title).font(.headline).padding(.top, 4) }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 12)], spacing: 12) {
                            ForEach(tools) { t in
                                Button { model.show(.tool(t.id)) } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: t.symbol).font(.system(size: 18, weight: .medium)).foregroundStyle(.white)
                                            .frame(width: 36, height: 36).background((Theme.playful ? t.category.color : .gray).gradient, in: RoundedRectangle(cornerRadius: 9))
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(t.name).font(.callout.weight(.semibold)).foregroundStyle(.primary)
                                            Text(t.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                        }
                                        Spacer(minLength: 0)
                                    }
                                    .padding(12).frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                                    .background(glassOn ? Color.clear : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                                    .glassPanel(glassOn, in: RoundedRectangle(cornerRadius: 12), interactive: true)
                                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(dropTarget == t.id ? Color.accentColor : Color.primary.opacity(glassOn ? 0 : 0.07), lineWidth: dropTarget == t.id ? 2 : 1))
                                    .scaleEffect(dropTarget == t.id ? 1.03 : 1)
                                    .animation(.spring(duration: 0.25), value: dropTarget)
                                }
                                .buttonStyle(.plain)
                                .dropDestination(for: URL.self) { urls, _ in
                                    ToolInbox.shared.files = Array(urls.prefix(2000)); model.show(.tool(t.id)); return true
                                } isTargeted: { dropTarget = $0 ? t.id : (dropTarget == t.id ? nil : dropTarget) }
                            }
                        }
                    }
                }
            }.padding(22)
        }
    }
}

struct ToolHost: View {
    let id: String
    @EnvironmentObject var model: AppModel
    var body: some View {
        if let t = ToolCatalog.tool(id) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    PageHeader(title: t.name, subtitle: t.detail, symbol: t.symbol, tint: Theme.playful ? t.category.color : .gray)
                    Button("All \(t.category.title) Tools") { model.show(.tools(t.category)) }.buttonStyle(.borderless)
                }.padding(20)
                Divider()
                t.view().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).id(id)
            }
        } else { EmptyState(symbol: "questionmark", title: "Tool not found") }
    }
}

// MARK: - Shared building blocks

/// Drop zone + file list + options + Run, used by every file tool. Output goes to ~/Downloads/Spyglass/<tool> <date>.
struct FileToolView<Options: View>: View {
    let title: String
    let accepts: [String]
    var actionTitle = "Run"
    var multiple = true
    @ViewBuilder var options: Options
    let run: ([URL], URL, @escaping (Double) -> Void) async throws -> [URL]

    @State private var files: [URL] = []
    @State private var running = false
    @State private var progress = 0.0
    @State private var outputs: [URL] = []
    @State private var error: String?
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14).strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [7]))
                    .foregroundStyle(targeted ? Color.accentColor : .secondary.opacity(0.4))
                    .background(targeted ? Color.accentColor.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 14))
                if files.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "tray.and.arrow.down").font(.system(size: 30)).foregroundStyle(.secondary)
                        Text("Drop \(accepts.isEmpty ? "files" : accepts.prefix(6).map { $0.uppercased() }.joined(separator: ", ")) here").foregroundStyle(.secondary)
                        Button("Choose Files…") { files = pickFiles(accepts, multiple: multiple) }
                    }
                } else {
                    VStack(spacing: 0) {
                        List {
                            ForEach(files, id: \.self) { u in
                                HStack { Thumb(url: u, side: 24); Text(u.lastPathComponent).lineLimit(1); Spacer()
                                    Text(Fmt.size(FileItem(url: u)?.size ?? 0)).foregroundStyle(.secondary).font(.caption)
                                    Button { files.removeAll { $0 == u } } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless).foregroundStyle(.secondary) }
                            }
                            .onMove { files.move(fromOffsets: $0, toOffset: $1) }
                        }
                        HStack { Button("Add…") { files += pickFiles(accepts, multiple: multiple) }; Button("Clear") { files = []; outputs = [] }; Spacer(); Text("\(files.count) file\(files.count == 1 ? "" : "s")").foregroundStyle(.secondary) }.padding(8)
                    }
                }
            }
            .frame(minHeight: 160, maxHeight: 300)
            .animation(.easeOut(duration: 0.2), value: targeted)
            .dropDestination(for: URL.self) { urls, _ in
                let ok = urls.flatMap(expand).filter { accepts.isEmpty || accepts.contains($0.pathExtension.lowercased()) }
                files = multiple ? Array((files + ok).prefix(2000)) : Array(ok.prefix(1)); outputs = []; return !ok.isEmpty
            } isTargeted: { targeted = $0 }

            options
            HStack {
                if running { ProgressView(value: progress).frame(width: 200) }
                if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).lineLimit(2) }
                Spacer()
                if !outputs.isEmpty {
                    Label("\(outputs.count) file\(outputs.count == 1 ? "" : "s") saved", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Button("Show") { FileOps.reveal(outputs) }
                }
                Button(actionTitle) { go() }.buttonStyle(.borderedProminent).controlSize(.large).disabled(files.isEmpty || running)
            }
        }
        .padding(20)
        .onAppear { let f = ToolInbox.shared.take().flatMap(expand).filter { accepts.isEmpty || accepts.contains($0.pathExtension.lowercased()) }; if !f.isEmpty { files = f } }
    }

    private func expand(_ u: URL) -> [URL] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue, !accepts.contains(u.pathExtension.lowercased()), accepts.count > 0 else { return [u] }
        let e = FileManager.default.enumerator(at: u, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        return (e?.allObjects as? [URL] ?? []).filter { accepts.contains($0.pathExtension.lowercased()) }
    }

    private func go() {
        running = true; error = nil; outputs = []; progress = 0
        let out = FileOps.outputFolder(title)
        let input = files
        Task {
            do {
                let r = try await run(input, out) { p in Task { @MainActor in progress = p } }
                outputs = r
                if !r.isEmpty { FileOps.created(r, title: "\(title): \(r.count) file\(r.count == 1 ? "" : "s")") }
            } catch let e { self.error = e.localizedDescription }
            running = false
        }
    }
}

struct ToolError: LocalizedError { let message: String; init(_ m: String) { message = m }; var errorDescription: String? { message } }

/// Two-pane text tool: input on the left, output on the right.
struct TextPane: View {
    let title: String
    @Binding var text: String
    var editable = true
    var mono = true
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if editable { Button("Paste") { text = NSPasteboard.general.string(forType: .string) ?? text }.buttonStyle(.borderless).controlSize(.small) }
                Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string); ActivityLog.shared.show("Copied") }.buttonStyle(.borderless).controlSize(.small)
            }
            TextEditor(text: editable ? $text : .constant(text))
                .font(mono ? .system(.body, design: .monospaced) : .body)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
        }
    }
}

struct CopyRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
            Text(value).font(.system(.body, design: .monospaced)).textSelection(.enabled).lineLimit(3)
            Spacer()
            Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string); ActivityLog.shared.show("Copied \(label)") } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless)
        }
    }
}
