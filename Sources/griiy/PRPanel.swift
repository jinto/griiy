// The PR panel (F-PR-4) and the thread popover: PR text drawn by AppKit, never read as HTML
// (F-PR-5). Core's `markdown` already dropped every link but https and mailto; this side builds
// its text from plain strings, fonts and those links only, takes every link click itself, and
// fetches an image only when its "show image" is clicked.
import AppKit
import GriiyCore
import ImageIO

private let body = NSFont.systemFont(ofSize: 13)
private let small = NSFont.systemFont(ofSize: 11)

/// Selectable read-only text in a scroll view. Links to griiy:// are the app's own (an image to
/// show, a thread to go to); user text can't make one, since only `safeLink`s survive `markdown`.
final class TextPane: NSObject, NSTextViewDelegate {
    let scroll = NSTextView.scrollableTextView()
    var text: NSTextView { scroll.documentView as? NSTextView ?? NSTextView() }
    /// Images by the `n` of their `griiy://image?n=` link.
    private var images: [URL] = []
    /// Bumped by `show`: an image fetched for earlier text doesn't land in this one.
    private var shown = 0
    /// `griiy://goto?t=<n>`: the panel's thread `n` was clicked.
    var onGoto: (Int) -> Void = { _ in }

    override init() {
        super.init()
        text.isEditable = false
        text.isSelectable = true
        text.textContainerInset = NSSize(width: 12, height: 12)
        text.backgroundColor = Palette.bg
        text.delegate = self
        scroll.hasHorizontalScroller = false
    }

    func show(_ s: NSAttributedString, images: [URL]) {
        self.images = images
        shown += 1
        text.textStorage?.setAttributedString(s)
        text.scrollToBeginningOfDocument(nil)
    }

    // Always true: AppKit's own handling opens any URL scheme with NSWorkspace.
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = link as? URL else { return true }
        if url.scheme == "griiy" {
            let n = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value.flatMap {
                Int($0)
            }
            if url.host() == "image", let n, n < images.count { load(n) }
            if url.host() == "goto", let n { onGoto(n) }
        } else if safeLink(url) {
            NSWorkspace.shared.open(url)
        }
        return true
    }

    /// Fetches image `n` and puts it where its "show image" link was. The link turns into a
    /// link-less "loading…" at once, so a second click doesn't fetch it again.
    private func load(_ n: Int) {
        guard let storage = text.textStorage, let loading = find(.link, URL(string: "griiy://image?n=\(n)"))
        else { return }
        storage.replaceCharacters(
            in: loading,
            with: NSAttributedString(string: "loading…", attributes: muted(small).merging([imageKey: n]) { $1 }))
        let (url, mine) = (images[n], shown)
        let width = Int(text.bounds.width - 40)
        let scale = text.window?.backingScaleFactor ?? 2
        Task {
            let image = await fetchImage(url, maxPixels: Int(CGFloat(width) * scale))
            guard mine == shown, let found = find(imageKey, n) else { return }
            guard let image else {
                storage.replaceCharacters(
                    in: found, with: NSAttributedString(string: "can't show image", attributes: muted(small)))
                return
            }
            image.size = NSSize(width: image.size.width / scale, height: image.size.height / scale)
            let attachment = NSTextAttachment()
            attachment.image = image
            storage.replaceCharacters(in: found, with: NSAttributedString(attachment: attachment))
        }
    }

    /// The first range whose `key` is `value`.
    private func find<T: Equatable>(_ key: NSAttributedString.Key, _ value: T?) -> NSRange? {
        guard let storage = text.textStorage, let value else { return nil }
        var found: NSRange?
        storage.enumerateAttribute(key, in: NSRange(location: 0, length: storage.length)) { v, r, stop in
            if v as? T == value { (found, stop.pointee) = (r, true) }
        }
        return found
    }
}

/// Marks the "loading…" that a fetched image `n` replaces.
private let imageKey = NSAttributedString.Key("griiyImage")

private func muted(_ font: NSFont) -> [NSAttributedString.Key: Any] { [.font: font, .foregroundColor: Palette.mut] }

/// Core's Markdown as AppKit text, made run by run from characters, a font, a color and the link:
/// nothing else of the parsed string reaches the text view. Each https image gets a "show image"
/// link, numbered in `images`.
func richText(_ md: AttributedString, images: inout [URL]) -> NSAttributedString {
    let s = NSMutableAttributedString()
    for run in md.runs {
        let intent = run.inlinePresentationIntent ?? []
        var font = intent.contains(.code) ? mono : body
        var traits: NSFontDescriptor.SymbolicTraits = []
        if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
        if intent.contains(.emphasized) { traits.insert(.italic) }
        if !traits.isEmpty {
            font = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(traits), size: font.pointSize) ?? font
        }
        var a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Palette.fg]
        if intent.contains(.strikethrough) { a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if let url = run.link, safeLink(url) { a[.link] = url }
        let text = String(md[run.range].characters)
        guard let image = run.imageURL, safeImage(image) else {
            s.append(NSAttributedString(string: text, attributes: a))
            continue
        }
        s.append(NSAttributedString(string: text + " ", attributes: muted(body)))
        if let link = URL(string: "griiy://image?n=\(images.count)") {
            s.append(NSAttributedString(string: "show image", attributes: [.font: body, .link: link]))
            images.append(image)
        }
    }
    return s
}

/// The panel's text: the PR, its linked issues, comments and line comments, oldest first.
func panelText(_ pr: PullRequest, label: String, images: inout [URL]) -> NSAttributedString {
    let s = NSMutableAttributedString()
    func add(_ text: String, _ a: [NSAttributedString.Key: Any]) {
        s.append(NSAttributedString(string: text, attributes: a))
    }
    func link(_ text: String, _ url: URL?) {
        var a = muted(small)
        if let url, url.scheme == "griiy" || safeLink(url) { a[.link] = url }
        add(text, a)
    }
    func md(_ text: String) {
        s.append(
            text.isEmpty
                ? NSAttributedString(string: "No description.", attributes: muted(body))
                : richText(markdown(text), images: &images))
        add("\n\n", [.font: body])
    }
    func heading(_ text: String) {
        add(text + "\n", [.font: NSFont.boldSystemFont(ofSize: 13), .foregroundColor: Palette.fg])
    }

    add(pr.title + "\n", [.font: NSFont.boldSystemFont(ofSize: 17), .foregroundColor: Palette.fg])
    add("\(label) · \(pr.author) · \(pr.state.lowercased()) · ", muted(small))
    link("on GitHub", URL(string: pr.url))
    add("\n\n", [.font: body])
    md(pr.body)
    if !pr.issues.isEmpty {
        heading("Linked issues")
        for i in pr.issues {
            link("\(i.repo)#\(i.number) \(i.title) (\(i.state.lowercased()))", URL(string: i.url))
            add("\n", [.font: small])
        }
        add("\n", [.font: body])
    }
    for c in pr.comments {
        let kind: String
        switch c.kind {
        case .issue, .reviewComment: kind = ""
        case .review(let state): kind = " · " + state.lowercased().replacingOccurrences(of: "_", with: " ")
        }
        heading(c.author)
        add(String(c.created.prefix(10)) + kind + "\n", muted(small))
        md(c.body)
    }
    if !pr.threads.isEmpty { heading("Line comments") }
    for (n, t) in pr.threads.enumerated() {
        let place = t.path + (t.lines.map { ":\($0.upperBound - 1)" } ?? "")
        if t.lines != nil { link(place, URL(string: "griiy://goto?t=\(n)")) } else { add(place, muted(small)) }
        add((t.outdated ? " · outdated" : "") + (t.resolved ? " · resolved" : "") + "\n", muted(small))
        s.append(threadText(t, images: &images))
    }
    if pr.truncated { link("More on GitHub", URL(string: pr.url)) }
    return s
}

/// One thread's comments: author, date and the comment, in reply order.
func threadText(_ t: ReviewThread, images: inout [URL]) -> NSAttributedString {
    let s = NSMutableAttributedString()
    for c in t.comments {
        s.append(
            NSAttributedString(
                string: c.author, attributes: [.font: NSFont.boldSystemFont(ofSize: 12), .foregroundColor: Palette.fg]))
        s.append(NSAttributedString(string: "  " + String(c.created.prefix(10)) + "\n", attributes: muted(small)))
        s.append(richText(markdown(c.body), images: &images))
        s.append(NSAttributedString(string: "\n\n", attributes: [.font: body]))
    }
    return s
}

// ---- "show image": one https image, on click ----

/// No cookies, credentials or cache: the request carries nothing of the user's.
nonisolated private let imageSession: URLSession = {
    let c = URLSessionConfiguration.ephemeral
    c.httpShouldSetCookies = false
    c.httpCookieStorage = nil
    c.urlCredentialStorage = nil
    c.urlCache = nil
    c.timeoutIntervalForRequest = 15
    c.timeoutIntervalForResource = 60
    return URLSession(configuration: c)
}()

/// Every redirect is checked again.
nonisolated private final class Redirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        request.url.map(safeImage) == true ? request : nil
    }
}

nonisolated private let imageLimit = 10 << 20
nonisolated private let rasterTypes: Set<String> = [
    "public.png", "public.jpeg", "com.compuserve.gif", "org.webmproject.webp",
]

/// The image at `url`, at most `maxPixels` on its long side; nil if it isn't a `safeImage`, is
/// over 10MB, or isn't a PNG, JPEG, GIF or WebP. The size bound decodes a 20k×20k image small.
// ponytail: decoded by ImageIO in this process. A sandboxed helper if that ever needs to change.
nonisolated func fetchImage(_ url: URL, maxPixels: Int) async -> NSImage? {
    guard safeImage(url), let (bytes, response) = try? await imageSession.bytes(from: url, delegate: Redirects()),
        (response as? HTTPURLResponse)?.statusCode == 200, response.expectedContentLength <= imageLimit
    else { return nil }
    var data = Data()
    do {
        for try await b in bytes {
            data.append(b)
            if data.count > imageLimit { return nil }
        }
    } catch {
        return nil
    }
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
        rasterTypes.contains(CGImageSourceGetType(source) as String? ?? ""),
        let image = CGImageSourceCreateThumbnailAtIndex(
            source, 0,
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(maxPixels, 64),
            ] as CFDictionary)
    else { return nil }
    return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
}
