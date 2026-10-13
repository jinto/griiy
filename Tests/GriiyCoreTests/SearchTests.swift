// M1-11 (F-DV-7): ⌘P fuzzy file search and `/` diff text search.
import Foundation
import Testing

@testable import GriiyCore

private func ranked(_ q: String, _ paths: [String], limit: Int = 50) -> [String] {
    fuzzy(q, in: paths, limit: limit).map { paths[$0] }
}

@Test func fuzzyKeepsOnlySubsequences() {
    #expect(ranked("abc", ["a/b/c", "xaybzc", "acb", "ab"]) == ["a/b/c", "xaybzc"])
    #expect(ranked("DV", ["src/DiffView.swift", "docs/x.md"]) == ["src/DiffView.swift"])
}

@Test func fuzzyPrefersExactBasenameThenBasenamePrefix() {
    let paths = ["src/main.swift.orig", "tools/domain.swift", "main.swift/readme", "src/main.swift"]
    #expect(ranked("main.swift", paths).first == "src/main.swift")
    #expect(ranked("tree", ["docs/street.md", "Sources/griiy/TreeView.swift"]).first == "Sources/griiy/TreeView.swift")
}

@Test func fuzzyPrefersWordBoundaries() {
    let paths = ["docs/devlog/advanced.md", "Sources/griiy/DiffView.swift"]
    #expect(ranked("dv", paths).first == "Sources/griiy/DiffView.swift")
    #expect(ranked("ab", ["xaxb", "xabx"]) == ["xabx", "xaxb"])
    #expect(ranked("abc", ["a_b_c.txt", "abc.txt"]).first == "abc.txt")
}

@Test func fuzzyPrefersMatchesInTheFileName() {
    #expect(ranked("readme", ["readme/x.c", "docs/README.md"]).first == "docs/README.md")
    // "view" first occurs in the folder; the file name's View is the better match.
    #expect(ranked("view", ["src/overview.c", "docs/review/TreeView.swift"]).first == "docs/review/TreeView.swift")
}

@Test func fuzzyEmptyQueryKeepsOrderUpToLimit() {
    let paths = (0..<100).map { "f\($0)" }
    #expect(fuzzy("", in: paths, limit: 3) == [0, 1, 2])
    #expect(fuzzy("f", in: paths, limit: 5).count == 5)
    #expect(fuzzy("f", in: paths, limit: -1).isEmpty && fuzzy("", in: paths, limit: -1).isEmpty)
    // Ties keep the given order.
    #expect(ranked("x", ["b/x", "a/x"]) == ["b/x", "a/x"])
}

@Test func fuzzyHandlesNonAscii() {
    #expect(ranked("한글", ["docs/한글.txt", "docs/hangul.txt"]) == ["docs/한글.txt"])
}

/// The 50ms target is for the shipped (optimized) build; debug code runs 10–200× slower, so
/// `swift test` only catches a blow-up. Measure: `swift test -c release -Xswiftc -enable-testing`.
#if DEBUG
    private let budget = 500.0
#else
    private let budget = 50.0
#endif

@Test func fuzzyOverTenThousandPathsIsFast() {
    let dirs = ["Sources/GriiyCore", "Sources/griiy/views", "Tests/GriiyCoreTests/fixtures", "docs/design/notes"]
    let paths = (0..<10_000).map { i in "\(dirs[i % 4])/m\(i % 37)/component_\(i)_View\(i % 7).swift" }
    for q in ["v", "cv", "comp", "m3cv", "component_9999"] {
        let t = Date()
        let hits = fuzzy(q, in: paths)
        let ms = Date().timeIntervalSince(t) * 1000
        #expect(!hits.isEmpty)
        print("fuzzy \(q): \(Int(ms))ms")
        #expect(ms < budget)
    }
    #expect(ranked("component_9999", paths).first?.contains("component_9999_") == true)
}

// ---- diff search ----

private func file(_ path: String, _ hunks: [[String]]) -> File {
    var f = File(path: path, status: .modified)
    var n = 1
    for texts in hunks {
        var h = Hunk(oldStart: n, oldLen: texts.count, newStart: n, newLen: texts.count, section: "")
        h.lines = texts.map { t in
            defer { n += 1 }
            return Line(kind: .context, oldNo: n, newNo: n, text: t)
        }
        f.hunks.append(h)
    }
    return f
}

private func text(_ files: [File], _ h: Hit) -> String? {
    guard case .line(let l) = files[h.file].rows(from: h.row, n: 1).first else { return nil }
    return l.text
}

@Test func searchFindsRowsInOrderAcrossHunksAndFiles() {
    let files = [file("a", [["x", "needle 1"], ["needle 2"]]), file("b", [[]]), file("c", [["y", "z needle"]])]
    let hits = search(files, for: "needle")
    // header 0, hunk 1, x 2, needle 3, hunk 4, needle 5 · c: header 0, hunk 1, y 2, z needle 3
    #expect(hits == [Hit(file: 0, row: 3), Hit(file: 0, row: 5), Hit(file: 2, row: 3)])
    #expect(hits.map { text(files, $0) } == ["needle 1", "needle 2", "z needle"])
}

@Test func searchIsSmartCase() {
    let files = [file("a", [["Foo", "foo", "FOO"]])]
    #expect(search(files, for: "foo").count == 3)
    #expect(search(files, for: "Foo") == [Hit(file: 0, row: 2)])
    #expect(search(files, for: "").isEmpty)
}

@Test func searchSkipsHeadersAndFilesWithoutHunks() {
    var binary = File(path: "needle.png", status: .added)
    binary.binary = true
    let files = [binary, file("needle.txt", [["a"]])]
    #expect(search(files, for: "needle").isEmpty)
}

@Test func searchReachesTheLastOf120kLines() {
    let files = (0..<300).map { f in
        file("src/file\(f).swift", [(0..<400).map { "    let v_\(f)_\($0) = compute(\($0), \"a\");" }])
    }
    let t = Date()
    let hits = search(files, for: "v_299_399 ")
    let ms = Date().timeIntervalSince(t) * 1000
    #expect(hits == [Hit(file: 299, row: 401)])
    print("search 120k lines: \(Int(ms))ms")
    #expect(search(files, for: "COMPUTE").isEmpty && search(files, for: "compute").count == 120_000)
}

@Test func searchEdgeCases() {
    var f = file("a", [["두 번 needle needle", "한글 검색", "crlf end\r"]])
    f.hunks[0].section = "needle in section"
    let files = [f]
    // Twice in a line is one hit; hunk header text isn't searched.
    #expect(search(files, for: "needle") == [Hit(file: 0, row: 2)])
    #expect(search(files, for: "글 검") == [Hit(file: 0, row: 3)])
    #expect(search(files, for: "end") == [Hit(file: 0, row: 4)])
    #expect(search(files, for: "needles").isEmpty)
}

@Test func fuzzyQueryWithSlashSpansFolders() {
    #expect(ranked("src/m", ["main.swift", "src/x/main.swift", "lib/src.md"]) == ["src/x/main.swift"])
}
