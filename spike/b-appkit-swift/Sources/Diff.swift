// The diff: one view-based NSTableView of fixed 18pt rows. Rows come from the core in chunks
// (griiy_rows, JSON), fetched synchronously on the main thread the first time a row is asked for.
import AppKit

struct FileInfo { let path: String, status: String, add: Int, del: Int, rows: Int, oldPath: String? }

enum Row {
    case header(Int)
    case hunk(String)
    case note(String)
    case line(kind: Character, old: Int?, new: Int?, text: String, noNewline: Bool)
}

let H: CGFloat = 18
let CHUNK = 1000
let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
let monoBold = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
let ch = ("0" as NSString).size(withAttributes: [.font: mono]).width
// ponytail: a row draws (and the width counts) at most this many chars; a minified MB-long line
// would otherwise cost a huge CTLine per frame. Upgrade: draw only the visible slice.
let MAX_CHARS = 2000
let paragraph: NSParagraphStyle = {
    let p = NSMutableParagraphStyle()
    p.tabStops = []; p.defaultTabInterval = 4 * ch; p.lineBreakMode = .byClipping
    return p
}()

final class DiffTable: NSTableView {
    weak var ctl: DiffController?
    // NSTableView tracks the drag (with auto-scroll) inside mouseDown; it returns on mouse-up.
    override func mouseDown(with e: NSEvent) {
        super.mouseDown(with: e)
        ctl?.reportSelection()
    }
    @objc func copy(_ sender: Any?) { ctl?.copySelection() }
}

final class RowView: NSTableRowView {
    var bg: NSColor?
    var text = NSAttributedString()
    var x: CGFloat = 0
    var stats: NSAttributedString?
    var plain = ""
    static var made = 0

    override var isFlipped: Bool { true }
    override func drawBackground(in r: NSRect) {
        (bg ?? Palette.bg).setFill(); r.fill()
    }
    override func drawSelection(in r: NSRect) {
        NSColor.selectedTextBackgroundColor.setFill(); r.fill()
    }
    override func draw(_ r: NSRect) {
        super.draw(r)
        text.draw(at: NSPoint(x: x, y: 1))
        if let stats, let clip = enclosingScrollView?.documentVisibleRect {
            stats.draw(at: NSPoint(x: min(bounds.maxX, clip.maxX) - stats.size().width - 12, y: 1))
        }
    }
    // P-AX: one static text per row carrying its text (rows draw themselves, so no subviews).
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
    var review: OpaquePointer?
    var files: [FileInfo] = []
    var start: [Int] = []
    var total = 0
    var gitMs = 0
    var cache: [Int: [Row]] = [:] // key: file << 32 | chunk
    var order: [Int] = []
    var widest: CGFloat = 0

    override init() {
        super.init()
        let col = NSTableColumn(identifier: .init("d"))
        col.resizingMask = []
        table.addTableColumn(col)
        table.headerView = nil
        table.style = .plain
        table.intercellSpacing = .zero
        table.rowHeight = H
        table.usesAutomaticRowHeights = false
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.allowsMultipleSelection = true
        table.backgroundColor = Palette.bg
        table.ctl = self
        table.dataSource = self
        table.delegate = self
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scroll, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.fitWidth() }
        }
    }

    func load(_ review: OpaquePointer, _ sum: [String: Any]) {
        self.review = review
        gitMs = sum["gitMs"] as? Int ?? 0
        for case let f as [Any] in sum["files"] as? [Any] ?? [] {
            files.append(FileInfo(path: f[0] as? String ?? "", status: f[1] as? String ?? "", add: f[2] as? Int ?? 0,
                                  del: f[3] as? Int ?? 0, rows: f[4] as? Int ?? 1, oldPath: f[5] as? String))
            start.append(total); total += files.last!.rows
            grow(chars: files.last!.path.utf8.count + (files.last!.oldPath?.utf8.count ?? 0) + 20)
        }
        table.reloadData()
    }

    func grow(chars: Int) {
        let w = 12 * ch + 8 + CGFloat(min(chars, MAX_CHARS)) * ch + 24
        if w > widest { widest = w; fitWidth() }
    }

    func fitWidth() {
        let w = max(widest, scroll.contentSize.width)
        if let col = table.tableColumns.first, col.width != w { col.width = w }
    }

    /// Index of the file holding global row r.
    func fileAt(_ r: Int) -> Int {
        var lo = 0, hi = files.count - 1
        while lo < hi { let mid = (lo + hi + 1) / 2; if start[mid] <= r { lo = mid } else { hi = mid - 1 } }
        return lo
    }

    func row(_ r: Int) -> Row {
        let f = fileAt(r), k = r - start[f]
        if k == 0 { return .header(f) }
        let c = k / CHUNK, key = f << 32 | c
        if cache[key] == nil { cache[key] = fetch(f, c) }
        let rows = cache[key]!
        return k % CHUNK < rows.count ? rows[k % CHUNK] : .note("")
    }

    func fetch(_ f: Int, _ c: Int) -> [Row] {
        // ponytail: FIFO eviction by chunk count; LRU if refetching ever shows up.
        order.append(f << 32 | c)
        if order.count > 100 { cache[order.removeFirst()] = nil }
        let s = take(griiy_rows(review, f, c * CHUNK, CHUNK)) ?? "[]"
        var longest = 0
        let rows = (json(s) as? [[Any]] ?? []).map { x -> Row in
            switch x[0] as? String {
            case "f": return .header(f)
            case "h": return .hunk(x[1] as? String ?? "")
            case "n": return .note(x[1] as? String ?? "")
            case let k:
                let text = x[3] as? String ?? ""
                longest = max(longest, text.utf8.count)
                return .line(kind: k?.first ?? " ", old: x[1] as? Int, new: x[2] as? Int, text: text, noNewline: x.count > 4)
            }
        }
        grow(chars: longest)
        return rows
    }

    func numberOfRows(in t: NSTableView) -> Int { total }
    func tableView(_ t: NSTableView, viewFor c: NSTableColumn?, row: Int) -> NSView? { nil }

    func tableView(_ t: NSTableView, rowViewForRow r: Int) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("row")
        let v = t.makeView(withIdentifier: id, owner: nil) as? RowView ?? {
            let v = RowView(); v.identifier = id; RowView.made += 1; return v
        }()
        configure(v, row(r))
        return v
    }

    func configure(_ v: RowView, _ row: Row) {
        let a: [NSAttributedString.Key: Any] = [.font: mono, .foregroundColor: Palette.fg, .paragraphStyle: paragraph]
        let muted = a.merging([.foregroundColor: Palette.mut]) { $1 }
        let s = NSMutableAttributedString()
        v.stats = nil; v.x = 12
        switch row {
        case .header(let i):
            let f = files[i]
            v.bg = Palette.side
            let letter = ["added": "A", "deleted": "D", "modified": "M", "renamed": "R", "copied": "C"][f.status] ?? "?"
            let color = f.status == "added" ? Palette.addText : f.status == "deleted" ? Palette.delText : Palette.mut
            s.append(NSAttributedString(string: letter + " ", attributes: a.merging([.foregroundColor: color]) { $1 }))
            if let o = f.oldPath { s.append(NSAttributedString(string: o + " → ", attributes: muted)) }
            s.append(NSAttributedString(string: f.path, attributes: a.merging([.font: monoBold]) { $1 }))
            let st = NSMutableAttributedString(string: "+\(f.add)", attributes: a.merging([.foregroundColor: Palette.addText]) { $1 })
            st.append(NSAttributedString(string: " -\(f.del)", attributes: a.merging([.foregroundColor: Palette.delText]) { $1 }))
            v.stats = st
            v.plain = (f.oldPath.map { $0 + " → " } ?? "") + f.path
        case .hunk(let h):
            v.bg = Palette.hunk
            s.append(NSAttributedString(string: h, attributes: muted)); v.plain = h
        case .note(let n):
            v.bg = nil
            s.append(NSAttributedString(string: n, attributes: muted.merging([.obliqueness: 0.2]) { $1 })); v.plain = n
        case let .line(kind, old, new, text, nn):
            v.bg = kind == "+" ? Palette.add : kind == "-" ? Palette.del : nil
            v.x = 0
            let g = { (n: Int?) in String(repeating: " ", count: max(0, 6 - String(n.map(String.init) ?? "").count)) + (n.map(String.init) ?? "") }
            s.append(NSAttributedString(string: g(old) + g(new) + " ", attributes: muted))
            let clipped = text.count > MAX_CHARS ? String(text.prefix(MAX_CHARS)) : text
            s.append(NSAttributedString(string: clipped.replacingOccurrences(of: "\r", with: ""), attributes: a))
            if nn { s.append(NSAttributedString(string: "  \\ no newline at end of file", attributes: muted)) }
            v.plain = text
        }
        v.text = s
        v.needsDisplay = true
    }

    func liveRowViews() -> Int { table.subviews.filter { $0 is RowView && !$0.isHidden }.count }

    func scrollTo(row r: Int) {
        let clip = scroll.contentView
        let maxY = max(0, table.frame.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: min(max(0, CGFloat(r) * H), maxY)))
        scroll.reflectScrolledClipView(clip)
    }
    func scrollTo(file f: Int) { if f < start.count { scrollTo(row: start[f]) } }

    /// P-FOCUS keys: j / k jump to the next / previous file header.
    func jumpFile(_ d: Int) {
        guard !files.isEmpty else { return }
        let top = Int((scroll.contentView.bounds.minY / H).rounded()), cur = fileAt(top)
        let to = d > 0 ? cur + 1 : (top > start[cur] ? cur : cur - 1)
        scrollTo(file: min(max(0, to), files.count - 1))
    }

    // ---- P-SEL / P-COPY ----
    func reportSelection() {
        let sel = table.selectedRowIndexes
        guard sel.count > 1, let first = sel.first else { return }
        let f = fileAt(first)
        let lines = sel.filter { fileAt($0) == f }.compactMap { r -> (Character, Int?, Int?)? in
            if case let .line(k, o, n, _, _) = row(r) { return (k, o, n) }
            return nil
        }
        guard !lines.isEmpty else { return }
        let base = lines.allSatisfy { $0.0 == "-" }
        let nums = lines.compactMap { base ? $0.1 : $0.2 }
        FileHandle.standardError.write(Data("Selection { path: \(files[f].path), side: \(base ? "Base" : "Head"), start: \(nums.min() ?? 0), end: \(nums.max() ?? 0) }\n".utf8))
    }

    func copySelection() {
        let text = table.selectedRowIndexes.map { r -> String in
            switch row(r) {
            case .header(let f): return files[f].path
            case .hunk(let s), .note(let s): return s
            case .line(_, _, _, let t, _): return t
            }
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // ---- Bench auto-scroll (BRIEF: 10 jumps × 60 frames of half a screen) ----
    var bench: (k: Int, n: Int, prev: Double?, gaps: [Double], viewsMax: Int)?
    var benchLink: CADisplayLink?

    func startBench() {
        bench = (0, 0, nil, [], 0)
        jump(0)
        benchLink = table.displayLink(target: self, selector: #selector(step(_:)))
        benchLink?.add(to: .main, forMode: .common)
    }

    func jump(_ k: Int) {
        let maxY = max(0, table.frame.height - scroll.contentView.bounds.height)
        let clip = scroll.contentView
        clip.scroll(to: NSPoint(x: 0, y: maxY * CGFloat(k) / 10)); scroll.reflectScrolledClipView(clip)
    }

    @objc func step(_ link: CADisplayLink) {
        guard var b = bench else { return }
        let ts = link.timestamp * 1000
        if let p = b.prev, b.n > 1 { b.gaps.append(ts - p) }
        b.prev = ts
        b.viewsMax = max(b.viewsMax, liveRowViews())
        b.n += 1
        if b.n > 60 {
            b.k += 1; b.n = 0; b.prev = nil
            if b.k == 10 {
                link.invalidate(); bench = nil
                let g = b.gaps.sorted()
                let median = g.isEmpty ? 0 : g[g.count / 2]
                mark("\"scroll\":{\"frames\":\(g.count),\"long\":\(g.filter { $0 > 50 }.count),\"max\":\(Int((g.last ?? 0).rounded())),\"median\":\(Int(median.rounded())),\"blank\":0,\"viewsMax\":\(b.viewsMax),\"rowViewsMade\":\(RowView.made)}")
                return
            }
            bench = b
            jump(b.k)
            return
        }
        bench = b
        let clip = scroll.contentView
        clip.scroll(to: NSPoint(x: 0, y: min(clip.bounds.minY + clip.bounds.height / 2, max(0, table.frame.height - clip.bounds.height))))
        scroll.reflectScrolledClipView(clip)
    }
}
