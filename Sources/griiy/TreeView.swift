// File tree (F-DV-1): tracked ∪ changed paths in an NSOutlineView. Dirs holding a change start
// expanded, single-child dir chains collapse into one "a/b/c" node. NSOutlineView only asks for the
// children of expanded items, so a closed folder's contents cost nothing on screen.
import AppKit
import GriiyCore

final class Node {
    var name: String
    var dirs: [String: Node] = [:]
    var paths: [String] = []
    var children: [Node] = []
    /// Index of the changed file this leaf is.
    var file: Int?
    var path = ""
    var hot = false
    let isDir: Bool

    init(_ name: String, dir: Bool) {
        self.name = name
        isDir = dir
    }
}

final class TreeCell: NSTableCellView {
    let name = NSTextField(labelWithString: "")
    let stats = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        name.lineBreakMode = .byTruncatingTail
        for field in [name, stats] {
            field.font = .systemFont(ofSize: 13)
            addSubview(field)
        }
        textField = name
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        stats.sizeToFit()
        let w = stats.frame.width
        stats.frame = NSRect(
            x: bounds.width - w - 4, y: (bounds.height - stats.frame.height) / 2, width: w, height: stats.frame.height)
        name.frame = NSRect(x: 0, y: (bounds.height - 17) / 2, width: bounds.width - w - 8, height: 17)
    }
}

final class TreeController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let outline = NSOutlineView()
    let scroll = NSScrollView()
    private var root = Node("", dir: true)
    private var files: [File] = []
    /// A changed file picked: show it in the diff.
    var onPick: (Int) -> Void = { _ in }
    /// Show this path whole: an unchanged file picked, or any file double-clicked.
    var onOpen: (String) -> Void = { _ in }

    override init() {
        super.init()
        let column = NSTableColumn(identifier: .init("tree"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.backgroundColor = Palette.side
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(open)
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
    }

    /// Builds and shows the tree; returns the number of paths in it.
    func fill(_ files: [File], tracked: String) -> Int {
        self.files = files
        // Deleted files aren't in the listing but still belong in the tree.
        let changed = Dictionary(files.enumerated().map { ($1.path, $0) }, uniquingKeysWith: { a, _ in a })
        var all = Set(tracked.split(separator: "\0").map(String.init))
        all.formUnion(changed.keys)
        root = Node("", dir: true)
        for p in all {
            var n = root
            for d in p.split(separator: "/", omittingEmptySubsequences: false).dropLast() {
                let next = n.dirs[String(d)] ?? Node(String(d), dir: true)
                n.dirs[String(d)] = next
                n = next
                if changed[p] != nil { n.hot = true }
            }
            n.paths.append(p)
        }
        finish(root, changed)
        outline.reloadData()
        expandHot(root)
        return all.count
    }

    private func finish(_ n: Node, _ changed: [String: Int]) {
        var dirs: [Node] = []
        for (_, child) in n.dirs.sorted(by: { $0.key < $1.key }) {
            var c = child
            var full = c.name
            while c.paths.isEmpty && c.dirs.count == 1, let only = c.dirs.first?.value {
                c = only
                full += "/" + c.name
            }
            c.name = full
            finish(c, changed)
            dirs.append(c)
        }
        let leaves = n.paths.sorted().map { p -> Node in
            let leaf = Node(String(p.split(separator: "/").last ?? ""), dir: false)
            leaf.file = changed[p]
            leaf.path = p
            return leaf
        }
        n.children = dirs + leaves
        n.dirs = [:]
        n.paths = []
    }

    private func expandHot(_ node: Node) {
        for c in node.children where c.isDir && c.hot {
            outline.expandItem(c)
            expandHot(c)
        }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        ((item as? Node) ?? root).children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        ((item as? Node) ?? root).children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? Node)?.isDir ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let n = item as? Node else { return nil }
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? TreeCell ?? TreeCell()
        cell.identifier = id
        cell.name.stringValue = n.name
        cell.name.textColor = n.isDir ? Palette.mut : n.file == nil ? Palette.mut.withAlphaComponent(0.6) : Palette.fg
        if let i = n.file {
            let digits = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            let (add, del) = files[i].stats
            let s = NSMutableAttributedString(
                string: "+\(add)", attributes: [.foregroundColor: Palette.addText, .font: digits])
            s.append(
                NSAttributedString(string: " -\(del)", attributes: [.foregroundColor: Palette.delText, .font: digits]))
            cell.stats.attributedStringValue = s
        } else {
            cell.stats.stringValue = ""
        }
        cell.needsLayout = true
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard let node = outline.item(atRow: outline.selectedRow) as? Node, !node.isDir else { return }
        if let f = node.file { onPick(f) } else { onOpen(node.path) }
    }

    @objc private func open() {
        if let node = outline.item(atRow: outline.clickedRow) as? Node, !node.isDir { onOpen(node.path) }
    }
}
