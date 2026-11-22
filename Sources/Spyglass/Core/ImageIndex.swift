import Foundation
import Vision
import AppKit
import SwiftUI

/// Background index of the text inside screenshots and images, so they're searchable.
/// Runs at low priority, pauses in Low Power Mode and on battery under 30%, and stores only the text.
@MainActor final class ImageTextIndex: ObservableObject {
    static let shared = ImageTextIndex()
    struct Entry: Codable { var m: Double; var t: String }   // modification time, text

    @Published private(set) var count = 0
    @Published private(set) var indexing = false
    @Published private(set) var pending = 0
    private var entries: [String: Entry] = [:]
    private var task: Task<Void, Never>?
    private var file: URL { Places.support.appendingPathComponent("imagetext.json") }
    private var timer: Timer?

    var enabled: Bool { UserDefaults.standard.object(forKey: "indexImageText") as? Bool ?? true }

    func start() {
        if let d = try? Data(contentsOf: file), let e = try? JSONDecoder().decode([String: Entry].self, from: d) { entries = e; count = e.count }
        guard enabled else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { self.run() }
        timer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { _ in MainActor.assumeIsolated { self.run() } }
        timer?.tolerance = 300
    }

    func stop() { task?.cancel(); task = nil; indexing = false; timer?.invalidate(); timer = nil }

    func run() {
        guard enabled, task == nil else { return }
        task = Task {
            indexing = true
            let hits = await Spotlight.run("(kMDItemIsScreenCapture == 1 || kMDItemContentTypeTree == \"public.image\") && kMDItemFSSize > 20000 && kMDItemFSSize < 40000000",
                                           scopes: [Places.desktop.path, Places.documents.path, Places.downloads.path, Places.pictures.path], limit: 6000).hits
            let known = entries
            let todo = hits.filter { h in
                guard !h.url.path.contains(".photoslibrary") else { return false }
                return known[h.url.path].map { $0.m < h.date.timeIntervalSince1970 - 1 } ?? true
            }
            pending = todo.count
            var batch: [String: Entry] = [:]
            for (i, h) in todo.enumerated() {
                if Task.isCancelled { break }
                while Self.shouldPause() && !Task.isCancelled { try? await Task.sleep(for: .seconds(60)) }
                let text = await Task.detached(priority: .background) { Self.recognize(h.url) }.value
                batch[h.url.path] = Entry(m: h.date.timeIntervalSince1970, t: text)
                if i % 25 == 24 || i == todo.count - 1 { merge(batch); batch = [:]; pending = todo.count - i - 1 }
                try? await Task.sleep(for: .milliseconds(120))   // stay gentle on the CPU
            }
            // forget files that no longer exist
            let live = Set(hits.map(\.url.path))
            entries = entries.filter { live.contains($0.key) || FileManager.default.fileExists(atPath: $0.key) }
            count = entries.count
            save()
            indexing = false; pending = 0
            task = nil
        }
    }

    private func merge(_ b: [String: Entry]) { entries.merge(b) { $1 }; count = entries.count; save() }

    private func save() {
        let snap = entries, url = file
        DispatchQueue.global(qos: .background).async { try? JSONEncoder().encode(snap).write(to: url, options: .atomic) }
    }

    nonisolated static func shouldPause() -> Bool {
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return true }
        let b = SystemStats.battery()
        if let p = b.percent, !b.charging, p < 30 { return true }
        return ProcessInfo.processInfo.thermalState.rawValue >= 2
    }

    nonisolated static func recognize(_ u: URL) -> String {
        autoreleasepool {
            guard let img = try? ImageTools.cgImage(u, maxPixel: 2000) else { return "" }
            let req = VNRecognizeTextRequest()
            req.recognitionLevel = .accurate
            req.usesLanguageCorrection = true
            try? VNImageRequestHandler(cgImage: img).perform([req])
            return (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        }
    }

    /// Files whose image text contains every word.
    func search(_ words: [String], limit: Int = 200) -> [Spotlight.Hit] {
        let ws = words.map { $0.lowercased() }.filter { !$0.isEmpty }
        guard !ws.isEmpty else { return [] }
        var out: [Spotlight.Hit] = []
        for (path, e) in entries {
            let t = e.t.lowercased()
            if ws.allSatisfy({ t.contains($0) }) {
                let u = URL(fileURLWithPath: path)
                out.append(Spotlight.Hit(url: u, name: u.lastPathComponent, size: FileItem(url: u)?.size ?? 0, date: Date(timeIntervalSince1970: e.m)))
                if out.count >= limit { break }
            }
        }
        return out.sorted { $0.date > $1.date }
    }

    func text(for u: URL) -> String? { entries[u.path]?.t }

    func reset() { stop(); entries = [:]; count = 0; save(); if enabled { start(); run() } }
}

struct ImageTextView: View {
    @ObservedObject var idx = ImageTextIndex.shared
    @State private var q = ""
    @State private var hits: [Spotlight.Hit] = []
    @AppStorage("indexImageText") private var on = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Text in Images", subtitle: idx.indexing ? "Reading \(Fmt.count(idx.pending)) images in the background… \(Fmt.count(idx.count)) done" : "\(Fmt.count(idx.count)) screenshots and images read on this Mac", symbol: "text.viewfinder", tint: .teal) {
                HStack {
                    Toggle("Index", isOn: $on).toggleStyle(.switch).onChange(of: on) { _, v in if v { idx.start(); idx.run() } else { idx.stop() } }
                    Button { idx.run() } label: { Image(systemName: "arrow.clockwise") }.disabled(idx.indexing || !on).help("Look for new images now")
                }
            }.padding(20)
            TextField("Search words inside screenshots and photos", text: $q).textFieldStyle(.roundedBorder).controlSize(.large).padding(.horizontal, 20).padding(.bottom, 12)
            Divider()
            if q.isEmpty { EmptyState(symbol: "text.viewfinder", title: "Search what's written in your images", message: "Spyglass reads screenshots and photos in Desktop, Documents, Downloads and Pictures. It pauses in Low Power Mode or when the battery is low. Results also show up in normal search.") }
            else if hits.isEmpty { EmptyState(symbol: "magnifyingglass", title: "No images contain that") }
            else { HitList(hits: hits) }
        }
        .onChange(of: q) { _, v in hits = idx.search(v.split(separator: " ").map(String.init)) }
    }
}
