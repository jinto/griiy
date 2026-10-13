// What a question sends along (F-AI-2), each item under the ID answers cite it by (F-AI-3).

/// One item, its ID without the brackets of a citation.
public struct Evidence: Equatable, Sendable {
    /// `code:<path>:L<a>-<b>@<base|head>`, …
    public var id: String
    public var text: String
}

extension Review {
    /// Evidence ① for `lines` of `side` selected in either view of `path`: built from the whole
    /// file, so the diff and the whole-file view give the same evidence when their spans agree.
    /// Blocking (git).
    public func code(_ path: String, _ side: Side, _ lines: Range<Int>, cancel: Cancel? = nil) throws(GitError)
        -> (diff: String, items: [Evidence])
    {
        try whole(path, cancel: cancel).code(side, lines)
    }
}

extension File {
    /// From a `whole` file, which has every line of both sides: the changed lines in the span as
    /// `-`/`+` text (the question, not an item), and each side's lines ±40 around it. A side with
    /// no lines there is left out, and so is base when its text is head's.
    func code(_ side: Side, _ lines: Range<Int>) -> (diff: String, items: [Evidence]) {
        let span = span(side, lines)
        let rows = hunks.flatMap(\.lines)
        var diff = ""
        for l in rows where l.kind != .context {
            if let o = l.oldNo, span.base.contains(o) { diff += "-\(l.text)\n" }
            if let n = l.newNo, span.head.contains(n) { diff += "+\(l.text)\n" }
        }
        // span stops at UInt32, so ±40 can't overflow.
        func near(_ r: Range<Int>, _ no: KeyPath<Line, Int?>) -> [(Int, String)] {
            let wide = r.lowerBound - 40..<r.upperBound + 40
            return rows.compactMap { l in l[keyPath: no].flatMap { wide.contains($0) ? ($0, l.text) : nil } }
        }
        func item(_ ls: [(Int, String)], _ path: String, _ side: String) -> Evidence? {
            guard let a = ls.first?.0, let b = ls.last?.0 else { return nil }
            return Evidence(id: "code:\(path):L\(a)-\(b)@\(side)", text: ls.map { "\($0)\t\($1)\n" }.joined())
        }
        let base = near(span.base, \.oldNo)
        let head = near(span.head, \.newNo)
        let same = base.map(\.1) == head.map(\.1)
        let items = [same ? nil : item(base, oldPath ?? path, "base"), item(head, path, "head")]
        return (diff, items.compactMap { $0 })
    }
}
