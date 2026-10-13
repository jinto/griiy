// Unified diff → files, hunks and lines (F-DV-10). Pure: no git calls, never traps.
//
// Expects the output of `Git.diff` (fixed prefixes `a/` `b/`, `--full-index`); names may be
// C-quoted or raw. Names come from the most reliable line present: `rename/copy from|to`, then
// `---`/`+++`, then `diff --git` (the only source for binary, mode-only and empty files). Hunks end
// by their header's line counts, so content can never be mistaken for a header. Parses bytes:
// walking a 10MB diff as Swift Characters is 15–25× slower.

import Foundation

public enum Status: String, Equatable, Sendable {
    case added, deleted, modified, renamed, copied
    /// Only in a whole-file view of a file the diff doesn't touch.
    case unchanged
}

public enum Kind: Equatable, Sendable {
    case context, add, del
}

public struct Line: Equatable, Sendable {
    public var kind: Kind
    /// Line numbers in the base and head files; nil on the side the line isn't on.
    public var oldNo: Int?
    public var newNo: Int?
    /// Without the +/-/space prefix. A CRLF file keeps its `\r`.
    public var text: String
    /// `\ No newline at end of file` followed this line.
    public var noNewline = false
}

public struct Hunk: Equatable, Sendable {
    public var oldStart: Int, oldLen: Int, newStart: Int, newLen: Int
    /// Text after the second `@@` (git's function-name guess), trimmed.
    public var section: String
    public var lines: [Line] = []

    public var header: String {
        let h = "@@ -\(oldStart),\(oldLen) +\(newStart),\(newLen) @@ \(section)"
        return section.isEmpty ? String(h.dropLast()) : h
    }
}

/// One row of the diff view: the file header, a hunk header, a line, or the note a file without
/// hunks gets instead.
public enum Row: Equatable, Sendable {
    case fileHeader
    case hunk(String)
    case line(Line)
    case note(String)
}

public struct File: Equatable, Sendable {
    /// Head-side path; the base-side path for a deletion. Display only: names that aren't UTF-8
    /// are decoded lossily, so a file's identity is its ID and blob ids, never this.
    public var path: String
    /// Base-side path of a rename or copy.
    public var oldPath: String?
    public var status: Status
    public var oldMode: String?
    public var newMode: String?
    public var oldBlob: String?
    public var newBlob: String?
    public var binary = false
    public var hunks: [Hunk] = []

    /// (added, deleted) lines.
    public var stats: (add: Int, del: Int) {
        var a = 0
        var d = 0
        for h in hunks {
            for l in h.lines {
                if l.kind == .add { a += 1 } else if l.kind == .del { d += 1 }
            }
        }
        return (a, d)
    }

    /// Rows on screen: the file header, then each hunk's header and lines, or one note row when
    /// there are no hunks. The view sizes its whole scroll area from this.
    public var rowCount: Int { 1 + (hunks.isEmpty ? 1 : hunks.reduce(0) { $0 + 1 + $1.lines.count }) }

    /// The rows `from..<from + n` of the `rowCount`. Whole hunks before the window are skipped by
    /// their size, so a window deep in a huge file costs its own rows, not everything above it.
    public func rows(from: Int, n: Int) -> [Row] {
        // Out-of-range windows clamp instead of trapping.
        let from = max(from, 0)
        let end = from + min(max(n, 0), Int.max - from)
        let want = { (i: Int) in i >= from && i < end }
        var rows: [Row] = []
        if want(0) { rows.append(.fileHeader) }
        if hunks.isEmpty {
            if want(1) { rows.append(.note(note)) }
            return rows
        }
        var at = 1
        for h in hunks {
            if at >= end { break }
            if at + 1 + h.lines.count > from {
                if want(at) { rows.append(.hunk(h.header)) }
                let last = min(end - (at + 1), h.lines.count)
                let first = min(max(from - (at + 1), 0), last)
                rows += h.lines[first..<last].map(Row.line)
            }
            at += 1 + h.lines.count
        }
        return rows
    }

    /// Why a file with no hunks is in the diff.
    var note: String {
        if binary { return "Binary file" }
        if let a = oldMode, let b = newMode, a != b { return "Mode \(a) → \(b)" }
        return "No content changes"
    }

    /// Selected `lines` of one side's file, and the lines they cover on both sides (F-AI-1).
    /// Half-open, so an empty range still says where: `k..<k` is between lines k-1 and k. A context
    /// line maps to its twin; a changed line to its whole change block (the `-`/`+` run between
    /// context lines). Deleted lines alone map to an empty range.
    public func span(_ side: Side, _ lines: Range<Int>) -> (base: Range<Int>, head: Range<Int>) {
        // Hunk headers stop at UInt32 (the parser checks), so nothing below can overflow.
        let lines = lines.clamped(to: 0..<Int(UInt32.max))
        let lo = twin(side, lines.lowerBound, forward: true)
        let theirs = lo..<max(lo, twin(side, lines.upperBound - 1, forward: false) + 1)
        return side == .base ? (lines, theirs) : (theirs, lines)
    }

    /// The other side's first line at or after line `n`'s row (`forward`), or last at or before.
    private func twin(_ side: Side, _ n: Int, forward: Bool) -> Int {
        let my = side == .base ? \Line.oldNo : \Line.newNo
        let their = side == .base ? \Line.newNo : \Line.oldNo
        var delta = 0
        for h in hunks {
            let (myStart, myLen, theirStart, theirLen) =
                side == .base
                ? (h.oldStart, h.oldLen, h.newStart, h.newLen) : (h.newStart, h.newLen, h.oldStart, h.oldLen)
            // A start with length 0 is the line before the hunk.
            if n < myStart + (myLen == 0 ? 1 : 0) { break }
            if n < myStart + myLen, var i = h.lines.firstIndex(where: { $0[keyPath: my] == n }) {
                // Out to the edge of the change block, then on to the nearest line the other side has.
                let step = forward ? -1 : 1
                while h.lines[i].kind != .context, h.lines.indices.contains(i + step),
                    h.lines[i + step].kind != .context
                {
                    i += step
                }
                let t =
                    forward
                    ? h.lines[i...].lazy.compactMap { $0[keyPath: their] }.first
                    : h.lines[...i].lazy.compactMap { $0[keyPath: their] }.last
                if let t { return t }
                let before = theirLen == 0 ? theirStart : theirStart - 1
                return forward ? before + theirLen + 1 : before
            }
            delta += theirLen - myLen
        }
        // Between hunks, lines are unchanged.
        return n + delta
    }
}

public enum Side: Sendable {
    case base, head
}

/// The whole head file `text` with `f`'s changes in place (F-DV-5), as a File whose one hunk spans
/// both sides: the view, copying and `span` work on it as on any diff. `f` nil: an unchanged file.
/// If `text` no longer matches the diff (the work tree moved on), lines run out early; no trap.
public func whole(_ f: File?, path: String, text bytes: [UInt8]) -> File {
    var out = f ?? File(path: path, status: .unchanged)
    // git's test for binary: a NUL in the first 8000 bytes.
    if bytes.prefix(8000).contains(0) {
        out.binary = true
        out.hunks = []
        return out
    }
    var lines = bytes.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
    let noNewline = lines.last?.isEmpty == false
    if !noNewline { lines.removeLast() }
    var rows: [Line] = []
    var (o, n) = (1, 1)
    func gap(upTo end: Int) {
        while n < end, n >= 1, n <= lines.count {
            rows.append(Line(kind: .context, oldNo: o, newNo: n, text: text(lines[n - 1])))
            (o, n) = (o &+ 1, n &+ 1)
        }
    }
    // A start with length 0 is the line before the hunk. Wrapping: a hand-made File may hold any Int.
    let first = { (start: Int, len: Int) in len == 0 ? start &+ 1 : start }
    for h in out.hunks {
        gap(upTo: first(h.newStart, h.newLen))
        rows += h.lines
        (o, n) = (first(h.oldStart, h.oldLen) &+ h.oldLen, first(h.newStart, h.newLen) &+ h.newLen)
    }
    gap(upTo: Int.max)
    if noNewline, let last = rows.last, last.kind == .context, last.newNo == lines.count {
        rows[rows.count - 1].noNewline = true
    }
    let (ol, nl) = (rows.count { $0.oldNo != nil }, rows.count { $0.newNo != nil })
    var hunk = Hunk(oldStart: ol == 0 ? 0 : 1, oldLen: ol, newStart: nl == 0 ? 0 : 1, newLen: nl, section: "")
    hunk.lines = rows
    out.hunks = rows.isEmpty ? [] : [hunk]
    return out
}

/// A file while its header is read: names from each source, kept apart until the end.
private struct Draft {
    var gitNames: (String, String)?
    /// `---`/`+++`; `/dev/null` reads as absent, and the mode lines say added or deleted.
    var minus: String?
    var plus: String?
    var from: String?
    var to: String?
    var status: Status?
    var oldMode: String?
    var newMode: String?
    var oldBlob: String?
    var newBlob: String?
    var binary = false
    var hunks: [Hunk] = []

    /// nil only when no line named the file, which git's own output never does.
    func finish() -> File? {
        let old = from ?? minus ?? gitNames?.0
        let new = to ?? plus ?? gitNames?.1
        let status = status ?? .modified
        let path: String
        let oldPath: String?
        switch status {
        case .deleted:
            guard let old else { return nil }
            (path, oldPath) = (old, nil)
        case .renamed, .copied:
            guard let new else { return nil }
            (path, oldPath) = (new, old)
        case .added, .modified, .unchanged:
            guard let p = new ?? old else { return nil }
            (path, oldPath) = (p, nil)
        }
        // `index a..b <mode>` gives the mode when it didn't change; a side that doesn't exist has none.
        var oldMode = oldMode
        var newMode = newMode
        if status != .added && oldMode == nil { oldMode = newMode }
        if status == .deleted { newMode = nil }
        return File(
            path: path, oldPath: oldPath, status: status, oldMode: oldMode, newMode: newMode, oldBlob: oldBlob,
            newBlob: newBlob, binary: binary, hunks: hunks)
    }
}

private typealias Bytes = ArraySlice<UInt8>

private func text(_ b: Bytes) -> String { String(decoding: b, as: UTF8.self) }

extension ArraySlice<UInt8> {
    fileprivate func drop(_ prefix: String) -> Bytes? { starts(with: prefix.utf8) ? dropFirst(prefix.utf8.count) : nil }
}

public func parseDiff(_ input: [UInt8]) -> [File] {
    var files: [File] = []
    var draft: Draft?
    // Without the final newline, so a hunk cut short can't pick up a phantom empty line.
    var all = input[...]
    if all.last == UInt8(ascii: "\n") { all = all.dropLast() }
    let lines = all.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
    var i = 0
    func finish() {
        if let f = draft?.finish() { files.append(f) }
        draft = nil
    }
    while i < lines.count {
        let line = lines[i]
        i += 1
        if let rest = line.drop("diff --git ") {
            finish()
            draft = Draft(gitNames: gitNames(rest))
            continue
        }
        guard draft != nil else { continue }
        if line.drop("@@ ") != nil {
            guard var hunk = hunkHeader(line) else {
                // A header we can't read: keep the hunks so far and skip to the next file.
                finish()
                continue
            }
            // Int counters: a header near UInt32.max plus context lines must not trap.
            var oldNo = hunk.oldStart
            var newNo = hunk.newStart
            var oldLeft = hunk.oldLen
            var newLeft = hunk.newLen
            // The `\` marker for the hunk's last line comes after the counts run out.
            scan: while oldLeft > 0 || newLeft > 0 || (i < lines.count && lines[i].first == UInt8(ascii: "\\")) {
                // Look before taking, so a hunk cut short leaves the next file's header in place.
                guard i < lines.count else { break }
                let l = lines[i]
                let kind: Kind
                switch l.first {
                case UInt8(ascii: "+"): kind = .add
                case UInt8(ascii: "-"): kind = .del
                // `diff.suppressBlankEmpty` prints an empty context line with no space.
                case UInt8(ascii: " "), nil: kind = .context
                case UInt8(ascii: "\\"):
                    i += 1
                    if !hunk.lines.isEmpty { hunk.lines[hunk.lines.count - 1].noNewline = true }
                    continue
                default: break scan
                }
                i += 1
                let o = kind == .add ? nil : oldNo
                let n = kind == .del ? nil : newNo
                if o != nil {
                    oldNo += 1
                    oldLeft = max(oldLeft - 1, 0)
                }
                if n != nil {
                    newNo += 1
                    newLeft = max(newLeft - 1, 0)
                }
                hunk.lines.append(Line(kind: kind, oldNo: o, newNo: n, text: text(l.isEmpty ? l : l.dropFirst())))
            }
            draft?.hunks.append(hunk)
        } else if let p = line.drop("--- ") {
            draft?.minus = headerPath(p, "a/")
        } else if let p = line.drop("+++ ") {
            draft?.plus = headerPath(p, "b/")
        } else if let p = line.drop("rename from ") ?? line.drop("copy from ") {
            draft?.from = name(p)
        } else if let p = line.drop("rename to ") {
            draft?.to = name(p)
            draft?.status = .renamed
        } else if let p = line.drop("copy to ") {
            draft?.to = name(p)
            draft?.status = .copied
        } else if let m = line.drop("new file mode ") {
            draft?.newMode = text(m)
            draft?.status = .added
        } else if let m = line.drop("deleted file mode ") {
            draft?.oldMode = text(m)
            draft?.status = .deleted
        } else if let m = line.drop("old mode ") {
            draft?.oldMode = text(m)
        } else if let m = line.drop("new mode ") {
            draft?.newMode = text(m)
        } else if let rest = line.drop("index ") {
            let parts = rest.split(separator: UInt8(ascii: " "), maxSplits: 1)
            let blobs = parts.first ?? rest
            let blob = { (b: Bytes) in b.allSatisfy { $0 == UInt8(ascii: "0") } ? nil : text(b) }
            if let dots = blobs.firstRange(of: "..".utf8) {
                draft?.oldBlob = blob(blobs[..<dots.lowerBound])
                draft?.newBlob = blob(blobs[dots.upperBound...])
            }
            if parts.count > 1, draft?.newMode == nil { draft?.newMode = text(parts[1]) }
        } else if line.drop("Binary files ") != nil || text(line) == "GIT binary patch" {
            draft?.binary = true
        }
        // Anything else (similarity, dissimilarity, binary payload) carries nothing we use.
    }
    finish()
    return files
}

/// `@@ -a[,b] +c[,d] @@ section`. A missing count is 1. Rejects ranges that don't fit git's
/// 32-bit line numbers, as the Rust version did.
private func hunkHeader(_ line: Bytes) -> Hunk? {
    guard let rest = line.drop("@@ -") else { return nil }
    let (ranges, section): (Bytes, Bytes) =
        if let r = rest.firstRange(of: " @@".utf8) { (rest[..<r.lowerBound], rest[r.upperBound...]) } else {
            (rest, rest[rest.endIndex...])
        }
    guard let plus = ranges.firstRange(of: " +".utf8) else { return nil }
    func range(_ s: Bytes) -> (Int, Int)? {
        let num = { (b: Bytes) -> Int? in
            guard !b.isEmpty, b.count <= 10, b.allSatisfy({ $0 >= 48 && $0 <= 57 }), let v = Int(text(b)),
                v <= UInt32.max
            else { return nil }
            return v
        }
        let parts = s.split(separator: UInt8(ascii: ","), maxSplits: 1, omittingEmptySubsequences: false)
        guard let start = num(parts[0]), let len = parts.count > 1 ? num(parts[1]) : 1,
            start + len <= UInt32.max
        else { return nil }
        return (start, len)
    }
    guard let (os, ol) = range(ranges[..<plus.lowerBound]), let (ns, nl) = range(ranges[plus.upperBound...]) else {
        return nil
    }
    let sec = text(section).trimmingCharacters(in: .whitespacesAndNewlines)
    return Hunk(oldStart: os, oldLen: ol, newStart: ns, newLen: nl, section: sec)
}

/// A `---`/`+++` operand: `/dev/null` is no file. git appends a TAB after names with spaces,
/// outside the quotes, so it goes first.
private func headerPath(_ p: Bytes, _ prefix: String) -> String? {
    var p = p
    if p.last == UInt8(ascii: "\t") { p = p.dropLast() }
    if text(p) == "/dev/null" { return nil }
    let n = name(p)
    return n.hasPrefix(prefix) ? String(n.dropFirst(prefix.count)) : n
}

/// `a/P b/P` or `"a/P" "b/P"`. Without quotes the line is ambiguous when P has spaces, but both
/// names are the same unless it's a rename or copy, which carry their own `from`/`to` lines.
private func gitNames(_ rest: Bytes) -> (String, String)? {
    let old: String
    let new: String
    if rest.first == UInt8(ascii: "\"") {
        guard let (o, after) = unquote(rest), let a = after.drop(" ") else { return nil }
        old = o
        if a.first == UInt8(ascii: "\"") {
            guard let (n, _) = unquote(a) else { return nil }
            new = n
        } else {
            new = text(a)
        }
    } else {
        // "a/" P " b/" P
        guard rest.count >= 5 else { return nil }
        let half = (rest.count - 5) / 2
        let s = rest.startIndex
        old = text(rest[s..<s + half + 2])
        new = text(rest[(s + half + 3)...])
    }
    guard old.hasPrefix("a/"), new.hasPrefix("b/") else { return nil }
    return (String(old.dropFirst(2)), String(new.dropFirst(2)))
}

/// A name on a `rename from`-style line: C-quoted or raw.
private func name(_ p: Bytes) -> String {
    if p.first == UInt8(ascii: "\""), let (s, _) = unquote(p) { return s }
    return text(p)
}

/// Reads one C-quoted string from the start of `s` (git's `quote_c_style`): returns it and what
/// follows the closing quote. Octal escapes are raw bytes, decoded as UTF-8 at the end.
private func unquote(_ s: Bytes) -> (String, Bytes)? {
    guard s.first == UInt8(ascii: "\"") else { return nil }
    var bytes: [UInt8] = []
    var i = s.startIndex + 1
    func next() -> UInt8? {
        guard i < s.endIndex else { return nil }
        defer { i += 1 }
        return s[i]
    }
    while let b = next() {
        switch b {
        case UInt8(ascii: "\""): return (text(bytes[...]), s[i...])
        case UInt8(ascii: "\\"):
            guard let e = next() else { return nil }
            switch e {
            case UInt8(ascii: "a"): bytes.append(7)
            case UInt8(ascii: "b"): bytes.append(8)
            case UInt8(ascii: "t"): bytes.append(9)
            case UInt8(ascii: "n"): bytes.append(10)
            case UInt8(ascii: "v"): bytes.append(11)
            case UInt8(ascii: "f"): bytes.append(12)
            case UInt8(ascii: "r"): bytes.append(13)
            case UInt8(ascii: "0")...UInt8(ascii: "3"):
                let octal = UInt8(ascii: "0")...UInt8(ascii: "7")
                guard let x = next(), let y = next(), octal.contains(x), octal.contains(y) else { return nil }
                bytes.append((e - 48) * 64 + (x - 48) * 8 + (y - 48))
            default: bytes.append(e)  // \" and \\
            }
        default: bytes.append(b)
        }
    }
    return nil
}
