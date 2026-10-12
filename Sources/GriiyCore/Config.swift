// config.toml (PRD §6.6). Bad values fall back to their default with a warning; never fatal.
//
// TOML, read by a small parser for the subset griiy uses: `key = value` with strings, integers,
// floats and booleans, `[table]` headers and comments. Anything else (arrays, inline tables,
// dotted keys, …) is a syntax error: the whole file falls back to defaults with one warning,
// as a full TOML parser would on a broken file.
import Foundation
import System

public enum Backend: Equatable, Sendable {
    case auto, claudeCli, api
}

public struct Config: Equatable, Sendable {
    public var backend = Backend.auto
    public var model = "claude-opus-5-5"
    public var contextLines = 40
    public var tokenLimit = 100_000
    public var largeFileBytes = 1 << 20

    public init() {}
}

/// `~/Library/Application Support/griiy` (PRD §6.6, §7.4).
public func appDir() -> FilePath? {
    ProcessInfo.processInfo.environment["HOME"].map { FilePath($0).appending("Library/Application Support/griiy") }
}

/// Missing or empty file → defaults, no warnings.
public func loadConfig(_ path: FilePath) -> (Config, [String]) {
    var c = Config()
    var warn: [String] = []
    let text: String
    do {
        text = try String(contentsOfFile: path.string, encoding: .utf8)
    } catch let e as CocoaError where e.code == .fileReadNoSuchFile {
        return (c, warn)
    } catch {
        return (c, ["\(path.string): \(error.localizedDescription)"])
    }
    let table: [(String, Toml)]
    switch parseToml(text) {
    case .success(let t): table = t
    case .failure(let e): return (c, ["\(path.string): \(e.message)"])
    }
    func int(_ key: String, _ v: Toml, _ range: ClosedRange<Int>, _ set: (Int) -> Void) {
        if case .int(let n) = v, range.contains(n) {
            set(n)
        } else {
            warn.append(bad(key, v, "an integer in \(range.lowerBound)..=\(range.upperBound)"))
        }
    }
    for (key, v) in table {
        switch key {
        case "ai":
            guard case .table(let ai) = v else {
                warn.append(bad("ai", v, "a table"))
                continue
            }
            for (k, v) in ai {
                switch (k, v) {
                case ("backend", .string("auto")): c.backend = .auto
                case ("backend", .string("claude-cli")): c.backend = .claudeCli
                case ("backend", .string("api")): c.backend = .api
                case ("backend", _): warn.append(bad("ai.backend", v, "\"auto\", \"claude-cli\" or \"api\""))
                case ("model", .string(let m)) where !m.trimmingCharacters(in: .whitespaces).isEmpty: c.model = m
                case ("model", _): warn.append(bad("ai.model", v, "a model name"))
                default: warn.append("unknown setting ai.\(k)")
                }
            }
        case "context_lines": int(key, v, 0...1_000) { c.contextLines = $0 }
        case "token_limit": int(key, v, 1_000...1_000_000) { c.tokenLimit = $0 }
        case "large_file_bytes": int(key, v, 1...(1 << 30)) { c.largeFileBytes = $0 }
        default: warn.append("unknown setting \(key)")
        }
    }
    return (c, warn)
}

private func bad(_ key: String, _ v: Toml, _ want: String) -> String {
    "\(key) = \(v) is invalid (want \(want)); using the default"
}

indirect enum Toml: CustomStringConvertible {
    case string(String)
    case int(Int)
    case float(Double)
    case bool(Bool)
    case table([(String, Toml)])

    var description: String {
        switch self {
        case .string(let s):
            "\"\(s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
        case .int(let n): "\(n)"
        case .float(let d): "\(d)"
        case .bool(let b): "\(b)"
        case .table: "{…}"
        }
    }
}

struct TomlError: Error {
    let message: String
}

/// Top-level keys in file order; a `[name]` header starts a table that collects the keys after it.
func parseToml(_ text: String) -> Result<[(String, Toml)], TomlError> {
    var top: [(String, Toml)] = []
    var table: (name: String, keys: [(String, Toml)])?
    var seen = Set<String>()
    func flush() {
        if let t = table { top.append((t.name, .table(t.keys))) }
    }
    for (n, raw) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
        let fail = { (why: String) in
            Result<[(String, Toml)], TomlError>.failure(TomlError(message: "line \(n + 1): \(why)"))
        }
        let line = stripComment(raw).trimmingCharacters(in: .whitespaces)
        if line.isEmpty { continue }
        if line.hasPrefix("[") {
            guard line.hasSuffix("]"),
                let name = bareKey(String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)),
                seen.insert(name).inserted
            else { return fail("invalid table header \(line)") }
            flush()
            table = (name, [])
            continue
        }
        guard let eq = line.firstIndex(of: "="), let key = bareKey(line[..<eq].trimmingCharacters(in: .whitespaces)),
            let value = scalar(line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)),
            seen.insert((table.map { $0.name + "." } ?? "") + key).inserted
        else { return fail("expected key = value, got \(line)") }
        if table == nil { top.append((key, value)) } else { table?.keys.append((key, value)) }
    }
    flush()
    return .success(top)
}

/// `#` starts a comment unless it is inside a "basic" or 'literal' string.
private func stripComment(_ line: Substring) -> Substring {
    var quote: Character?
    var escaped = false
    for i in line.indices {
        let ch = line[i]
        if escaped {
            escaped = false
        } else if quote == "\"" && ch == "\\" {
            escaped = true
        } else if let q = quote {
            if ch == q { quote = nil }
        } else if ch == "\"" || ch == "'" {
            quote = ch
        } else if ch == "#" {
            return line[..<i]
        }
    }
    return line
}

private func bareKey(_ s: String) -> String? {
    let ok =
        !s.isEmpty
        && s.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "_" || $0 == "-"
        }
    return ok ? s : nil
}

private func scalar(_ s: String) -> Toml? {
    if s == "true" { return .bool(true) }
    if s == "false" { return .bool(false) }
    if s.hasPrefix("\"") { return basicString(s).map(Toml.string) }
    // A literal string: no escapes, ends at the next `'`.
    if s.count >= 2, s.hasPrefix("'"), s.hasSuffix("'"), !s.dropFirst().dropLast().contains("'") {
        return .string(String(s.dropFirst().dropLast()))
    }
    let digits = s.replacingOccurrences(of: "_", with: "")
    if let n = Int(digits) { return .int(n) }
    if digits.contains(where: { ".eE".contains($0) }), let d = Double(digits), d.isFinite { return .float(d) }
    return nil
}

/// `"…"` with TOML's basic escapes, and nothing after the closing quote.
private func basicString(_ s: String) -> String? {
    var out = ""
    var it = s.dropFirst().makeIterator()
    while let ch = it.next() {
        switch ch {
        case "\"": return it.next() == nil ? out : nil
        case "\\":
            switch it.next() {
            case "\"": out.append("\"")
            case "\\": out.append("\\")
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "r": out.append("\r")
            default: return nil
            }
        default: out.append(ch)
        }
    }
    return nil
}
