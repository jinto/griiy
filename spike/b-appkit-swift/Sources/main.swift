// griiy spike B: AppKit UI in Swift over the Rust core (core/, griiy.h).
import AppKit

/// Takes ownership of a string the core returned.
func take(_ p: UnsafeMutablePointer<CChar>?) -> String? {
    guard let p else { return nil }
    defer { griiy_string_free(p) }
    return String(cString: p)
}

func json(_ s: String) -> Any? { try? JSONSerialization.jsonObject(with: Data(s.utf8)) }

func hex(_ light: UInt32, _ dark: UInt32) -> NSColor {
    func c(_ v: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat(v >> 16 & 255) / 255, green: CGFloat(v >> 8 & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
    }
    return NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? c(dark) : c(light) }
}

/// app.css palette.
enum Palette {
    static let fg = hex(0x1f2328, 0xe6edf3), mut = hex(0x656d76, 0x8d96a0), side = hex(0xf6f8fa, 0x161b22)
    static let add = hex(0xdafbe1, 0x12261e), del = hex(0xffebe9, 0x25171c), hunk = hex(0xddf4ff, 0x121d2f)
    static let addText = hex(0x1a7f37, 0x3fb950), delText = hex(0xcf222e, 0xf85149), bg = hex(0xffffff, 0x0d1117)
}

// ---- Bench marks (spike/BRIEF.md) ----
let markPath = ProcessInfo.processInfo.environment["GRIIY_MARK"]
func mark(_ body: String) {
    guard let markPath else { return }
    let line = "{\"type\":\"mark\",\"wall\":\(Int(Date().timeIntervalSince1970 * 1000)),\(body)}\n"
    if let h = FileHandle(forWritingAtPath: markPath) ?? {
        FileManager.default.createFile(atPath: markPath, contents: nil)
        return FileHandle(forWritingAtPath: markPath)
    }() {
        h.seekToEndOfFile(); h.write(Data(line.utf8)); h.closeFile()
    }
}
func jsonString(_ s: String) -> String {
    String(data: try! JSONSerialization.data(withJSONObject: [s], options: [.fragmentsAllowed, .withoutEscapingSlashes]), encoding: .utf8)!.dropFirst().dropLast().description
}

final class AppUI: NSObject, NSApplicationDelegate {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    let header = NSTextField(labelWithString: "griiy")
    let diff = DiffController()
    let tree = TreeController()
    let message = NSTextField(wrappingLabelWithString: "")
    var link: CADisplayLink?
    enum Phase { case waiting, error(String), empty, ready, done }
    var phase = Phase.waiting
    var md: NSWindow?

    override init() {
        super.init()
        window.title = "griiy"
        window.center()
        let content = window.contentView!
        let b = content.bounds
        header.frame = NSRect(x: 12, y: b.height - 26, width: b.width - 24, height: 18)
        header.autoresizingMask = [.width, .minYMargin]
        header.lineBreakMode = .byTruncatingMiddle
        let line = NSBox(frame: NSRect(x: 0, y: b.height - 33, width: b.width, height: 1))
        line.boxType = .separator; line.autoresizingMask = [.width, .minYMargin]
        let split = NSSplitView(frame: NSRect(x: 0, y: 0, width: b.width, height: b.height - 33))
        split.isVertical = true; split.dividerStyle = .thin; split.autoresizingMask = [.width, .height]
        tree.scroll.frame = NSRect(x: 0, y: 0, width: 260, height: split.bounds.height)
        let right = NSView(frame: NSRect(x: 261, y: 0, width: b.width - 261, height: split.bounds.height))
        diff.scroll.frame = right.bounds; diff.scroll.autoresizingMask = [.width, .height]
        message.frame = right.bounds.insetBy(dx: 32, dy: 32); message.autoresizingMask = [.width, .height]
        message.isHidden = true; message.isSelectable = true
        right.addSubview(diff.scroll); right.addSubview(message)
        split.addArrangedSubview(tree.scroll); split.addArrangedSubview(right)
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        [header, line, split].forEach(content.addSubview)
        tree.onPick = { [unowned self] f in diff.scrollTo(file: f) }
        // First display tick after rows are on screen writes mark 1 (see tick).
        link = content.displayLink(target: self, selector: #selector(tick(_:)))
        link?.add(to: .main, forMode: .common)
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        window.makeKeyAndOrderFront(nil)
        // P-FOCUS: a plain executable launched from a terminal must pull itself to the front.
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(diff.table)
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [unowned self] e in
            guard e.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return e }
            switch e.charactersIgnoringModifiers {
            case "j": diff.jumpFile(1)
            case "k": diff.jumpFile(-1)
            case "m": showMarkdown()
            default: return e
            }
            return nil
        }
        if ProcessInfo.processInfo.environment["GRIIY_PROBE"] == "md" { showMarkdown() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }

    /// Called on the main thread with the result of griiy_open.
    func loaded(_ review: OpaquePointer?, _ error: String?) {
        guard let review, let s = take(griiy_summary(review)), let sum = json(s) as? [String: Any] else {
            let e = (error.flatMap(json) as? [String: String]) ?? ["title": "griiy failed", "detail": error ?? "", "hint": ""]
            showMessage(e["title"] ?? "", e["detail"] ?? "", e["hint"] ?? "")
            phase = .error(e["title"] ?? "")
            return
        }
        diff.load(review, sum)
        tree.summary = sum
        header.attributedStringValue = headerText(sum, nil)
        if diff.files.isEmpty {
            showMessage("No changes.", "", (sum["worktree"] as? Bool ?? false) ? "To see the last commit: griiy HEAD~1..HEAD" : "", plain: true)
            phase = .empty
        } else {
            phase = .ready
        }
    }

    func headerText(_ sum: [String: Any], _ total: Int?) -> NSAttributedString {
        let s = NSMutableAttributedString(string: sum["repo"] as? String ?? "", attributes: [.font: NSFont.boldSystemFont(ofSize: 13), .foregroundColor: Palette.fg])
        var rest = "   \(sum["label"] as? String ?? "") · \(diff.files.count) changed"
        if let total { rest += " / \(total) files" }
        s.append(NSAttributedString(string: rest, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: Palette.mut]))
        return s
    }

    func showMessage(_ title: String, _ detail: String, _ hint: String, plain: Bool = false) {
        let s = NSMutableAttributedString()
        if plain {
            s.append(NSAttributedString(string: title + (hint.isEmpty ? "" : " " + hint), attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: Palette.mut]))
        } else {
            s.append(NSAttributedString(string: title + "\n\n", attributes: [.font: NSFont.boldSystemFont(ofSize: 18), .foregroundColor: Palette.fg]))
            if !detail.isEmpty {
                s.append(NSAttributedString(string: detail + "\n\n", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: Palette.mut]))
            }
            s.append(NSAttributedString(string: hint, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: Palette.fg]))
        }
        message.attributedStringValue = s
        message.isHidden = false
        diff.scroll.isHidden = true
    }

    @objc func tick(_ link: CADisplayLink) {
        switch phase {
        case .waiting, .done: return
        case .error(let title):
            mark("\"error\":\(jsonString(title))"); mark("\"scroll\":null"); phase = .done; link.invalidate()
        case .empty:
            mark("\"git\":\(diff.gitMs),\"rows\":0,\"files\":0,\"views\":0"); mark("\"scroll\":null"); phase = .done
            fillTree(); link.invalidate()
        case .ready:
            guard diff.liveRowViews() > 0 else { return }
            mark("\"git\":\(diff.gitMs),\"rows\":\(diff.total),\"files\":\(diff.files.count),\"views\":\(diff.liveRowViews())")
            phase = .done
            fillTree()
            link.invalidate()
            if let at = ProcessInfo.processInfo.environment["GRIIY_AT"].flatMap(Double.init) { diff.scrollTo(row: Int(Double(diff.total) * at)) } // screenshots
            if markPath != nil { diff.startBench() }
        }
    }

    func fillTree() {
        let n = tree.fill(diff.files)
        if let sum = tree.summary { header.attributedStringValue = headerText(sum, n) }
    }

    func showMarkdown() {
        if let md { md.makeKeyAndOrderFront(nil); return }
        md = markdownWindow()
    }
}

// Usage errors go to the terminal before any window exists.
let argc = CommandLine.argc, argv = CommandLine.unsafeArgv
if let e = take(griiy_usage_error(argc, argv)) {
    FileHandle.standardError.write(Data((e + "\n").utf8))
    exit(2)
}
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let menu = NSMenu(), appItem = NSMenuItem(), editItem = NSMenuItem()
appItem.submenu = NSMenu(); appItem.submenu!.addItem(withTitle: "Quit griiy", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
editItem.submenu = NSMenu(title: "Edit"); editItem.submenu!.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
menu.addItem(appItem); menu.addItem(editItem); app.mainMenu = menu
let ui = AppUI()
app.delegate = ui
// git runs while the window is being created (as W does).
Thread.detachNewThread {
    var err: UnsafeMutablePointer<CChar>?
    let review = griiy_open(argc, argv, &err)
    let error = take(err)
    DispatchQueue.main.async { ui.loaded(review, error) }
}
app.run()
