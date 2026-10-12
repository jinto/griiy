// P-MD: PR markdown by the F-PR-5 rules. Foundation parses (raw HTML stays literal text, nothing
// is fetched); this file adds block breaks, styling, tables, checkboxes and the link/image policy.
import AppKit

let safeSchemes: Set<String> = ["https", "mailto"]

func renderMarkdown(_ src: String) -> NSAttributedString {
    let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
    guard let md = try? AttributedString(markdown: src, options: opts) else { return NSAttributedString(string: src) }
    let body = NSFont.systemFont(ofSize: 13), out = NSMutableAttributedString()
    var lastBlock: Int?, lastItem: Int?, lastAttrs: [NSAttributedString.Key: Any] = [:]
    var tables: [Int: NSTextTable] = [:], rows: [Int: (id: Int, n: Int)] = [:]

    for run in md.runs {
        var text = String(md[run.range].characters)
        let comps = run.presentationIntent?.components ?? [] // innermost first
        let p = NSMutableParagraphStyle()
        p.paragraphSpacing = 6
        var a: [NSAttributedString.Key: Any] = [.font: body, .foregroundColor: Palette.fg]
        var depth = 0, item: (id: Int, prefix: String)?, ordered = false
        for c in comps.reversed() { // outermost first
            switch c.kind {
            case .header(let level):
                a[.font] = NSFont.boldSystemFont(ofSize: [0, 22, 17, 15][min(level, 3)])
            case .codeBlock:
                a[.font] = mono; a[.backgroundColor] = Palette.side
                if text.hasSuffix("\n") { text.removeLast() }
            case .blockQuote:
                p.headIndent += 16; p.firstLineHeadIndent += 16; a[.foregroundColor] = Palette.mut
            case .orderedList: ordered = true; depth += 1
            case .unorderedList: ordered = false; depth += 1
            case .listItem(let n):
                item = (c.identity, ordered ? "\(n). " : "• ")
                p.headIndent = CGFloat(depth) * 18; p.firstLineHeadIndent = CGFloat(depth) * 18 - 12
            case .table(let cols):
                if tables[c.identity] == nil {
                    let t = NSTextTable(); t.numberOfColumns = cols.count; t.collapsesBorders = true
                    tables[c.identity] = t
                }
            case .tableHeaderRow, .tableRow:
                let t = comps.first { if case .table = $0.kind { return true }; return false }!.identity
                if rows[t]?.id != c.identity { rows[t] = (c.identity, (rows[t]?.n ?? -1) + 1) }
                if case .tableHeaderRow = c.kind { a[.font] = NSFont.boldSystemFont(ofSize: 13) }
            case .tableCell(let col):
                let t = comps.first { if case .table = $0.kind { return true }; return false }!.identity
                let cell = NSTextTableBlock(table: tables[t]!, startingRow: rows[t]!.n, rowSpan: 1, startingColumn: col, columnSpan: 1)
                cell.setWidth(1, type: .absoluteValueType, for: .border); cell.setBorderColor(.separatorColor)
                cell.setWidth(4, type: .absoluteValueType, for: .padding)
                p.textBlocks = [cell]; p.paragraphSpacing = 0
            case .thematicBreak: text = "―――――"
            default: break
            }
        }
        if let i = run.inlinePresentationIntent {
            var traits: NSFontDescriptor.SymbolicTraits = []
            if i.contains(.stronglyEmphasized) { traits.insert(.bold) }
            if i.contains(.emphasized) { traits.insert(.italic) }
            if !traits.isEmpty, let f = a[.font] as? NSFont {
                a[.font] = NSFont(descriptor: f.fontDescriptor.withSymbolicTraits(traits), size: f.pointSize) ?? f
            }
            if i.contains(.code) { a[.font] = mono; a[.backgroundColor] = Palette.side }
            if i.contains(.strikethrough) { a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        }
        // Links: only https/mailto stay clickable; others render as plain text.
        if let url = run.link {
            if safeSchemes.contains(url.scheme?.lowercased() ?? "") { a[.link] = url } else { a[.foregroundColor] = Palette.mut }
        }
        a[.paragraphStyle] = p
        // Foundation emits no separators between blocks: break when the innermost block changes.
        let block = comps.first?.identity
        if let lastBlock, block != lastBlock { out.append(NSAttributedString(string: "\n", attributes: lastAttrs)) }
        if block != lastBlock, let item, item.id != lastItem {
            lastItem = item.id
            var prefix = item.prefix
            // GFM task lists aren't in Foundation's parser: "[x] " arrives as text.
            for (box, mark) in [("[x] ", "☑ "), ("[X] ", "☑ "), ("[ ] ", "☐ ")] where text.hasPrefix(box) {
                prefix = mark; text.removeFirst(box.count)
            }
            out.append(NSAttributedString(string: prefix, attributes: a.filter { $0.key != .link }))
        }
        lastBlock = block; lastAttrs = a.filter { $0.key != .link }
        // External images are never loaded: alt text plus a "show image" affordance.
        if let img = run.imageURL {
            out.append(NSAttributedString(string: "🖼 \(text) ", attributes: a.merging([.foregroundColor: Palette.mut]) { $1 }))
            var show = a; show[.link] = "griiy-show-image:" + img.absoluteString
            out.append(NSAttributedString(string: "[show image]", attributes: show))
            continue
        }
        out.append(NSAttributedString(string: text, attributes: a))
    }
    return out
}

final class MarkdownDelegate: NSObject, NSTextViewDelegate {
    func textView(_ v: NSTextView, clickedOnLink link: Any, at i: Int) -> Bool {
        let s = (link as? URL)?.absoluteString ?? link as? String ?? ""
        if let url = URL(string: s), safeSchemes.contains(url.scheme?.lowercased() ?? "") {
            NSWorkspace.shared.open(url)
        } else if s.hasPrefix("griiy-show-image:") {
            // ponytail: affordance only; the real app would fetch on this explicit click.
            FileHandle.standardError.write(Data("show image requested: \(s.dropFirst(17))\n".utf8))
        }
        return true // never let AppKit open anything else
    }
}
let mdDelegate = MarkdownDelegate()

func markdownWindow() -> NSWindow {
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let path = ProcessInfo.processInfo.environment["GRIIY_FIXTURE"]
        ?? exe.deletingLastPathComponent().appendingPathComponent("../../fixture.md").path
    let src = (try? String(contentsOfFile: path, encoding: .utf8)) ?? "Could not read \(path)"
    let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 720), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    w.title = "PR description (P-MD)"
    w.isReleasedWhenClosed = false
    let scroll = NSTextView.scrollableTextView() // replaced below by a TextKit 1 view (NSTextTable needs it)
    let tv = NSTextView(usingTextLayoutManager: false)
    tv.frame = NSRect(x: 0, y: 0, width: 640, height: 720)
    tv.autoresizingMask = [.width]
    tv.isEditable = false; tv.isAutomaticLinkDetectionEnabled = false
    tv.textContainerInset = NSSize(width: 16, height: 16)
    tv.delegate = mdDelegate
    tv.textStorage?.setAttributedString(renderMarkdown(src))
    scroll.documentView = tv
    w.contentView = scroll
    w.center(); w.setFrameOrigin(NSPoint(x: w.frame.minX + 200, y: w.frame.minY))
    w.makeKeyAndOrderFront(nil)
    return w
}
