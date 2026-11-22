import SwiftUI
import PDFKit
import Vision
import AVFoundation
import Speech
import ScreenCaptureKit
import ImageIO

// MARK: - Summarize / Ask about a document

struct DocumentAITool: View {
    let ask: Bool
    @State private var file: URL?
    @State private var text = ""
    @State private var output = ""
    @State private var usedAI = false
    @State private var working = false
    @State private var question = ""
    @State private var chat: [(q: String, a: String)] = []
    @State private var style = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button(file?.lastPathComponent ?? "Choose Document…") { if let f = pickFiles(Ext.pdf + Ext.docs + Ext.image, multiple: false).first { load(f) } }
                Button("Paste Text") { text = NSPasteboard.general.string(forType: .string) ?? ""; file = nil; output = ""; chat = []; if !ask { Task { await run() } } }
                if working { ProgressView().controlSize(.small) }
                Spacer()
                if !text.isEmpty { Text("\(Fmt.count(text.split(separator: " ").count)) words read").font(.caption).foregroundStyle(.secondary) }
            }
            Label(AI.statusText, systemImage: AI.available ? "sparkles" : "cpu").font(.caption).foregroundStyle(.secondary)
            if ask {
                List(Array(chat.enumerated()), id: \.offset) { _, c in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(c.q).font(.headline)
                        Text(c.a).textSelection(.enabled)
                    }.padding(.vertical, 4)
                }
                .overlay { if chat.isEmpty { EmptyState(symbol: "questionmark.bubble", title: text.isEmpty ? "Drop a document" : "Ask anything about it", message: "For example: “What's the total?”, “When is it due?”, “Who signed it?”") } }
                HStack {
                    TextField("Ask a question", text: $question).textFieldStyle(.roundedBorder).onSubmit { Task { await askNow() } }
                    Button("Ask") { Task { await askNow() } }.buttonStyle(.borderedProminent).disabled(text.isEmpty || question.isEmpty || working)
                }
            } else {
                Picker("Style", selection: $style) { Text("Key points").tag(0); Text("One paragraph").tag(1); Text("One sentence").tag(2) }.pickerStyle(.segmented).frame(width: 360)
                    .onChange(of: style) { _, _ in Task { await run() } }
                TextPane(title: usedAI || output.isEmpty ? "Summary" : "Summary (offline: most important sentences)", text: .constant(output), editable: false, mono: false)
            }
        }
        .padding(20)
        .dropDestination(for: URL.self) { u, _ in if let f = u.first { load(f) }; return true }
        .onAppear { if let f = ToolInbox.shared.take().first { load(f) } }
    }

    func load(_ u: URL) {
        file = u; output = ""; chat = []; working = true
        Task {
            text = await Task.detached { AI.text(of: u) }.value
            working = false
            if !ask { await run() }
        }
    }
    func run() async {
        guard !text.isEmpty else { return }
        working = true
        let s = ["a short paragraph followed by 3–6 bullet points", "one clear paragraph", "a single sentence"][style]
        (output, usedAI) = await AI.summarize(text, style: s)
        working = false
    }
    func askNow() async {
        let q = question.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, !text.isEmpty else { return }
        question = ""; working = true
        let (a, _) = await AI.ask(q, about: text)
        chat.append((q, a)); working = false
    }
}

// MARK: - PDF page preview shared by Sign and Redact

struct PDFPagePicker: View {
    let doc: PDFDocument
    @Binding var page: Int
    var body: some View {
        HStack {
            Button { page = max(0, page - 1) } label: { Image(systemName: "chevron.left") }.disabled(page == 0)
            Text("Page \(page + 1) of \(doc.pageCount)").monospacedDigit()
            Button { page = min(doc.pageCount - 1, page + 1) } label: { Image(systemName: "chevron.right") }.disabled(page >= doc.pageCount - 1)
        }
    }
}

func pageImage(_ doc: PDFDocument, _ i: Int, width: CGFloat) -> NSImage? {
    guard let p = doc.page(at: i) else { return nil }
    let b = p.bounds(for: .mediaBox)
    return p.thumbnail(of: CGSize(width: width, height: width * b.height / b.width), for: .mediaBox)
}

/// Normalized rect (0–1, origin top-left) → PDF page coordinates.
func pageRect(_ n: CGRect, _ b: CGRect) -> CGRect {
    CGRect(x: b.minX + n.minX * b.width, y: b.minY + (1 - n.maxY) * b.height, width: n.width * b.width, height: n.height * b.height)
}

// MARK: - Sign PDF

struct SignPDFTool: View {
    @State private var file: URL?
    @State private var doc: PDFDocument?
    @State private var page = 0
    @State private var signature: NSImage?
    @State private var placed: [Int: [CGRect]] = [:]
    @State private var width = 0.28
    @State private var showPad = false
    @State private var saved: URL?

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 12) {
                Button(file?.lastPathComponent ?? "Choose PDF…") { if let f = pickFiles(Ext.pdf, multiple: false).first { open(f) } }
                Text("1. Make a signature").font(.headline)
                if let signature { Image(nsImage: signature).resizable().aspectRatio(contentMode: .fit).frame(height: 70).padding(6).background(.white, in: RoundedRectangle(cornerRadius: 8)) }
                Button(signature == nil ? "Create Signature…" : "Change Signature…") { showPad = true }
                Text("2. Click the page where it goes").font(.headline)
                HStack { Text("Size"); Slider(value: $width, in: 0.1...0.6) }
                Button("Remove Signatures on This Page") { placed[page] = [] }.disabled((placed[page] ?? []).isEmpty)
                Text("3. Save a signed copy").font(.headline)
                Button("Save Signed PDF") { save() }.buttonStyle(.borderedProminent).disabled(doc == nil || signature == nil || placed.values.allSatisfy(\.isEmpty))
                if let saved { Button("Show Signed PDF") { FileOps.reveal([saved]) } }
                Spacer()
            }.frame(width: 240)
            if let doc {
                VStack {
                    PDFPagePicker(doc: doc, page: $page)
                    if let img = pageImage(doc, page, width: 900) {
                        GeometryReader { g in
                            let fit = fitSize(img.size, in: g.size)
                            ZStack(alignment: .topLeading) {
                                Image(nsImage: img).resizable().frame(width: fit.width, height: fit.height).shadow(radius: 3)
                                ForEach(Array((placed[page] ?? []).enumerated()), id: \.offset) { _, r in
                                    if let signature { Image(nsImage: signature).resizable().frame(width: r.width * fit.width, height: r.height * fit.height).offset(x: r.minX * fit.width, y: r.minY * fit.height) }
                                }
                            }
                            .frame(width: fit.width, height: fit.height)
                            .contentShape(Rectangle())
                            .gesture(SpatialTapGesture().onEnded { v in
                                guard let sig = signature else { showPad = true; return }
                                let w = width, h = w * (sig.size.height / max(sig.size.width, 1)) * (fit.width / fit.height)
                                let r = CGRect(x: v.location.x / fit.width - w / 2, y: v.location.y / fit.height - h / 2, width: w, height: h)
                                placed[page, default: []].append(r)
                            })
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
            } else { EmptyState(symbol: "signature", title: "Drop a PDF to sign") }
        }
        .padding(20)
        .sheet(isPresented: $showPad) { SignaturePad { signature = $0 } }
        .dropDestination(for: URL.self) { u, _ in if let f = u.first(where: { $0.pathExtension.lowercased() == "pdf" }) { open(f) }; return true }
        .onAppear { if let f = ToolInbox.shared.take().first { open(f) } }
    }

    func open(_ u: URL) { file = u; doc = PDFDocument(url: u); page = 0; placed = [:]; saved = nil }

    func save() {
        guard let doc, let file, let sig = signature?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let out = FileOps.uniqueURL(FileOps.outputFolder("Sign PDF").appendingPathComponent(file.deletingPathExtension().lastPathComponent + " signed.pdf"))
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData), let ctx = CGContext(consumer: consumer, mediaBox: nil, nil) else { return }
        for i in 0..<doc.pageCount {
            guard let p = doc.page(at: i) else { continue }
            var box = p.bounds(for: .mediaBox)
            ctx.beginPage(mediaBox: &box)
            p.draw(with: .mediaBox, to: ctx)
            for r in placed[i] ?? [] { ctx.draw(sig, in: pageRect(r, box)) }
            ctx.endPage()
        }
        ctx.closePDF()
        do { try data.write(to: out); saved = out; FileOps.created([out], title: "Signed \(file.lastPathComponent)") } catch { ActivityLog.shared.show("Couldn't save the signed PDF") }
    }
}

func fitSize(_ s: CGSize, in box: CGSize) -> CGSize {
    let k = min(box.width / max(s.width, 1), box.height / max(s.height, 1))
    return CGSize(width: s.width * k, height: s.height * k)
}

struct SignaturePad: View {
    let done: (NSImage) -> Void
    @Environment(\.dismiss) var dismiss
    @State private var strokes: [[CGPoint]] = []
    @State private var current: [CGPoint] = []
    @State private var typed = ""
    @State private var mode = 0
    let size = CGSize(width: 520, height: 200)

    var body: some View {
        VStack(spacing: 12) {
            Picker("", selection: $mode) { Text("Draw").tag(0); Text("Type").tag(1) }.pickerStyle(.segmented).frame(width: 200)
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(.white)
                if mode == 0 {
                    Canvas { ctx, _ in
                        for s in strokes + [current] where s.count > 1 { var p = Path(); p.addLines(s); ctx.stroke(p, with: .color(.black), style: StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round)) }
                    }
                    .gesture(DragGesture(minimumDistance: 0).onChanged { current.append($0.location) }.onEnded { _ in strokes.append(current); current = [] })
                    if strokes.isEmpty && current.isEmpty { Text("Sign here with your trackpad or mouse").foregroundStyle(.gray) }
                } else {
                    TextField("Your name", text: $typed).textFieldStyle(.plain).font(.custom("Snell Roundhand", size: 54)).foregroundStyle(.black).multilineTextAlignment(.center).padding()
                }
                Rectangle().fill(.gray.opacity(0.4)).frame(height: 1).padding(.horizontal, 30).offset(y: 60)
            }.frame(width: size.width, height: size.height)
            HStack {
                Button("Clear") { strokes = []; current = []; typed = "" }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Use Signature") { if let i = render() { done(i) }; dismiss() }.keyboardShortcut(.defaultAction).disabled(mode == 0 ? strokes.isEmpty : typed.isEmpty)
            }
        }.padding(20)
    }

    func render() -> NSImage? {
        if mode == 1 {
            let attr: [NSAttributedString.Key: Any] = [.font: NSFont(name: "Snell Roundhand", size: 96) ?? NSFont.systemFont(ofSize: 80), .foregroundColor: NSColor.black]
            let s = NSAttributedString(string: typed, attributes: attr); let sz = s.size()
            return NSImage(size: NSSize(width: sz.width + 20, height: sz.height + 10), flipped: false) { _ in s.draw(at: NSPoint(x: 10, y: 5)); return true }
        }
        let pts = strokes.flatMap { $0 }
        guard let minX = pts.map(\.x).min(), let maxX = pts.map(\.x).max(), let minY = pts.map(\.y).min(), let maxY = pts.map(\.y).max() else { return nil }
        let pad: CGFloat = 8, scale: CGFloat = 3
        let w = (maxX - minX + 2 * pad) * scale, h = (maxY - minY + 2 * pad) * scale
        return NSImage(size: NSSize(width: w, height: h), flipped: true) { _ in
            NSColor.black.setStroke()
            for s in strokes where s.count > 1 {
                let p = NSBezierPath(); p.lineWidth = 2.6 * scale; p.lineCapStyle = .round; p.lineJoinStyle = .round
                p.move(to: NSPoint(x: (s[0].x - minX + pad) * scale, y: (s[0].y - minY + pad) * scale))
                for q in s.dropFirst() { p.line(to: NSPoint(x: (q.x - minX + pad) * scale, y: (q.y - minY + pad) * scale)) }
                p.stroke()
            }
            return true
        }
    }
}

// MARK: - Redact PDF

struct RedactPDFTool: View {
    @State private var file: URL?
    @State private var doc: PDFDocument?
    @State private var page = 0
    @State private var boxes: [Int: [CGRect]] = [:]
    @State private var dragStart: CGPoint?
    @State private var dragRect: CGRect?
    @State private var terms = ""
    @State private var emails = true
    @State private var phones = true
    @State private var saved: URL?

    var total: Int { boxes.values.reduce(0) { $0 + $1.count } }

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 12) {
                Button(file?.lastPathComponent ?? "Choose PDF…") { if let f = pickFiles(Ext.pdf, multiple: false).first { open(f) } }
                Text("Drag on the page to black out an area.").font(.callout).foregroundStyle(.secondary)
                Divider()
                Text("Find and redact").font(.headline)
                TextField("Words, comma separated", text: $terms).textFieldStyle(.roundedBorder)
                Toggle("Email addresses", isOn: $emails).toggleStyle(.checkbox)
                Toggle("Phone numbers", isOn: $phones).toggleStyle(.checkbox)
                Button("Find in All Pages") { find() }.disabled(doc == nil)
                Divider()
                Text("\(total) area\(total == 1 ? "" : "s") marked").foregroundStyle(.secondary)
                Button("Clear This Page") { boxes[page] = [] }
                Button("Save Redacted PDF") { save() }.buttonStyle(.borderedProminent).disabled(total == 0)
                Text("Redacted pages are turned into images, so the hidden text can't be copied or recovered.").font(.caption).foregroundStyle(.secondary)
                if let saved { Button("Show Redacted PDF") { FileOps.reveal([saved]) } }
                Spacer()
            }.frame(width: 250)
            if let doc {
                VStack {
                    PDFPagePicker(doc: doc, page: $page)
                    if let img = pageImage(doc, page, width: 900) {
                        GeometryReader { g in
                            let fit = fitSize(img.size, in: g.size)
                            ZStack(alignment: .topLeading) {
                                Image(nsImage: img).resizable().frame(width: fit.width, height: fit.height).shadow(radius: 3)
                                ForEach(Array(((boxes[page] ?? []) + (dragRect.map { [$0] } ?? [])).enumerated()), id: \.offset) { _, r in
                                    Rectangle().fill(.black.opacity(0.85)).frame(width: r.width * fit.width, height: r.height * fit.height).offset(x: r.minX * fit.width, y: r.minY * fit.height)
                                }
                            }
                            .frame(width: fit.width, height: fit.height)
                            .contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 3).onChanged { v in
                                let a = CGPoint(x: v.startLocation.x / fit.width, y: v.startLocation.y / fit.height), b = CGPoint(x: v.location.x / fit.width, y: v.location.y / fit.height)
                                dragRect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
                            }.onEnded { _ in if let r = dragRect { boxes[page, default: []].append(r) }; dragRect = nil })
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
            } else { EmptyState(symbol: "rectangle.fill.badge.minus", title: "Drop a PDF to redact") }
        }
        .padding(20)
        .dropDestination(for: URL.self) { u, _ in if let f = u.first(where: { $0.pathExtension.lowercased() == "pdf" }) { open(f) }; return true }
        .onAppear { if let f = ToolInbox.shared.take().first { open(f) } }
    }

    func open(_ u: URL) { file = u; doc = PDFDocument(url: u); page = 0; boxes = [:]; saved = nil }

    func find() {
        guard let doc else { return }
        var patterns = terms.split(separator: ",").map { NSRegularExpression.escapedPattern(for: $0.trimmingCharacters(in: .whitespaces)) }.filter { !$0.isEmpty }
        if emails { patterns.append("[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}") }
        if phones { patterns.append("\\+?\\d[\\d\\s().-]{7,}\\d") }
        guard !patterns.isEmpty, let re = try? NSRegularExpression(pattern: patterns.joined(separator: "|"), options: [.caseInsensitive]) else { return }
        var found = 0
        for i in 0..<doc.pageCount {
            guard let p = doc.page(at: i), let s = p.string else { continue }
            let b = p.bounds(for: .mediaBox)
            for m in re.matches(in: s, range: NSRange(location: 0, length: (s as NSString).length)) {
                guard let sel = p.selection(for: m.range) else { continue }
                for line in sel.selectionsByLine() {
                    let r = line.bounds(for: p).insetBy(dx: -1.5, dy: -1.5)
                    boxes[i, default: []].append(CGRect(x: (r.minX - b.minX) / b.width, y: 1 - (r.maxY - b.minY) / b.height, width: r.width / b.width, height: r.height / b.height))
                    found += 1
                }
            }
        }
        ActivityLog.shared.show(found == 0 ? "Nothing matched" : "Marked \(found) matches — check them, then save")
    }

    func save() {
        guard let doc, let file else { return }
        let out = PDFDocument()
        for i in 0..<doc.pageCount {
            guard let p = doc.page(at: i) else { continue }
            let rs = boxes[i] ?? []
            if rs.isEmpty { out.insert(p, at: out.pageCount); continue }
            let b = p.bounds(for: .mediaBox)
            let hi = p.thumbnail(of: CGSize(width: b.width * 2.5, height: b.height * 2.5), for: .mediaBox)
            let img = NSImage(size: b.size, flipped: false) { _ in
                hi.draw(in: NSRect(origin: .zero, size: b.size))
                NSColor.black.setFill()
                for r in rs { NSRect(x: r.minX * b.width, y: (1 - r.maxY) * b.height, width: r.width * b.width, height: r.height * b.height).fill() }
                return true
            }
            if let flat = flatten(img, pixels: CGSize(width: b.width * 2.5, height: b.height * 2.5)), let np = PDFPage(image: flat) { out.insert(np, at: out.pageCount) }
        }
        let dest = FileOps.uniqueURL(FileOps.outputFolder("Redact PDF").appendingPathComponent(file.deletingPathExtension().lastPathComponent + " redacted.pdf"))
        if out.write(to: dest) { saved = dest; FileOps.created([dest], title: "Redacted \(file.lastPathComponent)") }
    }

    /// Bakes an image into a single bitmap so nothing underneath survives.
    func flatten(_ img: NSImage, pixels: CGSize) -> NSImage? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(pixels.width), pixelsHigh: Int(pixels.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = img.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill(); NSRect(origin: .zero, size: img.size).fill()
        img.draw(in: NSRect(origin: .zero, size: img.size))
        NSGraphicsContext.restoreGraphicsState()
        let out = NSImage(size: img.size); out.addRepresentation(rep)
        return out
    }
}

// MARK: - Screen recording

@MainActor final class ScreenRecorder: NSObject, ObservableObject {
    static let shared = ScreenRecorder()
    @Published var recording = false
    @Published var started: Date?
    @Published var last: URL?
    @Published var error: String?
    private var stream: AnyObject?
    private var process: Process?

    func start(displayIndex: Int, cursor: Bool, systemAudio: Bool, mic: Bool, maxSeconds: Int) {
        error = nil
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let url = FileOps.outputFolder("Screen Recordings").appendingPathComponent("Screen Recording \(f.string(from: Date())).mov")
        if #available(macOS 15, *) {
            Task {
                do {
                    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                    guard content.displays.indices.contains(displayIndex) else { throw ToolError("Display not found") }
                    let d = content.displays[displayIndex]
                    let me = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
                    let filter = SCContentFilter(display: d, excludingApplications: me, exceptingWindows: [])
                    let cfg = SCStreamConfiguration()
                    let scale = Int(NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == d.displayID }?.backingScaleFactor ?? 2)
                    cfg.width = d.width * scale; cfg.height = d.height * scale
                    cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
                    cfg.showsCursor = cursor
                    cfg.capturesAudio = systemAudio
                    cfg.captureMicrophone = mic
                    let s = SCStream(filter: filter, configuration: cfg, delegate: nil)
                    let rc = SCRecordingOutputConfiguration()
                    rc.outputURL = url; rc.outputFileType = .mov
                    let out = SCRecordingOutput(configuration: rc, delegate: RecordingDelegate.shared)
                    try s.addRecordingOutput(out)
                    try await s.startCapture()
                    stream = s; last = url; recording = true; started = Date()
                    StatusItemController.shared.setRecording(true)
                } catch {
                    self.error = "Couldn't start recording. Allow Spyglass in System Settings › Privacy & Security › Screen & System Audio Recording, then try again. (\(error.localizedDescription))"
                }
            }
        } else {
            // macOS 14: the built-in screencapture tool, limited to a set length.
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-v", "-V\(maxSeconds)"] + (cursor ? ["-C"] : []) + (mic ? ["-g"] : []) + [url.path]
            p.terminationHandler = { _ in DispatchQueue.main.async { self.finish() } }
            do { try p.run(); process = p; last = url; recording = true; started = Date(); StatusItemController.shared.setRecording(true) }
            catch { self.error = error.localizedDescription }
        }
    }

    func stop() {
        if #available(macOS 15, *), let s = stream as? SCStream {
            Task { try? await s.stopCapture(); stream = nil; finish() }
        } else if let p = process { p.interrupt(); process = nil }
    }

    private func finish() {
        recording = false; started = nil
        StatusItemController.shared.setRecording(false)
        if let last { DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { if FileManager.default.fileExists(atPath: last.path) { FileOps.created([last], title: "Recorded the screen") } } }
    }
}

@available(macOS 15, *)
final class RecordingDelegate: NSObject, SCRecordingOutputDelegate {
    static let shared = RecordingDelegate()
    func recordingOutput(_ o: SCRecordingOutput, didFailWithError error: Error) {
        DispatchQueue.main.async { ScreenRecorder.shared.error = error.localizedDescription }
    }
}

struct ScreenRecordTool: View {
    @ObservedObject var r = ScreenRecorder.shared
    @State private var display = 0
    @State private var cursor = true
    @State private var audio = false
    @State private var mic = false
    @State private var maxSecs = 300
    @State private var tick = Date()
    let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: r.recording ? "record.circle.fill" : "record.circle").font(.system(size: 76)).foregroundStyle(r.recording ? .red : .secondary)
                .symbolEffect(.pulse, isActive: r.recording)
            Text(r.started.map { let s = Int(tick.timeIntervalSince($0)); return String(format: "%d:%02d", s / 60, s % 60) } ?? "Ready").font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
            if !r.recording {
                Form {
                    if NSScreen.screens.count > 1 { Picker("Display", selection: $display) { ForEach(NSScreen.screens.indices, id: \.self) { Text(NSScreen.screens[$0].localizedName).tag($0) } } }
                    Toggle("Show the pointer", isOn: $cursor)
                    if #available(macOS 15, *) { Toggle("Record sound from the Mac", isOn: $audio) } else {
                        Picker("Length (macOS 14)", selection: $maxSecs) { Text("1 min").tag(60); Text("5 min").tag(300); Text("15 min").tag(900); Text("1 hour").tag(3600) }
                    }
                    Toggle("Record the microphone", isOn: $mic)
                }.formStyle(.grouped).frame(width: 420, height: 200)
            }
            Button(r.recording ? "Stop Recording" : "Start Recording") { r.recording ? r.stop() : r.start(displayIndex: display, cursor: cursor, systemAudio: audio, mic: mic, maxSeconds: maxSecs) }
                .buttonStyle(.borderedProminent).controlSize(.large).tint(r.recording ? .red : .accentColor)
            if r.recording { Text("You can also stop from the red dot in the menu bar.").font(.caption).foregroundStyle(.secondary) }
            if let e = r.error { Text(e).foregroundStyle(.red).multilineTextAlignment(.center).frame(maxWidth: 480) }
            if let last = r.last, !r.recording, FileManager.default.fileExists(atPath: last.path) { Button("Show Recording") { FileOps.reveal([last]) } }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onReceive(timer) { tick = $0 }
    }
}

// MARK: - Transcribe

enum Transcriber {
    struct Cue { let start: Double; let end: Double; let text: String }

    static func authorize() async -> Bool {
        await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) } }
    }

    static func transcribe(_ url: URL, locale: Locale, progress: @escaping (Double) -> Void) async throws -> [Cue] {
        guard let rec = SFSpeechRecognizer(locale: locale), rec.isAvailable else { throw ToolError("Speech recognition isn't available for \(locale.identifier)") }
        let asset = AVURLAsset(url: url)
        let dur = try await asset.load(.duration).seconds
        guard dur > 0 else { throw ToolError("This file has no audio") }
        let piece = 55.0
        var cues: [Cue] = []
        var t = 0.0
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("spyglass-tr-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        while t < dur {
            let seg = tmp.appendingPathComponent("\(Int(t)).m4a")
            let range = CMTimeRange(start: CMTime(seconds: t, preferredTimescale: 600), duration: CMTime(seconds: min(piece, dur - t), preferredTimescale: 600))
            _ = try await MediaTools.export(asset, preset: AVAssetExportPresetAppleM4A, to: seg, type: .m4a, range: range) { _ in }
            let offset = t
            let segs = try await recognize(seg, rec)
            cues += group(segs.map { (offset + $0.0, offset + $0.0 + $0.1, $0.2) })
            t += piece
            progress(min(1, t / dur))
        }
        return cues
    }

    private static func recognize(_ u: URL, _ rec: SFSpeechRecognizer) async throws -> [(Double, Double, String)] {
        let req = SFSpeechURLRecognitionRequest(url: u)
        req.requiresOnDeviceRecognition = rec.supportsOnDeviceRecognition
        req.shouldReportPartialResults = false
        req.addsPunctuation = true
        return try await withCheckedThrowingContinuation { c in
            var done = false
            rec.recognitionTask(with: req) { result, error in
                guard !done else { return }
                if let result, result.isFinal {
                    done = true
                    c.resume(returning: result.bestTranscription.segments.map { ($0.timestamp, $0.duration, $0.substring) })
                } else if let error {
                    done = true
                    let ns = error as NSError
                    if ns.code == 1110 || ns.code == 203 { c.resume(returning: []) } else { c.resume(throwing: error) }   // no speech in this piece
                }
            }
        }
    }

    /// Groups words into subtitle lines of ~7 words / 3.5 s.
    static func group(_ words: [(Double, Double, String)]) -> [Cue] {
        var out: [Cue] = [], cur: [(Double, Double, String)] = []
        for w in words {
            cur.append(w)
            if cur.count >= 8 || w.1 - cur[0].0 > 3.5 || w.2.hasSuffix(".") || w.2.hasSuffix("?") {
                out.append(Cue(start: cur[0].0, end: w.1, text: cur.map(\.2).joined(separator: " "))); cur = []
            }
        }
        if let f = cur.first, let l = cur.last { out.append(Cue(start: f.0, end: l.1, text: cur.map(\.2).joined(separator: " "))) }
        return out
    }

    static func srt(_ cues: [Cue]) -> String {
        func ts(_ s: Double) -> String { let ms = Int((s * 1000).rounded()); return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000) }
        return cues.enumerated().map { "\($0.offset + 1)\n\(ts($0.element.start)) --> \(ts($0.element.end))\n\($0.element.text)\n" }.joined(separator: "\n")
    }
}

struct TranscribeTool: View {
    @State private var file: URL?
    @State private var text = ""
    @State private var progress = 0.0
    @State private var working = false
    @State private var error: String?
    @State private var locale = Locale.current.identifier
    @State private var outputs: [URL] = []

    var locales: [String] { SFSpeechRecognizer.supportedLocales().map(\.identifier).sorted() }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button(file?.lastPathComponent ?? "Choose Audio or Video…") { if let f = pickFiles(Ext.media, multiple: false).first { file = f; text = ""; outputs = [] } }
                Picker("Language", selection: $locale) { ForEach(locales, id: \.self) { Text(Locale.current.localizedString(forIdentifier: $0) ?? $0).tag($0) } }.frame(width: 260)
                Spacer()
                Button("Transcribe") { Task { await run() } }.buttonStyle(.borderedProminent).disabled(file == nil || working)
            }
            if working { ProgressView(value: progress) { Text("Transcribing on this Mac…").font(.caption) } }
            if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
            TextPane(title: "Transcript", text: .constant(text), editable: false, mono: false)
            if !outputs.isEmpty { HStack { Label("Saved a .txt and an .srt subtitle file", systemImage: "checkmark.circle.fill").foregroundStyle(.green); Button("Show") { FileOps.reveal(outputs) } } }
        }
        .padding(20)
        .dropDestination(for: URL.self) { u, _ in if let f = u.first { file = f; text = ""; outputs = [] }; return true }
        .onAppear { if let f = ToolInbox.shared.take().first { file = f }; if !locales.contains(locale) { locale = locales.first { $0.hasPrefix("en") } ?? locales.first ?? "en-US" } }
    }

    func run() async {
        guard let file else { return }
        error = nil; working = true; progress = 0
        defer { working = false }
        guard await Transcriber.authorize() else { error = "Allow Speech Recognition for Spyglass in System Settings › Privacy & Security."; return }
        do {
            let cues = try await Transcriber.transcribe(file, locale: Locale(identifier: locale)) { p in Task { @MainActor in progress = p } }
            text = cues.map(\.text).joined(separator: " ")
            let base = FileOps.outputFolder("Transcripts").appendingPathComponent(file.deletingPathExtension().lastPathComponent)
            let txt = FileOps.uniqueURL(base.appendingPathExtension("txt")), srt = FileOps.uniqueURL(base.appendingPathExtension("srt"))
            try text.write(to: txt, atomically: true, encoding: .utf8)
            try Transcriber.srt(cues).write(to: srt, atomically: true, encoding: .utf8)
            outputs = [txt, srt]; FileOps.created(outputs, title: "Transcribed \(file.lastPathComponent)")
        } catch let e { error = e.localizedDescription }
    }
}

// MARK: - Smart Rename

enum SmartNamer {
    static let generic = try! NSRegularExpression(pattern: "^(img|dsc|dscn|dscf|pxl|mvimg|gopr|dji|photo|image|pic|scan|scanned|document|doc|untitled|file|download|screenshot|screen shot|cleanshot|whatsapp image|signal-|telegram|vid|video)?[ _-]*[\\d_ .-]*(copy)?\\d*$|^screenshot|^screen shot|^img_|^dsc|^scan", options: [.caseInsensitive])
    static func isGeneric(_ u: URL) -> Bool {
        let n = u.deletingPathExtension().lastPathComponent
        return generic.firstMatch(in: n, range: NSRange(location: 0, length: (n as NSString).length)) != nil
    }

    static func date(_ u: URL) -> Date {
        if let src = CGImageSourceCreateWithURL(u as CFURL, nil), let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any], let s = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            let f = DateFormatter(); f.dateFormat = "yyyy:MM:dd HH:mm:ss"
            if let d = f.date(from: s) { return d }
        }
        return (try? u.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
    }

    static func labels(_ u: URL) -> [String] {
        guard let cg = try? ImageTools.cgImage(u, maxPixel: 800) else { return [] }
        let req = VNClassifyImageRequest()
        try? VNImageRequestHandler(cgImage: cg).perform([req])
        return (req.results ?? []).filter { $0.confidence > 0.25 }.prefix(3).map { $0.identifier.replacingOccurrences(of: "_", with: " ").capitalized }
    }

    static func suggest(_ u: URL) async -> String {
        let ext = u.pathExtension
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let day = df.string(from: date(u))
        var title: String?
        if Ext.image.contains(ext.lowercased()) {
            let text = OCR.text(of: u)
            if text.count > 25 { title = await AI.title(for: text) }
            if title == nil {
                let l = labels(u)
                if AI.available, !l.isEmpty { title = await AI.title(for: "A photo showing: " + l.joined(separator: ", ")) }
                if title == nil, !l.isEmpty { title = l.prefix(2).joined(separator: " ") }
            }
        } else {
            if ext.lowercased() == "pdf", let t = PDFDocument(url: u)?.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, t.count > 3 { title = AI.sanitize(t) }
            if title == nil { title = await AI.title(for: AI.text(of: u, limit: 4000)) }
        }
        let name = [day, title].compactMap { $0 }.joined(separator: " ")
        return ext.isEmpty ? name : name + "." + ext
    }
}

struct SmartRenameTool: View {
    struct Row: Identifiable { let id = UUID(); let url: URL; var name: String; var on: Bool; var thinking: Bool }
    @State private var rows: [Row] = []
    @State private var onlyGeneric = true
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("Add Files…") { add(pickFiles(Ext.image + Ext.pdf + Ext.docs)) }
                Button("Add Folder…") { if let f = pickFolder() { add(((try? FileManager.default.contentsOfDirectory(at: f, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])) } }
                Toggle("Only generic names like IMG_1234, Scan, Screenshot", isOn: $onlyGeneric).toggleStyle(.checkbox)
                Spacer()
                if working { ProgressView().controlSize(.small) }
            }
            Label(AI.available ? "Names come from what's in each file, using Apple Intelligence on this Mac." : "Names come from text in the file, image recognition and the date taken.", systemImage: "sparkles").font(.caption).foregroundStyle(.secondary)
            List($rows) { $r in
                HStack(spacing: 10) {
                    Toggle("", isOn: $r.on).toggleStyle(.checkbox).labelsHidden()
                    Thumb(url: r.url, side: 32)
                    Text(r.url.lastPathComponent).foregroundStyle(.secondary).lineLimit(1).frame(width: 200, alignment: .leading)
                    Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                    if r.thinking { ProgressView().controlSize(.small) } else { TextField("New name", text: $r.name).textFieldStyle(.roundedBorder) }
                }
            }
            .overlay { if rows.isEmpty { EmptyState(symbol: "wand.and.rays", title: "Drop photos, scans or documents", message: "Spyglass reads each one and suggests a clear name like “2026-03-14 Beach Sunset.jpg”. Nothing changes until you press Rename.") } }
            HStack { Spacer(); Button("Rename \(rows.filter(\.on).count) Files") { apply() }.buttonStyle(.borderedProminent).disabled(rows.filter(\.on).isEmpty || working) }
        }
        .padding(20)
        .dropDestination(for: URL.self) { u, _ in add(u); return true }
        .onAppear { let f = ToolInbox.shared.take(); if !f.isEmpty { add(f) } }
    }

    func add(_ urls: [URL]) {
        let ok = urls.filter { u in (Ext.image + Ext.pdf + Ext.docs).contains(u.pathExtension.lowercased()) && (!onlyGeneric || SmartNamer.isGeneric(u)) && !rows.contains(where: { r in r.url == u }) }
        let start = rows.count
        rows += ok.prefix(300).map { Row(url: $0, name: $0.lastPathComponent, on: true, thinking: true) }
        working = true
        Task {
            for i in start..<rows.count {
                let u = rows[i].url
                let n = await SmartNamer.suggest(u)
                if i < rows.count { rows[i].name = n; rows[i].thinking = false }
            }
            working = false
        }
    }

    func apply() {
        var moves: [Move] = []
        for r in rows where r.on && r.name != r.url.lastPathComponent && !r.name.isEmpty && !r.name.contains("/") {
            let dest = FileOps.uniqueURL(r.url.deletingLastPathComponent().appendingPathComponent(r.name))
            if (try? FileManager.default.moveItem(at: r.url, to: dest)) != nil { moves.append(Move(from: r.url.path, to: dest.path)) }
        }
        ActivityLog.shared.record(.rename, "Smart-renamed \(moves.count) files", moves: moves)
        FileOps.changed()
        rows = []
    }
}
