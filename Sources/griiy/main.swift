// griiy: the AppKit window over GriiyCore. Arguments are parsed before any window exists; the
// review opens on a thread of its own while the window comes up, and closing the window kills
// any git still running.
import AppKit
import Carbon
import Foundation
import GriiyCore
import System

private func hex(_ light: UInt32, _ dark: UInt32) -> NSColor {
    func color(_ v: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat(v >> 16 & 255) / 255, green: CGFloat(v >> 8 & 255) / 255, blue: CGFloat(v & 255) / 255,
            alpha: 1)
    }
    return NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? color(dark) : color(light) }
}

/// The colors of the WebKit version's app.css, light and dark.
enum Palette {
    static let fg = hex(0x1f2328, 0xe6edf3), mut = hex(0x656d76, 0x8d96a0), side = hex(0xf6f8fa, 0x161b22)
    static let add = hex(0xdafbe1, 0x12261e), del = hex(0xffebe9, 0x25171c), hunk = hex(0xddf4ff, 0x121d2f)
    static let addText = hex(0x1a7f37, 0x3fb950), delText = hex(0xcf222e, 0xf85149), bg = hex(0xffffff, 0x0d1117)
    static let keyword = hex(0xcf222e, 0xff7b72), string = hex(0x0a3069, 0xa5d6ff)
    static let comment = hex(0x6e7781, 0x8b949e), number = hex(0x0550ae, 0x79c0ff)

    static func syntax(_ t: Token) -> NSColor {
        switch t {
        case .keyword: keyword
        case .string: string
        case .comment: comment
        case .number: number
        }
    }
}

// ---- Bench marks: with GRIIY_MARK set, two JSON lines go to that file (scripts/bench.sh) ----
let markPath = ProcessInfo.processInfo.environment["GRIIY_MARK"]

func mark(_ body: String) {
    guard let markPath else { return }
    let line = "{\"type\":\"mark\",\"wall\":\(Int(Date().timeIntervalSince1970 * 1000)),\(body)}\n"
    if !FileManager.default.fileExists(atPath: markPath) {
        FileManager.default.createFile(atPath: markPath, contents: nil)
    }
    guard let h = FileHandle(forWritingAtPath: markPath) else { return }
    h.seekToEndOfFile()
    h.write(Data(line.utf8))
    h.closeFile()
}

private func jsonString(_ s: String) -> String {
    String(decoding: (try? JSONEncoder().encode(s)) ?? Data("\"\"".utf8), as: UTF8.self)
}

/// The key's character on the current ASCII-capable layout, as AppKit matches ⌘ shortcuts: `n`
/// stays `n` with a Korean input source on, and German ⇧7 is still `/`. ⇧ and ⌥ count; nil with ⌘ or ⌃.
func asciiKey(_ e: NSEvent) -> String? {
    guard e.modifierFlags.isDisjoint(with: [.command, .control]),
        let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
        let data = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
    else { return nil }
    let layout = Unmanaged<CFData>.fromOpaque(data).takeUnretainedValue()
    guard let bytes = CFDataGetBytePtr(layout) else { return nil }
    // UCKeyTranslate wants Carbon modifiers >> 8: shift 2, option 8, which NSEvent keeps at bits 17 and 19.
    let mods = UInt32(e.modifierFlags.intersection([.shift, .option]).rawValue >> 16 & 0xFF)
    var dead: UInt32 = 0
    var chars = [UniChar](repeating: 0, count: 4)
    var n = 0
    let status = bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) {
        UCKeyTranslate(
            $0, e.keyCode, UInt16(kUCKeyActionDown), mods, UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &n, &chars)
    }
    return status == noErr && n > 0 ? String(utf16CodeUnits: chars, count: n) : nil
}

let shortcuts = """
    ]  [     next / previous file
    n  p     next / previous change
    v        mark the file seen (or not)
    /  ⌘F    find: Return next, ⇧Return previous
    ⌘P       go to file
    c        line comments on this line
    ⌘I       PR panel (show or hide)
    Return   tree: show the file whole
    Escape   back to the diff
    ⌘/       this list

    ] [ n p stop at the ends; find wraps around.
    """

final class App: NSObject, NSApplicationDelegate {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
        styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    let header = NSTextField(labelWithString: "…")
    let diff = DiffController()
    /// One file whole (F-DV-5), in place of the diff until Escape or a changed file is picked.
    let full = DiffController()
    /// Drops a whole-file fetch the user has already moved on from (arrowing through the tree).
    private var opening = 0
    let tree = TreeController()
    let goTo = GoToFile()
    let find = FindBar()
    let message = NSTextField(wrappingLabelWithString: "")
    /// The PR's title, text and comments (F-PR-4), right of the diff; hidden for a local range.
    let panel = TextPane()
    private let split = NSSplitView()
    /// Stops the git opening the review when the window closes.
    let cancel = Cancel()
    private var review: Review?
    /// Files marked seen (F-DV-9), and the store document they're saved in: nil when it couldn't
    /// be read, so marks stay on screen and nothing overwrites the file.
    private var seen: Set<Int> = []
    private var doc: [String: Any]?
    private enum Phase {
        case waiting
        case error(String)
        case empty, ready, done
    }
    private var phase = Phase.waiting

    override init() {
        super.init()
        window.title = "griiy"
        window.center()
        let content = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = content
        let b = content.bounds
        header.frame = NSRect(x: 12, y: b.height - 26, width: b.width - 24, height: 18)
        header.autoresizingMask = [.width, .minYMargin]
        header.lineBreakMode = .byTruncatingMiddle
        let line = NSBox(frame: NSRect(x: 0, y: b.height - 33, width: b.width, height: 1))
        line.boxType = .separator
        line.autoresizingMask = [.width, .minYMargin]
        split.frame = NSRect(x: 0, y: 0, width: b.width, height: b.height - 33)
        split.isVertical = true
        split.dividerStyle = .thin
        split.autoresizingMask = [.width, .height]
        tree.scroll.frame = NSRect(x: 0, y: 0, width: 260, height: split.bounds.height)
        let right = NSView(frame: NSRect(x: 261, y: 0, width: b.width - 261, height: split.bounds.height))
        diff.scroll.frame = right.bounds
        diff.scroll.autoresizingMask = [.width, .height]
        message.frame = right.bounds.insetBy(dx: 32, dy: 32)
        message.autoresizingMask = [.width, .height]
        message.isHidden = true
        message.isSelectable = true
        full.scroll.frame = right.bounds
        full.scroll.autoresizingMask = [.width, .height]
        full.scroll.isHidden = true
        find.box.frame.origin = NSPoint(x: right.bounds.width - find.box.frame.width - 24, y: right.bounds.height - 44)
        find.box.autoresizingMask = [.minXMargin, .minYMargin]
        for v in [diff.scroll, full.scroll, message, find.box] { right.addSubview(v) }
        panel.scroll.frame = NSRect(x: 0, y: 0, width: 360, height: split.bounds.height)
        panel.scroll.isHidden = true
        split.addArrangedSubview(tree.scroll)
        split.addArrangedSubview(right)
        split.addArrangedSubview(panel.scroll)
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 2)
        goTo.box.frame.origin = NSPoint(
            x: (b.width - goTo.box.frame.width) / 2, y: b.height - 60 - goTo.box.frame.height)
        goTo.box.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin]
        for v in [header, line, split, goTo.box] { content.addSubview(v) }
        goTo.focus = { [unowned self] in shown.table }
        goTo.onPick = { [unowned self] path in tree.reveal(path) }
        find.target = { [unowned self] in shown }
        tree.onPick = { [unowned self] f in
            showDiff()
            diff.scrollTo(file: f)
        }
        tree.onOpen = { [unowned self] path in open(path) }
        panel.onGoto = { [unowned self] n in goTo(thread: n) }
        diff.isSeen = { [unowned self] in seen.contains($0) }
        tree.isSeen = diff.isSeen
        full.isSeen = { [unowned self] _ in fullInDiff.map(seen.contains) ?? false }
        // Keys that work wherever focus is, except while typing in a field or over a sheet.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [unowned self] e in
            guard e.window === window, window.attachedSheet == nil, !(window.firstResponder is NSText) else { return e }
            // Escape leaves a whole file (the tree keeps focus while arrowing through files).
            if e.keyCode == 53, !full.scroll.isHidden {
                showDiff()
                return nil
            }
            // Return (or keypad Enter) on a tree row shows it whole, like a double-click.
            if e.keyCode == 36 || e.keyCode == 76, window.firstResponder === tree.outline, tree.openSelected() {
                return nil
            }
            let key = asciiKey(e)
            switch key {
            case "/": find.open()
            case "v": toggleSeen()
            case "c": shown.showThreadsAtCursor()
            case "n": shown.jump(files: false, forward: true)
            case "p": shown.jump(files: false, forward: false)
            case "]", "[":
                // A whole file is one file: step from where it sits in the diff.
                let from = full.scroll.isHidden ? nil : full.files.first.flatMap { diff.startOf($0.path) }
                showDiff()
                diff.jump(files: true, forward: key == "]", from: from)
            default: return e
            }
            return nil
        }
        // The first display tick after rows are on screen writes the first-paint mark (tick).
        content.displayLink(target: self, selector: #selector(tick(_:))).add(to: .main, forMode: .common)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        window.makeKeyAndOrderFront(nil)
        // A plain executable launched from a terminal must pull itself to the front (M0-3).
        NSApp.activate()
        window.makeFirstResponder(diff.table)
    }

    /// The diff or the whole file, whichever is on screen.
    private var shown: DiffController { full.scroll.isHidden ? diff : full }

    @objc func goToFile(_ sender: Any?) { goTo.open(tree.paths) }
    @objc func findInDiff(_ sender: Any?) { find.open() }
    @objc func togglePanel(_ sender: Any?) {
        guard review?.pr != nil else { return }
        setPanel(shown: panel.scroll.isHidden)
    }

    /// Shows or hides the PR panel, taking its width from the diff, not the tree.
    private func setPanel(shown: Bool) {
        let width = tree.scroll.frame.width
        panel.scroll.isHidden = !shown
        split.adjustSubviews()
        split.setPosition(width, ofDividerAt: 0)
        if shown { split.setPosition(split.bounds.width - 360, ofDividerAt: 1) }
    }
    @objc func showShortcuts(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Keyboard Shortcuts"
        let list = NSTextField(labelWithString: shortcuts)
        list.font = mono
        list.sizeToFit()
        alert.accessoryView = list
        alert.beginSheetModal(for: window)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // git runs in its own process group, so it would outlive us: stop it.
        cancel.cancel()
        return .terminateNow
    }

    /// On the main thread, with what Review.open returned and the review's store document.
    func loaded(_ result: Result<Review, GitError>, doc: [String: Any]?) {
        switch result {
        case .failure(let e):
            // Launched outside a repository (from Finder the directory is /): ask for one. Not when
            // measuring (GRIIY_MARK), which no one is there to answer.
            if case .notARepo = e, markPath == nil { return choose(e) }
            showMessage(e.title, e.detail, e.hint)
            phase = .error(e.title)
        case .success(let r):
            review = r
            self.doc = doc
            seen = doc.map(r.seen(in:)) ?? []
            diff.load(r.files)
            if let pr = r.pr {
                diff.threads = pr.threads
                full.threads = pr.threads
                setPanel(shown: true)
            }
            header.attributedStringValue = headerText(r, total: nil)
            if r.files.isEmpty {
                let hint = r.head == .workTree ? " To see the last commit: griiy HEAD~1..HEAD" : ""
                showMessage("No changes." + hint, "", "", plain: true)
                phase = .empty
            } else {
                phase = .ready
            }
        }
    }

    /// Asks for a repository, again after each folder that isn't one; on Cancel, `e` as usual.
    private func choose(_ e: GitError) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose a git repository to review."
        panel.prompt = "Open"
        panel.beginSheetModal(for: window) { [self] response in
            guard response == .OK, let url = panel.url else {
                showMessage(e.title, e.detail, e.hint)
                phase = .error(e.title)
                return
            }
            openRepo(FilePath(url.path))
        }
    }

    private func headerText(_ r: Review, total: Int?) -> NSAttributedString {
        let s = NSMutableAttributedString(
            string: r.repo.string, attributes: [.font: NSFont.boldSystemFont(ofSize: 13), .foregroundColor: Palette.fg])
        var rest = "   \(r.spec.label)" + (r.pr.map { " " + $0.title } ?? "") + " · \(r.files.count) changed"
        if let total { rest += " / \(total) files" }
        if !seen.isEmpty { rest += " · \(seen.count) seen" }
        s.append(
            NSAttributedString(
                string: rest, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: Palette.mut]))
        return s
    }

    private func showMessage(_ title: String, _ detail: String, _ hint: String, plain: Bool = false) {
        let s = NSMutableAttributedString()
        if plain {
            s.append(
                NSAttributedString(
                    string: title, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: Palette.mut]))
        } else {
            s.append(
                NSAttributedString(
                    string: title + "\n\n",
                    attributes: [.font: NSFont.boldSystemFont(ofSize: 18), .foregroundColor: Palette.fg]))
            if !detail.isEmpty {
                s.append(
                    NSAttributedString(
                        string: detail + "\n\n", attributes: [.font: mono, .foregroundColor: Palette.mut]))
            }
            s.append(
                NSAttributedString(
                    string: hint, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: Palette.fg]))
        }
        message.attributedStringValue = s
        show(message)
    }

    private func show(_ view: NSView) {
        for v in [diff.scroll, full.scroll, message] { v.isHidden = v !== view }
    }

    private func showDiff() {
        opening += 1
        // An error or "No changes" stays what's shown behind a whole file.
        show(review?.files.isEmpty == false ? diff.scroll : message)
    }

    /// The panel's thread `n`, on its line in the diff.
    private func goTo(thread n: Int) {
        guard let threads = review?.pr?.threads, n < threads.count, case let t = threads[n],
            let f = diff.files.firstIndex(where: { $0.path == t.path }),
            let row = threadRows([t], in: diff.files[f]).keys.first, let at = diff.startOf(t.path)
        else { return }
        showDiff()
        diff.reveal(row: at + row)
        window.makeFirstResponder(diff.table)
    }

    /// Fetches the file on a thread (git or the disk), then shows it if nothing was picked since.
    private func open(_ path: String) {
        guard let review else { return }
        opening += 1
        let mine = opening
        let cancel = cancel
        Thread.detachNewThread {
            let result = Result { () throws(GitError) in try review.whole(path, cancel: cancel) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard mine == self.opening else { return }
                    switch result {
                    case .success(let f):
                        self.full.load([f])
                        self.show(self.full.scroll)
                        self.full.scrollTo(row: 0)
                    case .failure(let e): self.showMessage(e.title, e.detail, e.hint)
                    }
                }
            }
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        switch phase {
        case .waiting, .done: return
        case .error(let title):
            mark("\"error\":\(jsonString(title))")
            mark("\"scroll\":null")
        case .empty:
            mark("\"git\":\(review?.gitMs ?? 0),\"rows\":0,\"files\":0,\"views\":0")
            mark("\"scroll\":null")
            fillTree()
        case .ready:
            guard diff.liveRowViews() > 0 else { return }
            mark(
                "\"git\":\(review?.gitMs ?? 0),\"rows\":\(diff.total),\"files\":\(diff.files.count),\"views\":\(diff.liveRowViews())"
            )
            fillTree()
            if markPath != nil {
                diff.startBench { [tree] scroll in
                    mark(
                        "\"scroll\":\(scroll),\"tree\":{\"rows\":\(tree.outline.numberOfRows),\"views\":\(tree.liveRowViews())}"
                    )
                }
            }
        }
        phase = .done
        link.invalidate()
    }

    /// The whole file's index in the diff, if one is shown and the diff has it.
    private var fullInDiff: Int? {
        guard !full.scroll.isHidden, let path = full.files.first?.path else { return nil }
        return diff.files.firstIndex { $0.path == path }
    }

    /// `v`: flips the mark of the file at the cursor (or the whole file shown) and saves it.
    private func toggleSeen() {
        // Behind an error message, neither: the cursor would be a file not on screen.
        guard let r = review, let f = diff.scroll.isHidden ? fullInDiff : diff.fileAtCursor else { return }
        let on = seen.insert(f).inserted
        if !on { seen.remove(f) }
        diff.redraw(file: f)
        full.redraw(file: 0)
        tree.redraw(file: f)
        header.attributedStringValue = headerText(r, total: tree.paths.isEmpty ? nil : tree.paths.count)
        guard let store, let d = doc else { return }
        let next = r.marking(f, on, in: d)
        doc = next
        do {
            try store.save(r.key, next)
        } catch {
            FileHandle.standardError.write(Data("griiy: saving seen files: \(error.message)\n".utf8))
        }
    }

    /// After first paint: the tree of every tracked file and the PR's text (100ms on a PR with a
    /// few hundred comments) aren't needed to show the diff.
    private func fillTree() {
        guard let r = review else { return }
        let n = tree.fill(r.files, tracked: r.tracked)
        header.attributedStringValue = headerText(r, total: n)
        if let pr = r.pr {
            var images: [URL] = []
            panel.show(panelText(pr, label: r.spec.label, images: &images), images: images)
        }
    }
}

// Usage errors go to the terminal before any window exists. Arguments as raw bytes: a repo path
// need not be UTF-8.
let rawArgs = (1..<Int(CommandLine.argc)).compactMap { i in
    CommandLine.unsafeArgv[i].map {
        Array(UnsafeBufferPointer(start: $0, count: strlen($0))).map { UInt8(bitPattern: $0) }
    }
}
let args: Args
switch parseArgs(rawArgs) {
case .success(let a): args = a
case .failure(let e):
    FileHandle.standardError.write(Data((e.message + "\n").utf8))
    exit(2)
}
// Settings are read now but mostly used by features still in progress; bad values only warn.
for warning in appDir().map({ loadConfig($0.appending("config.toml")).1 }) ?? [] {
    FileHandle.standardError.write(Data("griiy: config: \(warning)\n".utf8))
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let appMenu = NSMenu()
let editMenu = NSMenu(title: "Edit")
appMenu.addItem(withTitle: "Quit griiy", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
editMenu.addItem(withTitle: "Find…", action: #selector(App.findInDiff(_:)), keyEquivalent: "f")
let goMenu = NSMenu(title: "Go")
goMenu.addItem(withTitle: "Go to File…", action: #selector(App.goToFile(_:)), keyEquivalent: "p")
goMenu.addItem(withTitle: "PR Info", action: #selector(App.togglePanel(_:)), keyEquivalent: "i")
let helpMenu = NSMenu(title: "Help")
helpMenu.addItem(withTitle: "Keyboard Shortcuts", action: #selector(App.showShortcuts(_:)), keyEquivalent: "/")
let menu = NSMenu()
for sub in [appMenu, editMenu, goMenu, helpMenu] {
    let item = NSMenuItem()
    item.submenu = sub
    menu.addItem(item)
}
app.mainMenu = menu
let store = appDir().map { Store(root: $0.appending("reviews")) }
let ui = App()
app.delegate = ui
// git runs while the window is being created. Review.open blocks, so it gets a thread, not a Task.
func openRepo(_ repo: FilePath) {
    let (spec, cancel) = (args.spec, ui.cancel)
    Thread.detachNewThread {
        let result = Result { () throws(GitError) in try Review.open(repo, spec, cancel: cancel) }
        var doc: [String: Any]?
        if let store, case .success(let r) = result {
            do throws(StoreError) {
                doc = try store.load(r.key)
            } catch {
                FileHandle.standardError.write(Data("griiy: reading seen files: \(error.message)\n".utf8))
            }
        }
        DispatchQueue.main.async { MainActor.assumeIsolated { ui.loaded(result, doc: doc) } }
    }
}
openRepo(args.repo)
app.run()
