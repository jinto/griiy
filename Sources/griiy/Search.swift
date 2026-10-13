// ⌘P and `/` (F-DV-7): overlays over the window. Each keeps the keyboard in its field; the field
// editor's commands (↑ ↓ Return Escape) drive it, and the results never take focus.
import AppKit
import GriiyCore

/// A floating rounded panel, hidden until opened.
private func overlay(_ frame: NSRect) -> NSVisualEffectView {
    let v = NSVisualEffectView(frame: frame)
    v.material = .popover
    v.state = .active
    v.wantsLayer = true
    v.layer?.cornerRadius = 8
    v.isHidden = true
    return v
}

/// Gives the field editor up before hiding: a hidden field would keep the keyboard.
private func close(_ box: NSView, focus: NSView) {
    guard !box.isHidden else { return }
    box.window?.makeFirstResponder(focus)
    box.isHidden = true
}

/// ⌘P: fuzzy file names, the best 50; Return or a click picks one.
final class GoToFile: NSObject, NSTextFieldDelegate, NSTableViewDataSource {
    let box = overlay(NSRect(x: 0, y: 0, width: 560, height: 36 + 12 * 20))
    private let field = NSTextField()
    private let table = NSTableView()
    private var paths: [String] = []
    private var shown: [Int] = []
    /// Where the keyboard goes back to.
    var focus: () -> NSView = { NSView() }
    var onPick: (String) -> Void = { _ in }

    override init() {
        super.init()
        field.frame = NSRect(x: 8, y: box.frame.height - 32, width: box.frame.width - 16, height: 24)
        field.placeholderString = "Go to file"
        field.font = .systemFont(ofSize: 15)
        field.delegate = self
        let column = NSTableColumn(identifier: .init("path"))
        column.width = box.frame.width - 16
        (column.dataCell as? NSTextFieldCell)?.lineBreakMode = .byTruncatingHead
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 18
        table.backgroundColor = .clear
        table.refusesFirstResponder = true
        table.dataSource = self
        table.target = self
        table.action = #selector(clicked)
        let scroll = NSScrollView(frame: NSRect(x: 8, y: 4, width: box.frame.width - 16, height: box.frame.height - 40))
        scroll.documentView = table
        scroll.drawsBackground = false
        for v in [field, scroll] { box.addSubview(v) }
    }

    func open(_ paths: [String]) {
        self.paths = paths
        field.stringValue = ""
        update()
        box.isHidden = false
        box.window?.makeFirstResponder(field)
    }

    private func update() {
        shown = fuzzy(field.stringValue, in: paths)
        table.reloadData()
        table.selectRowIndexes(shown.isEmpty ? [] : [0], byExtendingSelection: false)
        table.scrollRowToVisible(0)
    }

    private func pick(_ row: Int) {
        guard shown.indices.contains(row) else { return }
        close(box, focus: focus())
        onPick(paths[shown[row]])
    }

    @objc private func clicked() { pick(table.clickedRow) }

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        paths[shown[row]]
    }

    func controlTextDidChange(_ obj: Notification) { update() }

    /// Clicking anywhere else closes it.
    func controlTextDidEndEditing(_ obj: Notification) { box.isHidden = true }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.moveDown(_:)):
            guard !shown.isEmpty else { return true }
            let up = selector == #selector(NSResponder.moveUp(_:))
            let row = min(max(table.selectedRow + (up ? -1 : 1), 0), shown.count - 1)
            table.selectRowIndexes([row], byExtendingSelection: false)
            table.scrollRowToVisible(row)
        case #selector(NSResponder.insertNewline(_:)): pick(table.selectedRow)
        case #selector(NSResponder.cancelOperation(_:)): close(box, focus: focus())
        default: return false
        }
        return true
    }
}

/// `/`: finds text in the diff shown. Return is the next hit, ⇧Return the previous.
final class FindBar: NSObject, NSSearchFieldDelegate {
    let box = overlay(NSRect(x: 0, y: 0, width: 330, height: 36))
    private let field = NSSearchField()
    private let count = NSTextField(labelWithString: "")
    /// The query last searched: the text-change notification and the field's action both report an edit.
    private var last = ""
    /// The diff or whole file on screen.
    var target: () -> DiffController = { DiffController() }

    override init() {
        super.init()
        field.frame = NSRect(x: 8, y: 6, width: 230, height: 24)
        field.placeholderString = "Find in diff"
        field.delegate = self
        // The clear button changes the text without a text-change notification.
        field.target = self
        field.action = #selector(changed)
        count.frame = NSRect(x: 244, y: 9, width: 80, height: 18)
        count.textColor = Palette.mut
        count.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        for v in [field, count] { box.addSubview(v) }
    }

    func open() {
        box.isHidden = false
        box.window?.makeFirstResponder(field)
        // The view shown (or its files) may have changed since: search again.
        last = ""
        changed()
    }

    @objc private func changed() {
        guard field.stringValue != last else { return }
        last = field.stringValue
        let n = target().find(last)
        count.stringValue = field.stringValue.isEmpty ? "" : n == 0 ? "No results" : "\(n)"
        if n > 0 { step(forward: true) } else { target().table.deselectAll(nil) }
    }

    private func step(forward: Bool) {
        let c = target()
        // The shown view may have changed (Escape out of a whole file): search it first.
        let n = c.find(field.stringValue)
        if let i = c.step(forward: forward) { count.stringValue = "\(i + 1)/\(n)" }
    }

    func controlTextDidChange(_ obj: Notification) { changed() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            step(forward: NSApp.currentEvent?.modifierFlags.contains(.shift) != true)
        case #selector(NSResponder.cancelOperation(_:)): close(box, focus: target().table)
        default: return false
        }
        return true
    }
}
