// M2-4 (F-PR-5): someone else's Markdown as text we control, and line comments placed on diff rows.
import Foundation
import System
import Testing

@testable import GriiyCore

/// Every way to smuggle a scheme, raw HTML or an image that the parser was seen to let through.
private let evil = """
    Inline <b>tag</b>.

    <script>alert(1)</script> and <img src=x onerror=alert(1)> inline.

    <iframe src="https://evil.example"></iframe>

    [js](javascript:alert(1)) [J](JAVASCRIPT:alert(1)) [v](vbscript:x) [d](data:text/html,x)
    [f](file:///etc/passwd) [r](/relative) [p](//evil.example) [h](http://x.example) [frag](#top)
    <javascript:alert(1)> [x](jav&#x61;script:alert(1)) [y](javascript&colon;alert(1)) [z](<javascript:alert(1)>)
    [![x](https://img.example/i.png)](javascript:alert(1)) [ref][1] www.bare.example foot[^1]
    [u](https://good.example@evil.example/) [n](https:evil.example) [e](https:///x)

    [1]: javascript:alert(1)
    [^1]: note

    | a | b |
    |---|---|
    | [c](javascript:alert(1)) | d |

    <details><summary>s</summary>

    [in](javascript:alert(1))

    </details>

    ![t](https://evil.example/t.png) ![t](http://evil.example/t.png) ![t](file:///etc/passwd)
    """

private func ns(_ s: AttributedString) -> NSAttributedString { NSAttributedString(s) }

private func links(_ s: AttributedString) -> [URL] { s.runs.compactMap(\.link) }

@Test func evilMarkdownKeepsOnlySafeLinksAndNoHTML() {
    let out = markdown(evil)
    let text = String(out.characters)
    // Raw HTML stays characters on screen: neither dropped nor interpreted.
    for literal in ["<script>alert(1)</script>", "onerror=alert(1)", "<iframe", "<details>"] {
        #expect(text.contains(literal), "\(literal) in \(text)")
    }
    for url in links(out) {
        #expect(safeLink(url), "\(url)")
        #expect(["https", "mailto"].contains(url.scheme?.lowercased()), "\(url)")
    }
    #expect(out.runs.compactMap(\.imageURL) == [URL(string: "https://evil.example/t.png")])
    // Nothing but what the app knows how to draw rides along.
    let allowed: Set<String> = ["NSLink", "NSInlinePresentationIntent", "NSImageURL"]
    ns(out).enumerateAttributes(in: NSRange(location: 0, length: ns(out).length)) { attrs, _, _ in
        #expect(Set(attrs.keys.map(\.rawValue)).isSubset(of: allowed), "\(attrs.keys)")
    }
    // The link texts are still there, just not links.
    for word in ["js", "frag", "bare.example", "in"] { #expect(text.contains(word)) }
    #expect(text.contains("[image: t]"))
    // Shown as code, so it reads as the characters someone typed: block HTML and inline tags alike.
    #expect(out.runs.first { String(out[$0.range].characters) == "<b>" }?.inlinePresentationIntent == .code)
    #expect(out.runs.first { String(out[$0.range].characters).contains("<script>") }?.inlinePresentationIntent == .code)
}

@Test func safeLinkAllowsHttpsWithAHostAndMailto() {
    for ok in ["https://a.example/x?y#z", "HTTPS://A.example", "mailto:a@b.example"] {
        #expect(safeLink(URL(string: ok)!), "\(ok)")
    }
    for bad in [
        "http://a.example", "javascript:alert(1)", "https:evil.example", "https:///x", "https://u@evil.example/",
        "https://u:p@evil.example/", "griiy://goto?file=0", "file:///etc/passwd", "/relative", "//evil.example",
        "data:text/html,x", "https://good.example%40evil.example/",
    ] {
        #expect(!safeLink(URL(string: bad)!), "\(bad)")
    }
}

@Test func markdownBlocksBecomeLines() {
    let out = markdown(
        "# Title *em*\r\n\r\nPara **bold** `code` [ok](https://a.example) <x@b.example>\r\n\r\n- one\r\n- two\r\n\r\n1. first\r\n2. second\r\n\r\n> quote\r\n\r\n```swift\r\nlet a = 1\r\nlet b = 2\r\n```\r\n\r\n<!-- template note -->\r\n\r\n| a | b |\r\n|---|---|\r\n| c | d |\r\n\r\nend"
    )
    let text = String(out.characters)
    #expect(
        text == """
            Title em

            Para bold code ok x@b.example

            • one
            • two

            1. first
            2. second

            ▎ quote

            let a = 1
            let b = 2

            a | b
            c | d

            end
            """)
    #expect(links(out) == [URL(string: "https://a.example")!, URL(string: "mailto:x@b.example")!])
    func intent(of word: String) -> InlinePresentationIntent? {
        out.runs.first { String(out[$0.range].characters).contains(word) }?.inlinePresentationIntent
    }
    #expect(intent(of: "Title")?.contains(.stronglyEmphasized) == true)
    #expect(intent(of: "em")?.contains([.stronglyEmphasized, .emphasized]) == true)
    #expect(intent(of: "bold")?.contains(.stronglyEmphasized) == true)
    #expect(intent(of: "let a")?.contains(.code) == true)
}

@Test func imagesAreHttpsOnly() {
    #expect(safeImage(URL(string: "https://a.example/i.png")!))
    #expect(!safeImage(URL(string: "mailto:a@b.example")!) && !safeImage(URL(string: "http://a.example/i.png")!))
    let out = markdown("![](mailto:a@b.example) ![](https://a.example/i.png)")
    #expect(out.runs.compactMap(\.imageURL) == [URL(string: "https://a.example/i.png")])
    // An empty alt isn't U+FFFC on screen.
    #expect(String(out.characters) == "[image: ] [image: ]")
}

@Test func newlinesAndCommentsAsGitHubShowsThem() {
    // A newline inside a paragraph is a line break on GitHub, not a space.
    #expect(String(markdown("a\nb\r\nc").characters) == "a\nb\nc")
    // Comments go; what's between them stays.
    #expect(String(markdown("<!-- a --> real <!-- b -->\n\nnext").characters) == " real \n\nnext")
}

@Test func unparsableMarkdownIsPlainText() {
    #expect(String(markdown("").characters) == "")
    #expect(String(markdown("plain").characters) == "plain")
}

// ---- Line comments on their rows ----

private func thread(_ path: String, _ side: Side, _ lines: Range<Int>?) -> ReviewThread {
    ReviewThread(path: path, side: side, lines: lines, resolved: false, outdated: false, comments: [])
}

private let diffText = """
    diff --git a/a.txt b/a.txt
    index 1111111..2222222 100644
    --- a/a.txt
    +++ b/a.txt
    @@ -1,4 +1,4 @@
     one
    -two
    +TWO
     three
     four
    diff --git a/old.txt b/new.txt
    similarity index 80%
    rename from old.txt
    rename to new.txt
    index 3333333..4444444 100644
    --- a/old.txt
    +++ b/new.txt
    @@ -1,2 +1,2 @@
    -x
    +y
     z

    """

@Test func threadsLandOnTheirLastLine() throws {
    let files = parseDiff(Array(diffText.utf8))
    try #require(files.map(\.path) == ["a.txt", "new.txt"])
    // Rows: 0 header, 1 hunk, 2 " one", 3 "-two", 4 "+TWO", 5 " three", 6 " four".
    let threads = [
        thread("a.txt", .head, 2..<3),  // +TWO
        thread("a.txt", .base, 2..<3),  // -two
        thread("a.txt", .head, 3..<5),  // " three" … " four": the end line
        thread("a.txt", .base, 1..<2),  // " one" by its base number
        thread("a.txt", .head, nil),  // outdated or a file comment
        thread("a.txt", .head, 40..<41),  // not in the diff
        thread("b.txt", .head, 2..<3),  // another file
    ]
    let rows = threadRows(threads, in: files[0])
    #expect(rows.keys.sorted() == [2, 3, 4, 6])
    #expect(rows[4] == [threads[0]] && rows[3] == [threads[1]] && rows[6] == [threads[2]] && rows[2] == [threads[3]])
    // A renamed file: GitHub names it by its new path, on either side.
    let renamed = threadRows([thread("new.txt", .base, 1..<2), thread("new.txt", .head, 1..<2)], in: files[1])
    #expect(renamed.keys.sorted() == [2, 3])
    #expect(threadRows([thread("old.txt", .base, 1..<2)], in: files[1]).isEmpty)
}

@Test func threadsLandInTheWholeFileToo() throws {
    let files = parseDiff(Array(diffText.utf8))
    let f = whole(files[0], path: "a.txt", text: Array("one\nTWO\nthree\nfour\nfive\n".utf8))
    let rows = threadRows([thread("a.txt", .head, 2..<3), thread("a.txt", .head, 5..<6)], in: f)
    let lines = f.rows(from: 0, n: f.rowCount)
    for (r, _) in rows {
        guard case .line(let l) = lines[r] else {
            Issue.record("row \(r) is \(lines[r])")
            continue
        }
        #expect([2, 5].contains(l.newNo ?? 0) && l.kind != .del)
    }
    #expect(rows.count == 2)
}
