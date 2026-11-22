import Foundation
import NaturalLanguage
import PDFKit
import AppKit
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple's on-device model (macOS 26+, Apple Intelligence on). Everything has an offline fallback.
enum AI {
    static var available: Bool {
        guard UserDefaults.standard.object(forKey: "useAppleIntelligence") as? Bool ?? true else { return false }
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    static var statusText: String {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return "Apple Intelligence is on — answers come from the on-device model."
            case .unavailable(let r):
                switch r {
                case .deviceNotEligible: return "This Mac can't run Apple Intelligence. Spyglass uses its built-in offline method instead."
                case .appleIntelligenceNotEnabled: return "Turn on Apple Intelligence in System Settings for better answers. Using the offline method for now."
                case .modelNotReady: return "Apple Intelligence is still downloading. Using the offline method for now."
                @unknown default: return "Apple Intelligence isn't available. Using the offline method."
                }
            }
        }
        #endif
        return "Apple Intelligence needs macOS 26. Spyglass uses its built-in offline method."
    }

    static func respond(instructions: String, prompt: String) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26, *), available {
            let session = LanguageModelSession(instructions: instructions)
            return try await session.respond(to: prompt).content
        }
        #endif
        throw ToolError("Apple Intelligence isn't available")
    }

    // MARK: Documents

    /// Reads text from PDFs, Word/RTF/HTML/Pages-exported docs, plain text and images (OCR).
    static func text(of url: URL, limit: Int = 200_000) -> String {
        let ext = url.pathExtension.lowercased()
        var s = ""
        if ext == "pdf" { s = OCR.text(of: url) }
        else if Ext.image.contains(ext) { s = OCR.text(of: url) }
        else if ["docx", "doc", "rtf", "rtfd", "html", "htm", "odt", "webarchive"].contains(ext),
                let a = try? NSAttributedString(url: url, options: [:], documentAttributes: nil) { s = a.string }
        else if let t = try? String(contentsOf: url, encoding: .utf8) { s = t }
        else if let t = try? String(contentsOf: url, encoding: .isoLatin1) { s = t }
        return String(s.prefix(limit))
    }

    static func chunks(_ text: String, size: Int = 7000) -> [String] {
        var out: [String] = [], cur = ""
        text.enumerateSubstrings(in: text.startIndex..., options: .byParagraphs) { p, _, _, _ in
            guard let p, !p.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            if cur.count + p.count > size, !cur.isEmpty { out.append(cur); cur = "" }
            cur += (cur.isEmpty ? "" : "\n") + String(p.prefix(size))
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    static func summarize(_ text: String, style: String = "a short paragraph followed by 3–6 bullet points") async -> (String, Bool) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return ("There's no readable text in this file.", false) }
        if available {
            do {
                var parts = chunks(clean)
                if parts.count > 6 { parts = Array(parts.prefix(6)) }
                var notes: [String] = []
                for p in parts {
                    notes.append(try await respond(instructions: "You summarize documents accurately and concisely. Never invent facts.", prompt: "Summarize this part of a document in 3 bullet points:\n\n\(p)"))
                }
                if notes.count == 1 && style.contains("bullet") { return (notes[0], true) }
                let r = try await respond(instructions: "You summarize documents accurately and concisely. Never invent facts.",
                                          prompt: "Combine these notes into \(style):\n\n" + notes.joined(separator: "\n\n"))
                return (r, true)
            } catch {}
        }
        return (extractive(clean, sentences: 6), false)
    }

    static func ask(_ question: String, about text: String) async -> (String, Bool) {
        let best = relevant(text, to: question, budget: 7000)
        if available {
            if let r = try? await respond(instructions: "Answer questions using only the document excerpt given. If the answer isn't there, say you can't find it. Be brief and quote numbers exactly.",
                                          prompt: "Document excerpt:\n\(best)\n\nQuestion: \(question)") { return (r, true) }
        }
        let sents = sentences(best)
        let terms = keywords(question)
        let ranked = sents.map { s in (s, terms.reduce(0) { $0 + (s.lowercased().contains($1) ? 1 : 0) }) }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }
        return (ranked.isEmpty ? "I couldn't find that in the document." : "Most relevant passages:\n\n" + ranked.prefix(3).map { "• " + $0.0 }.joined(separator: "\n"), false)
    }

    /// Picks the chunks that share the most words with the question.
    static func relevant(_ text: String, to q: String, budget: Int) -> String {
        let parts = chunks(text, size: 1500)
        guard parts.count > 1 else { return String(text.prefix(budget)) }
        let terms = keywords(q)
        let scored = parts.enumerated().map { i, p in (i, p, terms.reduce(0) { $0 + p.lowercased().components(separatedBy: $1).count - 1 }) }
        var picked: [(Int, String)] = [], used = 0
        for s in scored.sorted(by: { $0.2 > $1.2 }) where used + s.1.count <= budget { picked.append((s.0, s.1)); used += s.1.count }
        return picked.sorted { $0.0 < $1.0 }.map(\.1).joined(separator: "\n…\n")
    }

    static func keywords(_ s: String) -> [String] {
        let stop: Set<String> = ["what", "when", "where", "which", "who", "how", "the", "is", "are", "was", "does", "do", "a", "an", "of", "in", "to", "for", "and", "this", "that", "it", "on", "my", "me", "about", "with"]
        return s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 2 && !stop.contains($0) }
    }

    static func sentences(_ text: String) -> [String] {
        let t = NLTokenizer(unit: .sentence); t.string = text
        return t.tokens(for: text.startIndex..<text.endIndex).map { text[$0].trimmingCharacters(in: .whitespacesAndNewlines) }.filter { $0.count > 20 }
    }

    /// Offline summary: highest-scoring sentences by word frequency, in original order.
    static func extractive(_ text: String, sentences n: Int) -> String {
        let sents = sentences(String(text.prefix(60000)))
        guard sents.count > n else { return sents.map { "• " + $0 }.joined(separator: "\n") }
        var freq: [String: Int] = [:]
        for w in keywords(text) { freq[w, default: 0] += 1 }
        let scored = sents.enumerated().map { i, s -> (Int, String, Double) in
            let ws = keywords(s); return (i, s, ws.isEmpty ? 0 : Double(ws.reduce(0) { $0 + (freq[$1] ?? 0) }) / Double(ws.count).squareRoot())
        }
        return scored.sorted { $0.2 > $1.2 }.prefix(n).sorted { $0.0 < $1.0 }.map { "• " + $0.1 }.joined(separator: "\n")
    }

    /// A short, filesystem-safe title for a document or image description.
    static func title(for text: String) async -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if available, let r = try? await respond(instructions: "You name files. Reply with only a 2–6 word Title Case name, no punctuation, no file extension, no quotes.",
                                                 prompt: "Suggest a file name for this content:\n\n\(t.prefix(3000))") {
            return sanitize(r)
        }
        // Offline: first meaningful line.
        let line = t.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.first { $0.count >= 4 && $0.rangeOfCharacter(from: .letters) != nil } ?? ""
        return line.isEmpty ? nil : sanitize(String(line.prefix(60)))
    }

    static func sanitize(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\?%*|\"<>\n\r\t.")
        let parts = s.components(separatedBy: bad).joined(separator: " ").split(separator: " ")
        return parts.prefix(8).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }
}
