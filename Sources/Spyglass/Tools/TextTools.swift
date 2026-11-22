import SwiftUI
import CryptoKit
import AVFoundation
import CoreImage.CIFilterBuiltins
#if canImport(Translation)
import Translation
#endif

private func split<L: View, R: View>(@ViewBuilder _ l: () -> L, @ViewBuilder _ r: () -> R) -> some View {
    HStack(spacing: 14) { l(); r() }.padding(20)
}

struct JSONTool: View {
    @State private var input = "{\"name\":\"Spyglass\",\"tools\":62,\"fast\":true}"
    @State private var indent = true
    @State private var sorted = true
    var output: (String, Bool) {
        guard let d = input.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed]) else {
            return ("Not valid JSON" + (validationError.map { ": \($0)" } ?? ""), false)
        }
        var o: JSONSerialization.WritingOptions = [.fragmentsAllowed, .withoutEscapingSlashes]
        if indent { o.insert(.prettyPrinted) }; if sorted { o.insert(.sortedKeys) }
        return ((try? JSONSerialization.data(withJSONObject: obj, options: o)).flatMap { String(data: $0, encoding: .utf8) } ?? "", true)
    }
    var validationError: String? {
        do { _ = try JSONSerialization.jsonObject(with: Data(input.utf8)); return nil } catch { return (error as NSError).userInfo["NSDebugDescription"] as? String }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Toggle("Pretty", isOn: $indent); Toggle("Sort keys", isOn: $sorted); Spacer()
                Label(output.1 ? "Valid" : "Invalid", systemImage: output.1 ? "checkmark.circle.fill" : "xmark.octagon.fill").foregroundStyle(output.1 ? .green : .red) }
                .toggleStyle(.checkbox).padding([.horizontal, .top], 20)
            split({ TextPane(title: "Input", text: $input) }, { TextPane(title: "Output", text: .constant(output.0), editable: false) })
        }
    }
}

struct Base64Tool: View {
    @State private var input = "Hello, Spyglass"
    @State private var decode = false
    @State private var urlSafe = false
    var output: String {
        if decode {
            var s = input.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while s.count % 4 != 0 { s += "=" }
            return Data(base64Encoded: s).flatMap { String(data: $0, encoding: .utf8) ?? "(\($0.count) bytes of binary data)" } ?? "Not valid Base64"
        }
        var e = Data(input.utf8).base64EncodedString()
        if urlSafe { e = e.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
        return e
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Picker("", selection: $decode) { Text("Encode").tag(false); Text("Decode").tag(true) }.pickerStyle(.segmented).frame(width: 200); Toggle("URL-safe", isOn: $urlSafe).toggleStyle(.checkbox) }.padding([.horizontal, .top], 20)
            split({ TextPane(title: "Input", text: $input) }, { TextPane(title: "Output", text: .constant(output), editable: false) })
        }
    }
}

struct HashTool: View {
    @State private var input = ""
    @State private var file: URL?
    @State private var fileHashes: [(String, String)] = []
    func hashes(_ d: Data) -> [(String, String)] {
        func hex<D: Sequence>(_ x: D) -> String where D.Element == UInt8 { x.map { String(format: "%02x", $0) }.joined() }
        return [("MD5", hex(Insecure.MD5.hash(data: d))), ("SHA-1", hex(Insecure.SHA1.hash(data: d))), ("SHA-256", hex(SHA256.hash(data: d))), ("SHA-512", hex(SHA512.hash(data: d)))]
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextPane(title: "Text", text: $input).frame(height: 140)
            ForEach(hashes(Data(input.utf8)), id: \.0) { CopyRow(label: $0.0, value: $0.1) }
            Divider()
            HStack { Button("Hash a File…") { if let f = pickFiles(multiple: false).first { hashFile(f) } }; if let file { Text(file.lastPathComponent).foregroundStyle(.secondary) } }
            ForEach(fileHashes, id: \.0) { CopyRow(label: $0.0, value: $0.1) }
            Spacer()
        }
        .padding(20)
        .dropDestination(for: URL.self) { u, _ in if let f = u.first { hashFile(f) }; return true }
    }
    func hashFile(_ u: URL) {
        file = u; fileHashes = [("SHA-256", "Computing…")]
        Task.detached {
            var md5 = Insecure.MD5(), s1 = Insecure.SHA1(), s256 = SHA256(), s512 = SHA512()
            if let h = try? FileHandle(forReadingFrom: u) {
                while true { let c = autoreleasepool { h.readData(ofLength: 1 << 20) }; if c.isEmpty { break }; md5.update(data: c); s1.update(data: c); s256.update(data: c); s512.update(data: c) }
            }
            func hex<D: Sequence>(_ x: D) -> String where D.Element == UInt8 { x.map { String(format: "%02x", $0) }.joined() }
            let r = [("MD5", hex(md5.finalize())), ("SHA-1", hex(s1.finalize())), ("SHA-256", hex(s256.finalize())), ("SHA-512", hex(s512.finalize()))]
            await MainActor.run { fileHashes = r }
        }
    }
}

struct UUIDTool: View {
    @State private var count = 5
    @State private var upper = false
    @State private var list: [String] = []
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Stepper("How many: \(count)", value: $count, in: 1...500); Toggle("Uppercase", isOn: $upper).toggleStyle(.checkbox); Button("Generate") { gen() }.buttonStyle(.borderedProminent) }
            TextPane(title: "UUIDs", text: .constant(list.joined(separator: "\n")), editable: false)
        }.padding(20).onAppear(perform: gen)
    }
    func gen() { list = (0..<count).map { _ in let u = UUID().uuidString; return upper ? u : u.lowercased() } }
}

struct JWTTool: View {
    @State private var token = ""
    func part(_ i: Int) -> String {
        let parts = token.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".")
        guard parts.count > i else { return "" }
        var s = String(parts[i]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        guard let d = Data(base64Encoded: s), let o = try? JSONSerialization.jsonObject(with: d), let p = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]) else { return "Can't decode" }
        return String(data: p, encoding: .utf8) ?? ""
    }
    var expiry: String? {
        guard let d = part(1).data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let exp = o["exp"] as? Double else { return nil }
        let date = Date(timeIntervalSince1970: exp)
        return (date < Date() ? "Expired " : "Expires ") + Fmt.when(date)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextPane(title: "Token", text: $token).frame(height: 110)
            if let expiry { Label(expiry, systemImage: "clock").foregroundStyle(expiry.hasPrefix("Expired") ? .red : .green) }
            HStack(spacing: 14) { TextPane(title: "Header", text: .constant(part(0)), editable: false); TextPane(title: "Payload", text: .constant(part(1)), editable: false) }
            Text("The signature is not verified. Tokens never leave your Mac.").font(.caption).foregroundStyle(.secondary)
        }.padding(20)
    }
}

struct TimestampTool: View {
    @State private var input = "\(Int(Date().timeIntervalSince1970))"
    @State private var date = Date()
    var parsed: Date? {
        let t = input.trimmingCharacters(in: .whitespaces)
        if let n = Double(t) { return Date(timeIntervalSince1970: n > 1e11 ? n / 1000 : n) }
        return ISO8601DateFormatter().date(from: t)
    }
    var body: some View {
        Form {
            Section("Timestamp → Date") {
                TextField("Unix seconds, milliseconds or ISO 8601", text: $input)
                if let d = parsed {
                    CopyRow(label: "Local", value: DateFormatter.localizedString(from: d, dateStyle: .full, timeStyle: .long))
                    CopyRow(label: "UTC (ISO)", value: ISO8601DateFormatter().string(from: d))
                    CopyRow(label: "Relative", value: Fmt.ago(d))
                } else { Text("Not a timestamp").foregroundStyle(.secondary) }
            }
            Section("Date → Timestamp") {
                DatePicker("Date", selection: $date)
                CopyRow(label: "Seconds", value: "\(Int(date.timeIntervalSince1970))")
                CopyRow(label: "Milliseconds", value: "\(Int64(date.timeIntervalSince1970 * 1000))")
                Button("Now") { date = Date(); input = "\(Int(Date().timeIntervalSince1970))" }
            }
        }.formStyle(.grouped).padding(10)
    }
}

struct DiffTool: View {
    @State private var a = "one\ntwo\nthree"
    @State private var b = "one\n2\nthree\nfour"
    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) { TextPane(title: "Original", text: $a); TextPane(title: "Changed", text: $b) }.frame(height: 200)
            let diff = b.components(separatedBy: "\n").difference(from: a.components(separatedBy: "\n"))
            let removed = diff.removals.count, inserted = diff.insertions.count
            HStack { Text("\(removed) removed").foregroundStyle(.red); Text("\(inserted) added").foregroundStyle(.green); Spacer() }.font(.callout)
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(lines().enumerated()), id: \.offset) { _, l in
                        Text((l.0 == 0 ? "  " : l.0 < 0 ? "− " : "+ ") + l.1).font(.system(.body, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(l.0 == 0 ? Color.clear : l.0 < 0 ? Color.red.opacity(0.15) : Color.green.opacity(0.15))
                    }
                }
            }.background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        }.padding(20)
    }
    /// Simple LCS-based unified diff.
    func lines() -> [(Int, String)] {
        let x = a.components(separatedBy: "\n"), y = b.components(separatedBy: "\n")
        guard x.count * y.count < 4_000_000 else { return [(0, "Too long to compare")] }
        var dp = Array(repeating: Array(repeating: 0, count: y.count + 1), count: x.count + 1)
        for i in stride(from: x.count - 1, through: 0, by: -1) { for j in stride(from: y.count - 1, through: 0, by: -1) { dp[i][j] = x[i] == y[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1]) } }
        var i = 0, j = 0, out: [(Int, String)] = []
        while i < x.count && j < y.count {
            if x[i] == y[j] { out.append((0, x[i])); i += 1; j += 1 } else if dp[i + 1][j] >= dp[i][j + 1] { out.append((-1, x[i])); i += 1 } else { out.append((1, y[j])); j += 1 }
        }
        while i < x.count { out.append((-1, x[i])); i += 1 }
        while j < y.count { out.append((1, y[j])); j += 1 }
        return out
    }
}

struct RegexTool: View {
    @State private var pattern = "\\b(\\w+)@(\\w+\\.\\w+)\\b"
    @State private var text = "Write to hello@example.com or team@spyglass.app"
    @State private var ci = true
    var matches: Result<[NSTextCheckingResult], Error> {
        Result { try NSRegularExpression(pattern: pattern, options: ci ? [.caseInsensitive] : []).matches(in: text, range: NSRange(text.startIndex..., in: text)) }
    }
    var highlighted: AttributedString {
        var a = AttributedString(text)
        if case .success(let ms) = matches {
            for m in ms { if let r = Range(m.range, in: text), let ar = Range(r, in: a) { a[ar].backgroundColor = .yellow.opacity(0.45) } }
        }
        return a
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { TextField("Pattern", text: $pattern).textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced)); Toggle("Ignore case", isOn: $ci).toggleStyle(.checkbox) }
            TextPane(title: "Test text", text: $text, mono: false).frame(height: 120)
            Text(highlighted).padding(8).frame(maxWidth: .infinity, alignment: .leading).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            switch matches {
            case .failure(let e): Label(e.localizedDescription, systemImage: "xmark.octagon").foregroundStyle(.red)
            case .success(let ms):
                Text("\(ms.count) match\(ms.count == 1 ? "" : "es")").font(.headline)
                List(Array(ms.enumerated()), id: \.offset) { i, m in
                    VStack(alignment: .leading) {
                        Text("\(i + 1). " + (Range(m.range, in: text).map { String(text[$0]) } ?? "")).font(.system(.body, design: .monospaced))
                        ForEach(1..<max(1, m.numberOfRanges), id: \.self) { g in
                            Text("  $\(g): " + (Range(m.range(at: g), in: text).map { String(text[$0]) } ?? "–")).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }.padding(20)
    }
}

struct URLTool: View {
    @State private var input = "https://example.com/page?utm_source=news&utm_medium=email&id=42&fbclid=abc"
    static let tracking: Set<String> = ["utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content", "fbclid", "gclid", "mc_cid", "mc_eid", "igshid", "si", "ref_src", "_hsenc", "_hsmi", "yclid", "msclkid"]
    var tidy: String {
        input.components(separatedBy: .newlines).map { line in
            guard var c = URLComponents(string: line.trimmingCharacters(in: .whitespaces)) else { return line }
            c.queryItems = c.queryItems?.filter { !Self.tracking.contains($0.name.lowercased()) }
            if c.queryItems?.isEmpty == true { c.queryItems = nil }
            return c.string ?? line
        }.joined(separator: "\n")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextPane(title: "Links", text: $input).frame(height: 120)
            CopyRow(label: "Tidy", value: tidy)
            CopyRow(label: "Encoded", value: input.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=?+"))) ?? "")
            CopyRow(label: "Decoded", value: input.removingPercentEncoding ?? input)
            if let c = URLComponents(string: input.trimmingCharacters(in: .whitespaces)), let items = c.queryItems {
                Text("Parameters").font(.headline)
                ForEach(Array(items.enumerated()), id: \.offset) { _, q in
                    HStack { Text(q.name).font(.system(.body, design: .monospaced)).foregroundStyle(Self.tracking.contains(q.name) ? .red : .primary); Text(q.value ?? "").foregroundStyle(.secondary) }
                }
            }
            Spacer()
        }.padding(20)
    }
}

struct UnicodeTool: View {
    @State private var input = "Spyglass 👀 ñ"
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Text", text: $input).textFieldStyle(.roundedBorder).font(.title3)
            Text("\(input.count) characters · \(input.unicodeScalars.count) scalars · \(input.utf8.count) UTF-8 bytes · \(input.utf16.count) UTF-16 units").foregroundStyle(.secondary)
            Table(Array(input.unicodeScalars.enumerated()).map { USRow(i: $0.offset, s: $0.element) }) {
                TableColumn("Char") { Text(String($0.s)).font(.title3) }.width(50)
                TableColumn("Code point") { Text(String(format: "U+%04X", $0.s.value)).font(.system(.body, design: .monospaced)) }.width(100)
                TableColumn("Name") { Text($0.s.properties.name ?? "–") }
                TableColumn("UTF-8") { r in Text(String(r.s).utf8.map { String(format: "%02X", $0) }.joined(separator: " ")).font(.system(.caption, design: .monospaced)) }.width(110)
            }
        }.padding(20)
    }
    struct USRow: Identifiable { let i: Int; let s: Unicode.Scalar; var id: Int { i } }
}

struct LoremTool: View {
    @State private var paras = 3
    @State private var text = ""
    static let words = "lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor incididunt ut labore et dolore magna aliqua enim ad minim veniam quis nostrud exercitation ullamco laboris nisi aliquip ex ea commodo consequat duis aute irure in reprehenderit voluptate velit esse cillum fugiat nulla pariatur excepteur sint occaecat cupidatat non proident sunt culpa qui officia deserunt mollit anim id est laborum".split(separator: " ")
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Stepper("Paragraphs: \(paras)", value: $paras, in: 1...20); Button("Generate") { gen() }.buttonStyle(.borderedProminent) }
            TextPane(title: "Text", text: $text, mono: false)
        }.padding(20).onAppear(perform: gen)
    }
    func gen() {
        text = (0..<paras).map { p in
            (0..<Int.random(in: 4...7)).map { s in
                let n = Int.random(in: 8...16)
                var w = (0..<n).map { _ in String(Self.words.randomElement()!) }
                if p == 0 && s == 0 { w = ["Lorem", "ipsum", "dolor", "sit", "amet,"] + w.prefix(n - 5) }
                return w.joined(separator: " ").prefix(1).uppercased() + w.joined(separator: " ").dropFirst() + "."
            }.joined(separator: " ")
        }.joined(separator: "\n\n")
    }
}

struct PasswordTool: View {
    @State private var length = 20.0
    @State private var symbols = true
    @State private var numbers = true
    @State private var words = false
    @State private var pw = ""
    var strength: (String, Color) {
        let bits = words ? Double(Int(length / 4)) * 11 : length * log2(Double(26 + 26 + (numbers ? 10 : 0) + (symbols ? 20 : 0)))
        return bits > 100 ? ("Very strong", .green) : bits > 70 ? ("Strong", .mint) : bits > 50 ? ("OK", .orange) : ("Weak", .red)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(pw).font(.system(size: 22, weight: .medium, design: .monospaced)).textSelection(.enabled).padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            HStack { Text(strength.0).foregroundStyle(strength.1).font(.headline); Spacer()
                Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(pw, forType: .string); ActivityLog.shared.show("Copied password") }
                Button("New") { gen() }.buttonStyle(.borderedProminent) }
            HStack { Text("Length"); Slider(value: $length, in: 8...64, step: 1); Text("\(Int(length))").monospacedDigit().frame(width: 30) }
            HStack { Toggle("Numbers", isOn: $numbers); Toggle("Symbols", isOn: $symbols); Toggle("Memorable words", isOn: $words) }.toggleStyle(.checkbox)
            Spacer()
        }.padding(20).onAppear(perform: gen).onChange(of: length) { gen() }.onChange(of: symbols) { gen() }.onChange(of: numbers) { gen() }.onChange(of: words) { gen() }
    }
    func gen() {
        if words {
            let list = ["amber", "brisk", "cedar", "delta", "ember", "fjord", "glade", "harbor", "indigo", "jasper", "kettle", "lumen", "maple", "nectar", "orbit", "pebble", "quartz", "raven", "saffron", "tundra", "umber", "velvet", "willow", "xenon", "yonder", "zephyr"]
            pw = (0..<max(3, Int(length / 5))).map { _ in list.randomElement()!.capitalized }.joined(separator: "-") + (numbers ? "-\(Int.random(in: 10...99))" : "")
            return
        }
        var chars = Array("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ")
        if numbers { chars += Array("23456789") }
        if symbols { chars += Array("!@#$%^&*-_=+?") }
        var g = SystemRandomNumberGenerator()
        pw = String((0..<Int(length)).map { _ in chars.randomElement(using: &g)! })
    }
}

struct CSVJSONTool: View {
    @State private var input = "name,size,kind\nreport.pdf,2.1 MB,Document\nphoto.heic,3.4 MB,Image"
    @State private var toJSON = true
    func parseCSV(_ s: String) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false
        var it = Array(s).makeIterator(); var prev: Character?
        while let c = it.next() {
            if quoted { if c == "\"" { quoted = false } else { field.append(c) } }
            else if c == "\"" { if prev == "\"" { field.append("\"") }; quoted = true }
            else if c == "," { row.append(field); field = "" }
            else if c == "\n" || c == "\r\n" { row.append(field); rows.append(row); row = []; field = "" }
            else if c != "\r" { field.append(c) }
            prev = c
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }
    var output: String {
        if toJSON {
            let rows = parseCSV(input)
            guard let head = rows.first else { return "" }
            let objs = rows.dropFirst().map { r in Dictionary(uniqueKeysWithValues: head.enumerated().map { ($0.element, $0.offset < r.count ? r[$0.offset] : "") }) }
            return (try? JSONSerialization.data(withJSONObject: objs, options: [.prettyPrinted, .sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }
        guard let arr = (try? JSONSerialization.jsonObject(with: Data(input.utf8))) as? [[String: Any]] else { return "Expecting a JSON array of objects" }
        let keys = Array(Set(arr.flatMap(\.keys))).sorted()
        func esc(_ v: Any?) -> String { let s = v.map { "\($0)" } ?? ""; return s.contains(",") || s.contains("\"") || s.contains("\n") ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s }
        return ([keys.joined(separator: ",")] + arr.map { o in keys.map { esc(o[$0]) }.joined(separator: ",") }).joined(separator: "\n")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("", selection: $toJSON) { Text("CSV → JSON").tag(true); Text("JSON → CSV").tag(false) }.pickerStyle(.segmented).frame(width: 260).padding([.horizontal, .top], 20)
            split({ TextPane(title: "Input", text: $input) }, { TextPane(title: "Output", text: .constant(output), editable: false) })
        }
    }
}

// MARK: - Text & speech

struct WordCountTool: View {
    @State private var text = ""
    var body: some View {
        let words = text.split { $0.isWhitespace || $0.isNewline }.count
        let sentences = text.split { ".!?".contains($0) }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                stat("Words", words); stat("Characters", text.count); stat("No spaces", text.filter { !$0.isWhitespace }.count)
                stat("Sentences", sentences); stat("Lines", text.isEmpty ? 0 : text.components(separatedBy: "\n").count)
                Card(padding: 12) { VStack(alignment: .leading) { Text("Reading time").font(.caption).foregroundStyle(.secondary); Text("\(max(1, words / 230)) min").font(.title3.weight(.semibold)) } }
            }
            TextPane(title: "Text", text: $text, mono: false)
        }.padding(20)
    }
    func stat(_ t: String, _ n: Int) -> some View { Card(padding: 12) { VStack(alignment: .leading) { Text(t).font(.caption).foregroundStyle(.secondary); Text(Fmt.count(n)).font(.title3.weight(.semibold)).monospacedDigit() } } }
}

struct ChangeCaseTool: View {
    @State private var text = "The quick brown fox jumps over the lazy dog"
    var wordsList: [String] { text.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextPane(title: "Text", text: $text, mono: false).frame(height: 140)
            CopyRow(label: "UPPERCASE", value: text.uppercased())
            CopyRow(label: "lowercase", value: text.lowercased())
            CopyRow(label: "Title Case", value: text.capitalized)
            CopyRow(label: "Sentence", value: text.prefix(1).uppercased() + text.dropFirst().lowercased())
            CopyRow(label: "camelCase", value: wordsList.enumerated().map { $0.offset == 0 ? $0.element.lowercased() : $0.element.capitalized }.joined())
            CopyRow(label: "PascalCase", value: wordsList.map(\.capitalized).joined())
            CopyRow(label: "snake_case", value: wordsList.map { $0.lowercased() }.joined(separator: "_"))
            CopyRow(label: "kebab-case", value: wordsList.map { $0.lowercased() }.joined(separator: "-"))
            Spacer()
        }.padding(20)
    }
}

final class Speaker: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    let synth = AVSpeechSynthesizer()
    @Published var speaking = false
    override init() { super.init(); synth.delegate = self }
    func speak(_ t: String, rate: Float, voice: String?) {
        synth.stopSpeaking(at: .immediate)
        let u = AVSpeechUtterance(string: t)
        u.rate = rate
        if let voice { u.voice = AVSpeechSynthesisVoice(identifier: voice) }
        synth.speak(u); speaking = true
    }
    func stop() { synth.stopSpeaking(at: .immediate); speaking = false }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) { DispatchQueue.main.async { self.speaking = false } }
}

struct ReadAloudTool: View {
    @StateObject private var sp = Speaker()
    @State private var text = "Spyglass reads any text aloud, right on your Mac."
    @State private var rate: Float = AVSpeechUtteranceDefaultSpeechRate
    @State private var voice: String?
    var voices: [AVSpeechSynthesisVoice] { AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(Locale.current.language.languageCode?.identifier ?? "en") }.sorted { $0.quality.rawValue > $1.quality.rawValue } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextPane(title: "Text", text: $text, mono: false)
            HStack {
                Picker("Voice", selection: $voice) { Text("Default").tag(String?.none); ForEach(voices, id: \.identifier) { Text($0.name + ($0.quality == .enhanced || $0.quality == .premium ? " ✦" : "")).tag(Optional($0.identifier)) } }.frame(width: 260)
                Text("Speed"); Slider(value: $rate, in: 0.3...0.65).frame(width: 140)
                Spacer()
                Button(sp.speaking ? "Stop" : "Read Aloud") { sp.speaking ? sp.stop() : sp.speak(text, rate: rate, voice: voice) }.buttonStyle(.borderedProminent)
            }
        }.padding(20).onDisappear { sp.stop() }
    }
}

struct TranslateTool: View {
    @State private var text = "Hello! Where is the train station?"
    @State private var show = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextPane(title: "Text", text: $text, mono: false)
            HStack {
                Text("Uses Apple's on-device translation. Download languages in System Settings › General › Language & Region.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Translate") { show = true }.buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .modifier(TranslateModifier(show: $show, text: text))
    }
}

struct TranslateModifier: ViewModifier {
    @Binding var show: Bool
    let text: String
    func body(content: Content) -> some View {
        #if canImport(Translation)
        if #available(macOS 14.4, *) { content.translationPresentation(isPresented: $show, text: text) } else { content }
        #else
        content
        #endif
    }
}

struct QRTool: View {
    @State private var text = "https://example.com"
    var image: NSImage? { QR.make(text) }
    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 12) {
                TextPane(title: "Text or link", text: $text, mono: false).frame(height: 140)
                HStack {
                    Button("Copy Image") { if let i = image { NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([i]); ActivityLog.shared.show("Copied QR code") } }
                    Button("Save PNG…") { save() }
                }
            }
            if let image { Image(nsImage: image).interpolation(.none).resizable().frame(width: 260, height: 260).padding(10).background(.white, in: RoundedRectangle(cornerRadius: 12)) }
        }.padding(20)
    }
    func save() {
        guard let i = image, let t = i.tiffRepresentation, let png = NSBitmapImageRep(data: t)?.representation(using: .png, properties: [:]) else { return }
        let u = FileOps.uniqueURL(FileOps.outputFolder("QR Codes").appendingPathComponent("QR Code.png"))
        try? png.write(to: u); FileOps.created([u], title: "Saved QR code"); FileOps.reveal([u])
    }
}

enum QR {
    static func make(_ s: String, scale: CGFloat = 12) -> NSImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(s.utf8); f.correctionLevel = "M"
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) else { return nil }
        let rep = NSCIImageRep(ciImage: out)
        let img = NSImage(size: rep.size); img.addRepresentation(rep)
        return img
    }
}
