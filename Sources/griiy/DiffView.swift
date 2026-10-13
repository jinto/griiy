// The diff: one view-based NSTableView of fixed 18pt rows (F-DV-4). NSTableView only creates views
// for the rows on screen and reuses them, so a 150k-row diff costs about 40 row views. Rows come
// straight from the parsed files (`File.rows(from:n:)`); nothing is copied or serialized.
import AppKit
import GriiyCore

let rowHeight: CGFloat = 18
let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
let monoBold = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
let charWidth = ("0" as NSString).size(withAttributes: [.font: mono]).width
// ponytail: a row draws at most this many characters; a minified MB-long line would otherwise
// cost a huge CTLine per frame. Upgrade: draw only the visible slice.
let maxChars = 2000
let paragraph: NSParagraphStyle = {
    let p = NSMutableParagraphStyle()
    p.tabStops = []
    p.defaultTabInterval = 4 * charWidth
    p.lineBreakMode = .byClipping
    return p
}()

final class DiffTable: NSTableView {
    weak var controller: DiffController?
    @objc func copy(_ sender: Any?) { controller?.copySelection() }
}

/// Draws its row itself: one attributed string, no subviews.
final class RowView: NSTableRowView {
    var background: NSColor?
    var text = NSAttributedString()
    var indent: CGFloat = 0
    var stats: NSAttributedString?
    var plain = ""

    override var isFlipped: Bool { true }

    override func drawBackground(in rect: NSRect) {
        (background ?? Palette.bg).setFill()
        rect.fill()
    }

    override func drawSelection(in rect: NSRect) {
        NSColor.selectedTextBackgroundColor.setFill()
        rect.fill()
    }

    override func draw(_ rect: NSRect) {
        super.draw(rect)
        text.draw(at: NSPoint(x: indent, y: 1))
        // The file's +/- stays at the right edge of the visible area, however wide the table is.
        if let stats, let visible = enclosingScrollView?.documentVisibleRect {
            stats.draw(at: NSPoint(x: min(bounds.maxX, visible.maxX) - stats.size().width - 12, y: 1))
        }
    }

    // VoiceOver: the row's text, since it has no subviews to read.
    override func accessibilityChildren() -> [Any]? {
        let e = NSAccessibilityElement()
        e.setAccessibilityRole(.staticText)
        e.setAccessibilityValue(plain)
        e.setAccessibilityParent(self)
        e.setAccessibilityFrameInParentSpace(bounds)
        return [e]
    }
}

final class DiffController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let table = DiffTable()
    let scroll = NSScrollView()
    private(set) var files: [File] = []
    /// First global row of each file.
    private var start: [Int] = []
    private(set) var total = 0
    private var width: CGFloat = 0

    override init() {
        super.init()
        let column = NSTableColumn(identifier: .init("diff"))
        column.resizingMask = []
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.intercellSpacing = .zero
        table.rowHeight = rowHeight
        table.usesAutomaticRowHeights = false
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.allowsMultipleSelection = true
        table.backgroundColor = Palette.bg
        table.controller = self
        table.dataSource = self
        table.delegate = self
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: scroll, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.fitWidth() }
        }
    }

    func load(_ files: [File]) {
        self.files = files
        start = []
        total = 0
        var longest = 0
        for f in files {
            start.append(total)
            total += f.rowCount
            longest = max(longest, f.path.utf8.count + (f.oldPath?.utf8.count ?? 0) + 20)
            for h in f.hunks {
                for l in h.lines { longest = max(longest, l.text.utf8.count) }
            }
        }
        // Gutters (2 × 6ch + space) plus the longest line, capped like the drawing.
        width = 13 * charWidth + CGFloat(min(longest, maxChars)) * charWidth + 24
        fitWidth()
        table.reloadData()
    }

    private func fitWidth() {
        let w = max(width, scroll.contentSize.width)
        if let column = table.tableColumns.first, column.width != w { column.width = w }
    }

    /// Index of the file holding global row r.
    func fileAt(_ r: Int) -> Int {
        var lo = 0
        var hi = files.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if start[mid] <= r { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    private func row(_ r: Int) -> (file: Int, row: Row?) {
        let f = fileAt(r)
        return (f, files[f].rows(from: r - start[f], n: 1).first)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { total }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? { nil }

    func tableView(_ tableView: NSTableView, rowViewForRow r: Int) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("row")
        let view = tableView.makeView(withIdentifier: id, owner: nil) as? RowView ?? RowView()
        view.identifier = id
        let (f, row) = row(r)
        configure(view, file: files[f], row ?? .note(""))
        return view
    }

    private func configure(_ v: RowView, file f: File, _ row: Row) {
        let plain: [NSAttributedString.Key: Any] = [
            .font: mono, .foregroundColor: Palette.fg, .paragraphStyle: paragraph,
        ]
        let muted = plain.merging([.foregroundColor: Palette.mut]) { $1 }
        let s = NSMutableAttributedString()
        v.stats = nil
        v.indent = 12
        switch row {
        case .fileHeader:
            v.background = Palette.side
            let letter = f.status == .unchanged ? " " : f.status.rawValue.prefix(1).uppercased()  // A D M R C
            let color = f.status == .added ? Palette.addText : f.status == .deleted ? Palette.delText : Palette.mut
            s.append(
                NSAttributedString(string: letter + " ", attributes: plain.merging([.foregroundColor: color]) { $1 }))
            if let old = f.oldPath { s.append(NSAttributedString(string: old + " → ", attributes: muted)) }
            s.append(NSAttributedString(string: f.path, attributes: plain.merging([.font: monoBold]) { $1 }))
            let (add, del) = f.stats
            let st = NSMutableAttributedString(
                string: "+\(add)", attributes: plain.merging([.foregroundColor: Palette.addText]) { $1 })
            st.append(
                NSAttributedString(
                    string: " -\(del)", attributes: plain.merging([.foregroundColor: Palette.delText]) { $1 }))
            if f.status != .unchanged { v.stats = st }
            v.plain = (f.oldPath.map { $0 + " → " } ?? "") + f.path
        case .hunk(let h):
            v.background = Palette.hunk
            s.append(NSAttributedString(string: h, attributes: muted))
            v.plain = h
        case .note(let n):
            v.background = nil
            s.append(NSAttributedString(string: n, attributes: muted.merging([.obliqueness: 0.2]) { $1 }))
            v.plain = n
        case .line(let l):
            v.background = l.kind == .add ? Palette.add : l.kind == .del ? Palette.del : nil
            v.indent = 0
            let gutter = { (n: Int?) in
                let s = n.map(String.init) ?? ""
                return String(repeating: " ", count: max(0, 6 - s.count)) + s
            }
            s.append(NSAttributedString(string: gutter(l.oldNo) + gutter(l.newNo) + " ", attributes: muted))
            let text = l.text.utf8.count > maxChars ? String(l.text.prefix(maxChars)) : l.text
            s.append(NSAttributedString(string: text.replacingOccurrences(of: "\r", with: ""), attributes: plain))
            if l.noNewline { s.append(NSAttributedString(string: "  \\ no newline at end of file", attributes: muted)) }
            v.plain = l.text
        }
        v.text = s
        v.needsDisplay = true
    }

    func liveRowViews() -> Int { table.subviews.filter { $0 is RowView && !$0.isHidden }.count }

    func scrollTo(row r: Int) {
        let clip = scroll.contentView
        let maxY = max(0, table.frame.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: min(max(0, CGFloat(r) * rowHeight), maxY)))
        scroll.reflectScrolledClipView(clip)
    }

    func scrollTo(file f: Int) {
        if f < start.count { scrollTo(row: start[f]) }
    }

    /// ⌘C: the selected rows' text, without gutters.
    func copySelection() {
        let text = table.selectedRowIndexes.map { r -> String in
            let (f, row) = row(r)
            switch row {
            case .fileHeader, nil: return files[f].path
            case .hunk(let s), .note(let s): return s
            case .line(let l): return l.text
            }
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // ---- Bench auto-scroll: 10 jumps × 60 frames of half a screen (docs/SPIKE-native-ui.md) ----
    private struct Bench {
        var k = 0, n = 0, previous: Double?, gaps: [Double] = [], viewsMax = 0
    }
    private var bench: Bench?

    func startBench() {
        bench = Bench()
        jump(0)
        table.displayLink(target: self, selector: #selector(step(_:))).add(to: .main, forMode: .common)
    }

    private func jump(_ k: Int) {
        let clip = scroll.contentView
        let maxY = max(0, table.frame.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: 0, y: maxY * CGFloat(k) / 10))
        scroll.reflectScrolledClipView(clip)
    }

    @objc private func step(_ link: CADisplayLink) {
        guard var b = bench else { return link.invalidate() }
        let ts = link.timestamp * 1000
        // The first gaps after a jump are the jump itself, not scrolling.
        if let p = b.previous, b.n > 1 { b.gaps.append(ts - p) }
        b.previous = ts
        b.viewsMax = max(b.viewsMax, liveRowViews())
        b.n += 1
        if b.n > 60 {
            (b.k, b.n, b.previous) = (b.k + 1, 0, nil)
            if b.k == 10 {
                link.invalidate()
                bench = nil
                let g = b.gaps.sorted()
                let median = g.isEmpty ? 0 : g[g.count / 2]
                mark(
                    "\"scroll\":{\"frames\":\(g.count),\"long\":\(g.filter { $0 > 50 }.count),\"max\":\(Int((g.last ?? 0).rounded())),\"median\":\(Int(median.rounded())),\"blank\":0,\"viewsMax\":\(b.viewsMax)}"
                )
                return
            }
            bench = b
            jump(b.k)
            return
        }
        bench = b
        let clip = scroll.contentView
        let maxY = max(0, table.frame.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: 0, y: min(clip.bounds.minY + clip.bounds.height / 2, maxY)))
        scroll.reflectScrolledClipView(clip)
    }
}
