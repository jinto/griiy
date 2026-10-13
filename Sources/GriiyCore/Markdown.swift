// PR text on screen (F-PR-5): someone else's Markdown made into text we control, and line
// comments put on the diff rows they belong to (F-PR-4).
import Foundation

/// The only links griiy follows: https to a named host with no user in it, or mailto. Every link
/// in PR text goes through this. `%` in a host would read like another host (`a.example%40b.example`).
public func safeLink(_ url: URL) -> Bool {
    switch url.scheme?.lowercased() {
    case "https":
        url.host().map { !$0.isEmpty && !$0.contains("%") } == true && url.user() == nil && url.password() == nil
    case "mailto": true
    default: false
    }
}

/// An image griiy may fetch, and every redirect of one: a `safeLink` over https.
public func safeImage(_ url: URL) -> Bool { url.scheme?.lowercased() == "https" && safeLink(url) }

/// `source` as plain text with three attributes at most: `inlinePresentationIntent` (emphasis,
/// code), `link` (only `safeLink`s) and `imageURL` (an https image, on its `[image: alt]`
/// placeholder). Raw HTML stays literal characters, shown as code: nothing here is ever read as
/// HTML. Blocks become lines: paragraphs a blank line apart, `• ` and `1. ` list items, `▎ ` quotes,
/// table cells ` | `.
public func markdown(_ source: String) -> AttributedString {
    guard
        let parsed = try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible))
    else { return AttributedString(source) }
    var out = AttributedString()
    var previous: [PresentationIntent.IntentType]?
    for run in parsed.runs {
        var text = String(parsed[run.range].characters)
        var inline = run.inlinePresentationIntent ?? []
        let html = inline.contains(.blockHTML)
        // GitHub hides HTML comments; PR templates start with several.
        if html {
            text = text.replacing(/<!--[\s\S]*?-->/, with: "")
            if text.allSatisfy(\.isWhitespace) { continue }
        }
        // GitHub shows a newline in PR text as a line break.
        if inline.contains(.softBreak) { text = "\n" }
        // Outermost first. Block HTML has no intent: it is a block of its own.
        let blocks = run.presentationIntent?.components.reversed() ?? []
        let block = blocks.map(\.identity)
        if html || block != previous?.map(\.identity) {
            if let previous { out += AttributedString(gap(previous, blocks)) }
            out += AttributedString(prefix(previous ?? [], blocks))
            previous = html ? [] : Array(blocks)
        }
        // Code blocks and block HTML end in their own newline; the gap puts it back.
        if html || blocks.contains(where: { if case .codeBlock = $0.kind { true } else { false } }) {
            if text.hasSuffix("\n") { text.removeLast() }
            inline = .code
        }
        if inline.contains(.inlineHTML) { inline = .code }
        if blocks.contains(where: { if case .header = $0.kind { true } else { false } }) {
            inline.insert(.stronglyEmphasized)
        }
        var piece: AttributedString
        if let image = run.imageURL {
            // An empty alt comes back as U+FFFC.
            piece = AttributedString("[image: \(text.replacingOccurrences(of: "\u{FFFC}", with: ""))]")
            if safeImage(image) { piece.imageURL = image }
        } else {
            piece = AttributedString(text)
            if let link = run.link, safeLink(link) { piece.link = link }
        }
        if !inline.isEmpty { piece.inlinePresentationIntent = inline }
        out += piece
    }
    return out
}

/// What goes between the last block and the next: a line inside a list or table (` | ` between
/// cells of a row), else a blank line.
private func gap(_ a: [PresentationIntent.IntentType], _ b: [PresentationIntent.IntentType]) -> String {
    let shared = zip(a, b).prefix { $0.identity == $1.identity }.map { $0.0.kind }
    switch shared.last {
    case .tableHeaderRow, .tableRow: return " | "
    default: break
    }
    for kind in shared {
        switch kind {
        case .table, .orderedList, .unorderedList: return "\n"
        default: continue
        }
    }
    return "\n\n"
}

/// The start of block `b`'s first line: indent and bullet for list items, a bar per quote.
private func prefix(_ a: [PresentationIntent.IntentType], _ b: [PresentationIntent.IntentType]) -> String {
    var s = ""
    var ordered = false
    let old = Set(a.map(\.identity))
    for kind in b {
        switch kind.kind {
        case .blockQuote: s += "▎ "
        case .orderedList: ordered = true
        case .unorderedList: ordered = false
        case .listItem(let n):
            // A later paragraph of the same item only lines up under it.
            s += old.contains(kind.identity) ? "  " : ordered ? "\(n). " : "• "
        default: continue
        }
    }
    return s
}

/// Threads that have a place in `file`, by row index in `file.rows`: each on its last line, the
/// row GitHub shows it under. The others (outdated, file comments, lines outside the diff) aren't in it.
public func threadRows(_ threads: [ReviewThread], in file: File) -> [Int: [ReviewThread]] {
    var base: [Int: Int] = [:]
    var head: [Int: Int] = [:]
    var r = 1
    for h in file.hunks {
        r += 1
        for l in h.lines {
            if let n = l.oldNo { base[n] = r }
            if let n = l.newNo { head[n] = r }
            r += 1
        }
    }
    var rows: [Int: [ReviewThread]] = [:]
    for t in threads where t.path == file.path {
        guard let last = t.lines.map({ $0.upperBound - 1 }), let row = (t.side == .base ? base : head)[last] else {
            continue
        }
        rows[row, default: []].append(t)
    }
    return rows
}
