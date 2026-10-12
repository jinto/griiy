// File tree: tracked ∪ changed paths in an NSOutlineView. Dirs holding a change start expanded,
// single-child dir chains collapse into one "a/b/c" node.
import AppKit

final class Node {
    var name: String
    var dirs: [String: Node] = [:]
    var files: [String] = []
    var kids: [Node] = []
    var file: Int? // changed-file index
    var hot = false
    let isDir: Bool
    init(_ name: String, dir: Bool) { self.name = name; isDir = dir }
}

final class TreeCell: NSTableCellView {
    let name = NSTextField(labelWithString: ""), stats = NSTextField(labelWithString: "")
    override init(frame: NSRect) {
        super.init(frame: frame)
        name.lineBreakMode = .byTruncatingTail
        [name, stats].forEach { $0.font = .systemFont(ofSize: 13); addSubview($0) }
        textField = name
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        stats.sizeToFit()
        let w = stats.frame.width
        stats.frame = NSRect(x: bounds.width - w - 4, y: (bounds.height - stats.frame.height) / 2, width: w, height: stats.frame.height)
        name.frame = NSRect(x: 0, y: (bounds.height - 17) / 2, width: bounds.width - w - 8, height: 17)
    }
}

final class TreeController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let outline = NSOutlineView()
    let scroll = NSScrollView()
    var root = Node("", dir: true)
    var files: [FileInfo] = []
    var summary: [String: Any]?
    var onPick: (Int) -> Void = { _ in }

    override init() {
        super.init()
        let col = NSTableColumn(identifier: .init("t"))
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.headerView = nil
        outline.style = .sourceList
        outline.backgroundColor = Palette.side
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.dataSource = self
        outline.delegate = self
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
    }

    /// Builds and shows the tree; returns the number of paths in it.
    func fill(_ files: [FileInfo]) -> Int {
        self.files = files
        let changed = Dictionary(files.enumerated().map { ($1.path, $0) }, uniquingKeysWith: { a, _ in a })
        var all = Set((summary?["tracked"] as? String ?? "").split(separator: "\n").map(String.init))
        all.formUnion(changed.keys)
        for p in all {
            var n = root
            let parts = p.split(separator: "/", omittingEmptySubsequences: false)
            for d in parts.dropLast() {
                let k = String(d)
                if n.dirs[k] == nil { n.dirs[k] = Node(k, dir: true) }
                n = n.dirs[k]!
                if changed[p] != nil { n.hot = true }
            }
            n.files.append(p)
        }
        finish(root, changed)
        outline.reloadData()
        expandHot(nil)
        return all.count
    }

    func finish(_ n: Node, _ changed: [String: Int]) {
        var dirs: [Node] = []
        for (_, var c) in n.dirs.sorted(by: { $0.key < $1.key }) {
            let name = c.name
            var full = name
            while c.files.isEmpty && c.dirs.count == 1 { c = c.dirs.first!.value; full += "/" + c.name }
            c.name = full
            finish(c, changed)
            dirs.append(c)
        }
        let leaves = n.files.sorted().map { p -> Node in
            let l = Node(String(p.split(separator: "/").last ?? ""), dir: false)
            l.file = changed[p]
            return l
        }
        n.kids = dirs + leaves
        n.dirs = [:]; n.files = []
    }

    func expandHot(_ item: Node?) {
        for k in (item ?? root).kids where k.isDir && k.hot { outline.expandItem(k); expandHot(k) }
    }

    func outlineView(_ o: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { ((item as? Node) ?? root).kids.count }
    func outlineView(_ o: NSOutlineView, child i: Int, ofItem item: Any?) -> Any { ((item as? Node) ?? root).kids[i] }
    func outlineView(_ o: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as! Node).isDir }

    func outlineView(_ o: NSOutlineView, viewFor c: NSTableColumn?, item: Any) -> NSView? {
        let n = item as! Node, id = NSUserInterfaceItemIdentifier("cell")
        let v = o.makeView(withIdentifier: id, owner: nil) as? TreeCell ?? { let v = TreeCell(); v.identifier = id; return v }()
        v.name.stringValue = n.name
        v.name.textColor = n.isDir ? Palette.mut : n.file == nil ? Palette.mut.withAlphaComponent(0.6) : Palette.fg
        if let i = n.file {
            let s = NSMutableAttributedString(string: "+\(files[i].add)", attributes: [.foregroundColor: Palette.addText, .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)])
            s.append(NSAttributedString(string: " -\(files[i].del)", attributes: [.foregroundColor: Palette.delText, .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)]))
            v.stats.attributedStringValue = s
        } else {
            v.stats.stringValue = ""
        }
        v.needsLayout = true
        return v
    }

    func outlineViewSelectionDidChange(_ n: Notification) {
        if let node = outline.item(atRow: outline.selectedRow) as? Node, let f = node.file { onPick(f) }
    }
}
