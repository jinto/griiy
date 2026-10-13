// Syntax highlighting (F-DV-3): keywords, strings, comments and numbers, by file extension. Scans
// bytes, never looks ahead past a few bytes, so a line costs its length (docs/PLAN-M1-9.md). Spans
// are in UTF-16 offsets, ready for an NSAttributedString. Not a parser: no types, calls, regex
// literals, heredocs or Ruby %q().

public enum Token: Equatable, Sendable {
    case keyword, string, comment, number
}

/// Where a line starts: in code, a block comment, or a multi-line string closed by `quote`
/// (three of them when `triple`).
public enum LexState: Equatable, Sendable {
    case code, comment
    case string(quote: UInt8, triple: Bool)
}

/// A language as the lexer sees it, picked by file name.
public struct Lang: Sendable {
    enum Single: Sendable { case none, string, char }
    enum Backtick: Sendable { case none, escaped, raw }

    var line: [[UInt8]] = []
    /// `#` starts a comment only at the line start or after a space (shell, YAML).
    var hashNeedsSpace = false
    var block: (open: [UInt8], close: [UInt8])?
    var single = Single.string
    /// `'` strings have no escapes (shell, YAML, TOML).
    var rawSingle = false
    /// Which quotes open a `"""`-style multi-line string.
    var triple: [UInt8] = []
    var backtick = Backtick.none
    var keywords: Set<String> = []
    /// Keywords match in any case (stored lowercase).
    var caseless = false

    public static func of(path: String) -> Lang? {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        if let l = byName[name] { return l }
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return nil }
        return byExtension[name[name.index(after: dot)...].lowercased()]
    }
}

private func words(_ s: String) -> Set<String> { Set(s.split(separator: " ").map(String.init)) }

private let cBlock = (Array("/*".utf8), Array("*/".utf8))
private let slashes = [Array("//".utf8)]
private let hash = [Array("#".utf8)]
private let dashes = [Array("--".utf8)]
private let dq = UInt8(ascii: "\"")
private let sq = UInt8(ascii: "'")
private let bt = UInt8(ascii: "`")

private let common = words(
    "if else for while do switch case default break continue return goto true false null nil new delete "
        + "class struct enum interface public private protected internal static const final void import package "
        + "using namespace try catch finally throw throws this super extends implements abstract override "
        + "virtual var val let fun def in is as typedef sizeof int char long short float double bool boolean "
        + "unsigned signed auto extern volatile inline yield async await object when function echo")
private let swift = words(
    "let var func if else guard return for in while repeat switch case default break continue fallthrough "
        + "struct class enum protocol extension import init deinit self Self super nil true false try throw "
        + "throws rethrows catch do defer where as is static private fileprivate public internal open final "
        + "override mutating nonmutating weak unowned lazy inout some any async await typealias "
        + "associatedtype subscript operator convenience required actor nonisolated")
private let python = words(
    "and as assert async await break class continue def del elif else except False finally for from global "
        + "if import in is lambda None nonlocal not or pass raise return True try while with yield match case self")
private let js = words(
    "break case catch class const continue debugger default delete do else export extends false finally for "
        + "function if import in instanceof let new null return super switch this throw true try typeof "
        + "undefined var void while with yield async await of static get set interface type enum implements "
        + "private public protected readonly as from declare namespace abstract keyof")
private let go = words(
    "break case chan const continue default defer else fallthrough for func go goto if import interface map "
        + "package range return select struct switch type var nil true false iota")
private let rust = words(
    "as async await break const continue crate dyn else enum extern false fn for if impl in let loop match "
        + "mod move mut pub ref return self Self static struct super trait true type unsafe use where while")
private let shell = words(
    "if then else elif fi case esac for while until do done in function return local export echo exit set "
        + "unset readonly shift source break continue true false")
private let ruby = words(
    "alias and begin break case class def do else elsif end ensure false for if in module next nil not or "
        + "redo rescue retry return self super then true undef unless until when while yield require")
private let sql = words(
    "select from where and or not insert into values update set delete create table drop alter index join "
        + "left right inner outer on as group by order having limit offset union all distinct null is in like "
        + "between case when then else end primary key foreign references default exists with returning begin "
        + "commit rollback")
private let lua = words(
    "and break do else elseif end false for function goto if in local nil not or repeat return then true "
        + "until while")
private let literals = words("true false null")

private let byExtension: [String: Lang] = {
    var m: [String: Lang] = [:]
    func add(_ exts: String, _ l: Lang) { for e in exts.split(separator: " ") { m[String(e)] = l } }
    add("c h cc cpp cxx hpp hh m mm", Lang(line: slashes, block: cBlock, single: .char, keywords: common))
    add("java kt kts scala cs", Lang(line: slashes, block: cBlock, single: .char, triple: [dq], keywords: common))
    add("php", Lang(line: slashes + hash, block: cBlock, keywords: common))
    add("dart", Lang(line: slashes, block: cBlock, triple: [dq, sq], keywords: common))
    add("swift", Lang(line: slashes, block: cBlock, single: .none, triple: [dq], keywords: swift))
    add("go", Lang(line: slashes, block: cBlock, single: .char, backtick: .raw, keywords: go))
    add("rs", Lang(line: slashes, block: cBlock, single: .char, keywords: rust))
    add("js jsx mjs cjs ts tsx", Lang(line: slashes, block: cBlock, backtick: .escaped, keywords: js))
    add("py pyi", Lang(line: hash, triple: [dq, sq], keywords: python))
    add("rb", Lang(line: hash, keywords: ruby))
    add("sh bash zsh", Lang(line: hash, hashNeedsSpace: true, rawSingle: true, keywords: shell))
    add("yml yaml toml", Lang(line: hash, hashNeedsSpace: true, rawSingle: true, keywords: literals))
    add("sql", Lang(line: dashes, block: cBlock, keywords: sql, caseless: true))
    add("lua", Lang(line: dashes, block: (Array("--[[".utf8), Array("]]".utf8)), keywords: lua))
    add("css", Lang(block: cBlock))
    add("scss less", Lang(line: slashes, block: cBlock))
    add("json", Lang(single: .none, keywords: literals))
    return m
}()

private let byName: [String: Lang] = [
    "Makefile": Lang(line: hash, hashNeedsSpace: true, rawSingle: true, keywords: shell),
    "Dockerfile": Lang(
        line: hash, hashNeedsSpace: true,
        keywords: words("from run cmd copy add env arg workdir expose entrypoint user volume label as"), caseless: true),
]

/// Spans of one line in UTF-16 offsets, and the state the next line starts in.
public func lex(_ text: String, _ lang: Lang, from: LexState) -> (spans: [(Range<Int>, Token)], end: LexState) {
    var text = text
    var spans: [(Range<Int>, Token)] = []
    let end = text.withUTF8 { b in
        var s = Lexer(b: b, lang: lang, emit: { spans.append(($0, $1)) })
        return s.run(from)
    }
    return (spans, end)
}

/// The state each row of `f.rows(from:n:)` starts in. Each hunk starts in code (what's above it is
/// unknown). Deleted lines continue the base side's state, added and context lines the head's;
/// context lines advance both.
// ponytail: a hunk starting inside a block comment colors it as code; lexing both whole blobs
// fixes it at the cost of two git calls per file. The whole-file view is one hunk, so it's right.
public func lexStates(_ f: File, _ lang: Lang) -> [LexState] {
    var out = [LexState](repeating: .code, count: f.rowCount)
    let next = { (text: String, s: LexState) -> LexState in
        var text = text
        return text.withUTF8 { b in
            var l = Lexer(b: b, lang: lang, emit: nil)
            return l.run(s)
        }
    }
    var at = 1
    for h in f.hunks {
        var old = LexState.code
        var new = LexState.code
        for (k, l) in h.lines.enumerated() {
            switch l.kind {
            case .del:
                out[at + 1 + k] = old
                old = next(l.text, old)
            case .add:
                out[at + 1 + k] = new
                new = next(l.text, new)
            case .context:
                out[at + 1 + k] = new
                let n = next(l.text, new)
                old = old == new ? n : next(l.text, old)
                new = n
            }
        }
        at += 1 + h.lines.count
    }
    return out
}

private struct Lexer {
    let b: UnsafeBufferPointer<UInt8>
    let lang: Lang
    /// nil when only the end state is wanted: no spans, no keyword lookups.
    let emit: ((Range<Int>, Token) -> Void)?
    var i = 0
    /// UTF-16 offset of byte i.
    var u = 0

    mutating func step() {
        let c = b[i]
        u += c < 0x80 ? 1 : c >= 0xF0 ? 2 : c >= 0xC0 ? 1 : 0
        i += 1
    }

    mutating func skip(_ n: Int) { for _ in 0..<max(n, 0) where i < b.count { step() } }

    func at(_ s: [UInt8]) -> Bool {
        guard b.count - i >= s.count else { return false }
        for k in s.indices where b[i + k] != s[k] { return false }
        return true
    }

    func put(_ from: Int, _ t: Token) { if u > from { emit?(from..<u, t) } }

    mutating func run(_ start: LexState) -> LexState {
        switch start {
        case .code: break
        case .comment:
            if !blockComment(from: 0) { return .comment }
        case .string(let q, let triple):
            if !string(from: 0, q, triple: triple) { return start }
        }
        while i < b.count {
            let c = b[i]
            let from = u
            if let block = lang.block, at(block.open) {
                skip(block.open.count)
                if !blockComment(from: from) { return .comment }
            } else if lang.line.contains(where: at), c != UInt8(ascii: "#") || hashStarts {
                skip(b.count - i)
                put(from, .comment)
            } else if c == dq || c == sq || c == bt {
                if let end = quoted(c, from) { return end }
            } else if c >= 48 && c <= 57 {
                number()
                put(from, .number)
            } else if word(c) {
                let s = i
                while i < b.count && (word(b[i]) || (b[i] >= 48 && b[i] <= 57)) { step() }
                if emit != nil {
                    var w = String(decoding: UnsafeBufferPointer(rebasing: b[s..<i]), as: UTF8.self)
                    if lang.caseless { w = w.lowercased() }
                    if lang.keywords.contains(w) { put(from, .keyword) }
                }
            } else {
                step()
            }
        }
        return .code
    }

    var hashStarts: Bool { !lang.hashNeedsSpace || i == 0 || b[i - 1] == 32 || b[i - 1] == 9 }

    func word(_ c: UInt8) -> Bool { c >= 0x80 || c == 95 || (c | 0x20 >= 97 && c | 0x20 <= 122) }

    /// A string at byte i opening with quote `q`; the state to return when it runs past the line.
    mutating func quoted(_ q: UInt8, _ from: Int) -> LexState? {
        if lang.triple.contains(q), at([q, q, q]) {
            skip(3)
            if !string(from: from, q, triple: true) { return .string(quote: q, triple: true) }
            return nil
        }
        switch q {
        case bt:
            step()
            if lang.backtick == .none { return nil }
            if !string(from: from, q, triple: false) { return .string(quote: q, triple: false) }
        case sq where lang.single == .none:
            step()
        case sq where lang.single == .char:
            charLiteral(from)
        default:
            // One-line strings run to the line end when unclosed; the next line is code.
            step()
            _ = string(from: from, q, triple: false)
        }
        return nil
    }

    /// `'x'` or `'\…'` (up to 10 bytes) is a char; any other `'` (a Rust lifetime) is code.
    mutating func charLiteral(_ from: Int) {
        var j = i + 1
        if j < b.count && b[j] == UInt8(ascii: "\\") {
            j += 2
            while j < b.count && j < i + 12 && b[j] != sq { j += 1 }
        } else if j < b.count {
            let c = b[j]
            j += c < 0x80 ? 1 : c >= 0xF0 ? 4 : c >= 0xE0 ? 3 : 2
        }
        guard j < b.count && b[j] == sq else { return step() }
        skip(j + 1 - i)
        put(from, .string)
    }

    /// Scans to the closing quote; false when the line ends first. Colors from `from` either way.
    mutating func string(from: Int, _ q: UInt8, triple: Bool) -> Bool {
        let escapes = !(q == bt && lang.backtick == .raw) && !(q == sq && lang.rawSingle)
        defer { put(from, .string) }
        while i < b.count {
            if escapes && b[i] == UInt8(ascii: "\\") {
                skip(2)
            } else if b[i] == q && (!triple || at([q, q, q])) {
                skip(triple ? 3 : 1)
                return true
            } else {
                step()
            }
        }
        return false
    }

    /// Scans to the end of a block comment; false when the line ends first.
    mutating func blockComment(from: Int) -> Bool {
        guard let close = lang.block?.close else { return true }
        defer { put(from, .comment) }
        while i < b.count {
            if at(close) {
                skip(close.count)
                return true
            }
            step()
        }
        return false
    }

    mutating func number() {
        while i < b.count {
            let c = b[i]
            let sign = (c == 43 || c == 45) && i > 0 && (b[i - 1] | 0x20) == UInt8(ascii: "e")
            guard sign || c == 46 || (c < 0x80 && word(c)) || (c >= 48 && c <= 57) else { return }
            step()
        }
    }
}
