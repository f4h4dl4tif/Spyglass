import AppIntents
import Foundation
import UniformTypeIdentifiers

// Shortcuts and Siri actions. Each one runs inside Spyglass on this Mac.

enum ImageFormatOption: String, AppEnum {
    case jpeg, png, heic, tiff
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Image Format" }
    static var caseDisplayRepresentations: [ImageFormatOption: DisplayRepresentation] { [.jpeg: "JPEG", .png: "PNG", .heic: "HEIC", .tiff: "TIFF"] }
}

struct FindFilesIntent: AppIntent {
    static var title: LocalizedStringResource { "Find Files" }
    static var description: IntentDescription { IntentDescription("Finds files with a plain-English search, like “pdfs from last week over 5 MB”.") }
    @Parameter(title: "Search") var query: String
    @Parameter(title: "Limit", default: 50) var limit: Int
    static var parameterSummary: some ParameterSummary { Summary("Find files matching \(\.$query)") { \.$limit } }

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let p = ParsedSearch.parse(query)
        guard let q = p.query(excluding: [], meaning: true, contents: true) else { return .result(value: []) }
        let hits = await Spotlight.run(q, scopes: [p.scope?.path ?? NSMetadataQueryUserHomeScope], limit: max(1, limit)).hits
        return .result(value: hits.map { IntentFile(fileURL: $0.url) })
    }
}

struct ShowSearchResultsIntent: AppIntent {
    static var title: LocalizedStringResource { "Show Search Results" }
    static var description: IntentDescription { IntentDescription("Opens Spyglass with the results of a search.") }
    static var openAppWhenRun: Bool { true }
    @Parameter(title: "Search") var query: String
    @MainActor func perform() async throws -> some IntentResult {
        AppModel.shared.searchText = query
        AppModel.shared.show(.search(query))
        return .result()
    }
}

struct GetLatestDownloadIntent: AppIntent {
    static var title: LocalizedStringResource { "Get Latest Download" }
    static var description: IntentDescription { IntentDescription("Returns the newest file in your Downloads folder.") }
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<IntentFile?> {
        let h = await Spotlight.run("kMDItemPath == \"\(Places.downloads.path)/*\"", scopes: [Places.downloads.path], sort: "kMDItemDateAdded", limit: 1).hits.first
        return .result(value: h.map { IntentFile(fileURL: $0.url) })
    }
}

struct ScanForSpaceIntent: AppIntent {
    static var title: LocalizedStringResource { "Scan for Space to Free" }
    static var description: IntentDescription { IntentDescription("Looks for files you can safely remove and says how much space they take.") }
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        await CleanupScanner.shared.scan()
        let s = CleanupScanner.shared
        let lines = s.groups.filter { !$0.items.isEmpty }.map { "\($0.title): \(Fmt.size($0.bytes))" }
        let text = "\(Fmt.size(s.total)) ready to reclaim." + (lines.isEmpty ? "" : "\n" + lines.joined(separator: "\n"))
        return .result(value: text, dialog: "\(Fmt.size(s.total)) ready to reclaim.")
    }
}

struct CleanSafeItemsIntent: AppIntent {
    static var title: LocalizedStringResource { "Clean Safe Items" }
    static var description: IntentDescription { IntentDescription("Moves only items marked Safe (app caches and rebuildable developer data) to the Trash.") }
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        await CleanupScanner.shared.scan()
        let before = CleanupScanner.shared.total
        CleanupScanner.shared.cleanSafe()
        let freed = Fmt.size(max(0, before - CleanupScanner.shared.total))
        return .result(value: freed, dialog: "Freed \(freed). It's in the Trash if you need it back.")
    }
}

struct PutBackLastCleanupIntent: AppIntent {
    static var title: LocalizedStringResource { "Put Back Last Cleanup" }
    static var description: IntentDescription { IntentDescription("Restores the most recent cleanup, uninstall or move to Trash.") }
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let e = ActivityLog.shared.entries.first(where: { !$0.undone && [.cleanup, .trash, .uninstall].contains($0.kind) }) else { return .result(dialog: "There's nothing to put back.") }
        ActivityLog.shared.undo(e.id)
        return .result(dialog: "Put back “\(e.title)”.")
    }
}

struct GetMacHealthIntent: AppIntent {
    static var title: LocalizedStringResource { "Get Mac Health" }
    static var description: IntentDescription { IntentDescription("Returns your Mac's health score with the readings behind it.") }
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        _ = SystemStats.cpu(); try? await Task.sleep(for: .seconds(1))
        let r = SystemStats.read()
        let s = HealthScore(r)
        var text = "Health score \(s.score) — \(s.word)\nProcessor \(Int(r.cpu * 100))% · Memory \(Fmt.size(r.memUsed)) of \(Fmt.size(r.memTotal)) · \(Fmt.size(r.diskFree)) free"
        if let b = r.battery { text += " · Battery \(b)%" }
        for p in s.points { text += "\n• \(p.title) (\(p.detail))" }
        return .result(value: text, dialog: "Your Mac's health score is \(s.score), \(s.word).")
    }
}

struct OrganizeFolderIntent: AppIntent {
    static var title: LocalizedStringResource { "Organize Folder" }
    static var description: IntentDescription { IntentDescription("Sorts loose files in a folder into subfolders by kind or month. Can be undone in Activity.") }
    @Parameter(title: "Folder") var folder: IntentFile
    @Parameter(title: "By Month", default: false) var byMonth: Bool
    static var parameterSummary: some ParameterSummary { Summary("Organize \(\.$folder)") { \.$byMonth } }
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        guard let u = folder.fileURL else { throw ToolError("Choose a folder") }
        let plan = Organizer.plan(u, byMonth: byMonth)
        if !plan.isEmpty { Organizer.apply(plan, title: "Organized \(u.lastPathComponent) (\(plan.count) files)") }
        return .result(value: plan.count, dialog: plan.isEmpty ? "Nothing to organize." : "Organized \(plan.count) files.")
    }
}

struct ExtractTextIntent: AppIntent {
    static var title: LocalizedStringResource { "Extract Text from File" }
    static var description: IntentDescription { IntentDescription("Reads the text in an image, screenshot, PDF or document on this Mac.") }
    @Parameter(title: "File") var file: IntentFile
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let u = file.fileURL else { throw ToolError("Choose a file") }
        return .result(value: AI.text(of: u))
    }
}

struct SummarizeDocumentIntent: AppIntent {
    static var title: LocalizedStringResource { "Summarize Document" }
    static var description: IntentDescription { IntentDescription("Summarizes a PDF, document or image with Apple Intelligence on this Mac (or the offline method).") }
    @Parameter(title: "Document") var file: IntentFile
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let u = file.fileURL else { throw ToolError("Choose a file") }
        return .result(value: await AI.summarize(AI.text(of: u)).0)
    }
}

struct AskDocumentIntent: AppIntent {
    static var title: LocalizedStringResource { "Ask About Document" }
    static var description: IntentDescription { IntentDescription("Answers a question using only the text of a document.") }
    @Parameter(title: "Document") var file: IntentFile
    @Parameter(title: "Question") var question: String
    static var parameterSummary: some ParameterSummary { Summary("Ask \(\.$question) about \(\.$file)") }
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let u = file.fileURL else { throw ToolError("Choose a file") }
        return .result(value: await AI.ask(question, about: AI.text(of: u)).0)
    }
}

struct SmartRenameIntent: AppIntent {
    static var title: LocalizedStringResource { "Smart Rename Files" }
    static var description: IntentDescription { IntentDescription("Renames files like IMG_1234 from what's in them. Can be undone in Activity.") }
    @Parameter(title: "Files") var files: [IntentFile]
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        var out: [IntentFile] = [], moves: [Move] = []
        for f in files {
            guard let u = f.fileURL else { continue }
            let n = await SmartNamer.suggest(u)
            let d = FileOps.uniqueURL(u.deletingLastPathComponent().appendingPathComponent(n))
            if n != u.lastPathComponent, (try? FileManager.default.moveItem(at: u, to: d)) != nil { moves.append(Move(from: u.path, to: d.path)); out.append(IntentFile(fileURL: d)) }
            else { out.append(f) }
        }
        ActivityLog.shared.record(.rename, "Smart-renamed \(moves.count) files", moves: moves, toast: false)
        return .result(value: out)
    }
}

struct ConvertImagesIntent: AppIntent {
    static var title: LocalizedStringResource { "Convert Images" }
    static var description: IntentDescription { IntentDescription("Converts images to another format. Copies go to Downloads › Spyglass.") }
    @Parameter(title: "Images") var files: [IntentFile]
    @Parameter(title: "Format", default: .jpeg) var format: ImageFormatOption
    static var parameterSummary: some ParameterSummary { Summary("Convert \(\.$files) to \(\.$format)") }
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let out = FileOps.outputFolder("Convert Image")
        let ext = format == .jpeg ? "jpg" : format.rawValue
        let type = UTType(filenameExtension: ext) ?? .jpeg
        var made: [URL] = []
        for f in files {
            guard let u = f.fileURL, let cg = try? ImageTools.cgImage(u) else { continue }
            if let o = try? ImageTools.write(cg, to: out.appendingPathComponent(u.deletingPathExtension().lastPathComponent + "." + ext), type: type) { made.append(o) }
        }
        FileOps.created(made, title: "Converted \(made.count) images")
        return .result(value: made.map { IntentFile(fileURL: $0) })
    }
}

struct RunRoutineIntent: AppIntent {
    static var title: LocalizedStringResource { "Run Routine" }
    static var description: IntentDescription { IntentDescription("Runs one of your Spyglass routines now.") }
    @Parameter(title: "Routine Name") var name: String
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let r = await RoutineEngine.shared.run(named: name)
        return .result(value: r, dialog: "\(r)")
    }
}

struct OpenToolIntent: AppIntent {
    static var title: LocalizedStringResource { "Open Tool" }
    static var description: IntentDescription { IntentDescription("Opens a Spyglass tool by name, like “Merge PDFs” or “JSON Formatter”.") }
    static var openAppWhenRun: Bool { true }
    @Parameter(title: "Tool Name") var name: String
    @MainActor func perform() async throws -> some IntentResult {
        if let t = ToolCatalog.all.first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) ?? ToolCatalog.all.first(where: { $0.name.localizedCaseInsensitiveContains(name) }) {
            AppModel.shared.show(.tool(t.id))
        } else { AppModel.shared.show(.tools(nil)) }
        return .result()
    }
}

struct SpyglassShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: GetMacHealthIntent(), phrases: ["Check my Mac's health with \(.applicationName)", "\(.applicationName) Mac health"], shortTitle: "Mac Health", systemImageName: "heart.text.square")
        AppShortcut(intent: ScanForSpaceIntent(), phrases: ["How much space can \(.applicationName) free", "Scan for space with \(.applicationName)"], shortTitle: "Scan for Space", systemImageName: "internaldrive")
        AppShortcut(intent: CleanSafeItemsIntent(), phrases: ["Clean safe items with \(.applicationName)", "\(.applicationName) clean up"], shortTitle: "Clean Safe Items", systemImageName: "sparkles")
        AppShortcut(intent: PutBackLastCleanupIntent(), phrases: ["Put back the last cleanup in \(.applicationName)", "Undo \(.applicationName) cleanup"], shortTitle: "Put Back Cleanup", systemImageName: "arrow.uturn.backward")
        AppShortcut(intent: GetLatestDownloadIntent(), phrases: ["Get my latest download with \(.applicationName)", "\(.applicationName) latest download"], shortTitle: "Latest Download", systemImageName: "arrow.down.circle")
        AppShortcut(intent: ShowSearchResultsIntent(), phrases: ["Search files with \(.applicationName)", "Find files in \(.applicationName)"], shortTitle: "Search Files", systemImageName: "magnifyingglass")
        AppShortcut(intent: SummarizeDocumentIntent(), phrases: ["Summarize a document with \(.applicationName)"], shortTitle: "Summarize", systemImageName: "text.append")
        AppShortcut(intent: OpenToolIntent(), phrases: ["Open a tool in \(.applicationName)"], shortTitle: "Open Tool", systemImageName: "wrench.and.screwdriver")
    }
}
