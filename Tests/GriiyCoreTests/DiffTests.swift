// M1-3 (F-DV-10): unified diff → files, hunks and lines, from real git output.
import Foundation
import System
import Testing

@testable import GriiyCore

/// Commits `change` on top of `files` and returns the parsed `HEAD~1..HEAD` review.
private func changed(_ name: String, _ files: [(String, String)], _ change: (String) throws -> Void) throws -> [File] {
    let r = repo(name, files)
    try change(r.path)
    git(r.path, ["add", "-A"])
    git(r.path, ["commit", "-qm", "change"])
    return try Review.open(FilePath(r.path), .range(base: "HEAD~1", head: "HEAD", mergeBase: false)).files
}

private func one(_ files: [File], _ path: String) throws -> File {
    let found = files.filter { $0.path == path }
    try #require(found.count == 1, "\(path) in \(files.map(\.path))")
    return found[0]
}

private func lines(_ f: File) -> [Line] { f.hunks.flatMap(\.lines) }
private func line(_ kind: Kind, _ o: Int?, _ n: Int?, _ text: String) -> Line {
    Line(kind: kind, oldNo: o, newNo: n, text: text)
}
private func parse(_ s: String) -> [File] { parseDiff(Array(s.utf8)) }
private func chmod755(_ path: String) { chmod(path, 0o755) }

private let ten = "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n"

@Test func modifiedFileHasHunksWithLineNumbers() throws {
    let files = try changed("mod", [("a.txt", ten)]) { write($0, "a.txt", "1\n2\n3\n4\n5\n6\n7\n8\nnine\n10\n") }
    let f = try one(files, "a.txt")
    #expect(f.status == .modified && f.oldPath == nil && !f.binary)
    #expect(f.oldMode == "100644" && f.newMode == "100644")
    #expect(f.oldBlob?.count == 40 && f.newBlob?.count == 40)
    try #require(f.hunks.count == 1)
    let h = f.hunks[0]
    let ranges: [Int] = [h.oldStart, h.oldLen, h.newStart, h.newLen]
    #expect(ranges == [6, 5, 6, 5])
    #expect(
        Array(lines(f)[2..<6]) == [
            line(.context, 8, 8, "8"), line(.del, 9, nil, "9"), line(.add, nil, 9, "nine"),
            line(.context, 10, 10, "10"),
        ])
    #expect(st(f) == [1, 1])
}

@Test func addedDeletedAndEmptyFiles() throws {
    let files = try changed("adddel", [("gone.txt", "bye\n")]) { d in
        try FileManager.default.removeItem(atPath: d + "/gone.txt")
        write(d, "new.txt", "hi\n")
        write(d, "empty.txt", "")
    }
    var f = try one(files, "new.txt")
    #expect(f.status == .added && f.oldMode == nil && f.newMode == "100644" && f.oldBlob == nil)
    #expect(lines(f) == [line(.add, nil, 1, "hi")])
    f = try one(files, "gone.txt")
    #expect(f.status == .deleted && f.oldMode == "100644" && f.newMode == nil && f.newBlob == nil)
    #expect(lines(f) == [line(.del, 1, nil, "bye")])
    // No hunk and no ---/+++: the name comes from the `diff --git` line alone.
    f = try one(files, "empty.txt")
    #expect(f.status == .added && f.hunks.isEmpty && !f.binary)
}

@Test func renamesAndCopies() throws {
    // Distinct bodies, so each rename or copy has exactly one possible source.
    let body = { (tag: String) in (1...8).map { "\(tag)\($0)\n" }.joined() }
    let (old, edit, src) = (body("o"), body("e"), body("s"))
    let files = try changed("rename", [("old.txt", old), ("edit-old.txt", edit), ("src.txt", src)]) { d in
        try FileManager.default.createDirectory(atPath: d + "/dir", withIntermediateDirectories: false)
        git(d, ["mv", "old.txt", "dir/new.txt"])
        git(d, ["mv", "edit-old.txt", "edit-new.txt"])
        write(d, "edit-new.txt", edit.replacingOccurrences(of: "e8", with: "E8"))
        // -C finds copies whose source changed in the same diff (PLAN-M1-3 R6).
        write(d, "copy.txt", src)
        write(d, "src.txt", src.replacingOccurrences(of: "s1", with: "S1"))
    }
    var f = try one(files, "dir/new.txt")
    #expect(f.status == .renamed && f.oldPath == "old.txt" && f.hunks.isEmpty)
    f = try one(files, "edit-new.txt")
    #expect(f.status == .renamed && f.oldPath == "edit-old.txt" && st(f) == [1, 1])
    f = try one(files, "copy.txt")
    #expect(f.status == .copied && f.oldPath == "src.txt")
    #expect(try one(files, "src.txt").status == .modified)
}

@Test func binaryModeAndTypeChanges() throws {
    let files = try changed("bin", [("b.dat", "\0\u{1}"), ("run.sh", "echo\n"), ("link", "target\n")]) { d in
        write(d, "b.dat", "\0\u{2}")
        write(d, "새 그림.png", "\0png")
        chmod755(d + "/run.sh")
        try FileManager.default.removeItem(atPath: d + "/link")
        try FileManager.default.createSymbolicLink(atPath: d + "/link", withDestinationPath: "b.dat")
    }
    var f = try one(files, "b.dat")
    #expect(f.status == .modified && f.binary && f.hunks.isEmpty)
    // Quoted name, and the `diff --git` line is its only source.
    f = try one(files, "새 그림.png")
    #expect(f.status == .added && f.binary)
    f = try one(files, "run.sh")
    #expect(f.oldMode == "100644" && f.newMode == "100755" && f.hunks.isEmpty)
    // File → symlink is two blocks for one path: a deletion and an addition.
    let link = files.filter { $0.path == "link" }
    #expect(link.map(\.status) == [.deleted, .added] && link.map(\.newMode) == [nil, "120000"])
}

@Test func noNewlineAndCRLF() throws {
    let files = try changed("eol", [("a.txt", "x"), ("b.txt", "keep\nx"), ("crlf.txt", "a\r\nb\r\n")]) { d in
        write(d, "a.txt", "y")
        write(d, "b.txt", "keep\nx\nmore\n")
        write(d, "crlf.txt", "a\r\nB\r\n")
    }
    let a = try one(files, "a.txt")
    // The marker in the middle of the hunk, and at the end.
    #expect(a.hunks[0].lines.map { "\($0.text):\($0.noNewline)" } == ["x:true", "y:true"])
    let b = try one(files, "b.txt")
    var want = [
        line(.context, 1, 1, "keep"), line(.del, 2, nil, "x"), line(.add, nil, 2, "x"), line(.add, nil, 3, "more"),
    ]
    want[1].noNewline = true
    #expect(b.hunks[0].lines == want)
    // The \r stays, so line text matches the blob byte for byte.
    #expect(Array(lines(try one(files, "crlf.txt"))[1...]) == [line(.del, 2, nil, "b\r"), line(.add, nil, 2, "B\r")])
}

@Test func awkwardNames() throws {
    let names = ["a b.txt", "é.txt", "q\"uo.txt", "back\\slash.txt", "tab\there.txt", "x é y.txt", "diff --git a b"]
    let files = try changed("names", names.map { ($0, "1\n") }) { d in for n in names { write(d, n, "2\n") } }
    for n in names {
        let f = try one(files, n)
        #expect(f.status == .modified && st(f) == [1, 1], "\(n)")
    }
}

@Test func contentThatLooksLikeHeaders() throws {
    let patch = "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n"
    let files = try changed("meta", [("p.diff", patch)]) {
        write($0, "p.diff", patch.replacingOccurrences(of: "@@ -1", with: "@@ -2"))
    }
    #expect(files.count == 1)
    let f = try one(files, "p.diff")
    #expect(st(f) == [1, 1])
    #expect(lines(f).contains { $0.kind == .context && $0.text == "diff --git a/x b/x" })
}

private struct Key: Equatable {
    var path: String, oldPath: String?, status: Status, newMode: String?, binary: Bool, lines: [Line]
}

private func configured(_ cfg: [(String, String)]) throws -> [Key] {
    let r = repo(
        "cfg", [("a b.txt", ten), ("é.txt", ten), ("old.txt", ten), ("blank.txt", "a\n\nb\n"), ("b.bin", "\0")])
    for (k, v) in cfg { git(r.path, ["config", k, v]) }
    write(r.path, "a b.txt", ten.replacingOccurrences(of: "5", with: "five"))
    write(r.path, "é.txt", ten.replacingOccurrences(of: "9", with: "nine"))
    write(r.path, "blank.txt", "A\n\nb\n")
    // Named only by the `diff --git` line, where prefixes and quoting matter most.
    write(r.path, "b.bin", "\0\u{1}")
    chmod755(r.path + "/é.txt")
    git(r.path, ["mv", "old.txt", "new.txt"])
    git(r.path, ["add", "-A"])
    git(r.path, ["commit", "-qm", "c"])
    let files = try Review.open(FilePath(r.path), .range(base: "HEAD~1", head: "HEAD", mergeBase: false)).files
    return files.map {
        Key(
            path: $0.path, oldPath: $0.oldPath, status: $0.status, newMode: $0.newMode, binary: $0.binary,
            lines: lines($0))
    }
}

@Test(arguments: [
    ("diff.noprefix", "true"), ("diff.mnemonicPrefix", "true"), ("diff.renames", "false"), ("core.quotePath", "false"),
    ("diff.suppressBlankEmpty", "true"), ("diff.external", "false"), ("diff.context", "0"), ("diff.relative", "true"),
    ("color.ui", "always"),
])
func userConfigDoesNotChangeTheResult(key: String, value: String) throws {
    #expect(try configured([(key, value)]) == configured([]))
}

@Test func worktreeModeIsParsedToo() throws {
    let r = repo("wtdiff", [("a.txt", "a\n")])
    write(r.path, "a.txt", "b\n")
    let f = try one(try Review.open(FilePath(r.path), .default).files, "a.txt")
    #expect(f.status == .modified && st(f) == [1, 1])
}

@Test func handMadeInputNeverTraps() throws {
    #expect(parse("").isEmpty)
    for text in [
        "diff --git a/x b/x\n@@ -1,2 +1,2 @@\n",  // hunk cut short
        "diff --git a/x b/x\n@@ -zz +1 @@\n+a\n",
        "diff --git a/x b/x\n@@ -1 +1\n",
        "diff --git \"a/\\3\" \"b/\\",  // broken escapes, no newline at end
        "diff --git \"a/unterminated\n",
        "diff --git\n",
        "\\ No newline at end of file\n",
        "+orphan line\n",
        "diff --git a/x b/x\n--- \"a/x\\\n+++ b/x\t\n@@ -1 +1 @@\n-a\n+b\n\\\n\\\n",
    ] {
        _ = parse(text)
    }
    let f = try #require(parse("diff --git a/x b/x\nindex 1..2 100644\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n").first)
    #expect(f.path == "x" && st(f) == [1, 1])
}

@Test func octalEscapesDecodeToUTF8() throws {
    let f = try #require(
        parse(
            "diff --git \"a/\\355\\225\\234 \\\"q\\\\.txt\" \"b/\\355\\225\\234 \\\"q\\\\.txt\"\nnew file mode 100644\nindex 0000000..1111111\n"
        ).first)
    #expect(f.path == "한 \"q\\.txt" && f.status == .added)
}

@Test func hostileHunkHeaders() throws {
    // Past git's 32-bit line numbers: the hunk is rejected.
    #expect(try #require(parse("diff --git a/x b/x\n@@ -4294967295 +1 @@\n x\n").first).hunks.isEmpty)
    // Close to the limit with context lines after it: Rust wrapped, Swift would trap on UInt32.
    let near = "diff --git a/x b/x\n@@ -4294967290,1 +1,100 @@\n" + String(repeating: " c\n", count: 100)
    #expect(try #require(parse(near).first).hunks.first?.lines.count == 100)
    // A bad header later in a file keeps the good hunks before it.
    #expect(st(try #require(parse("diff --git a/x b/x\n@@ -1 +1 @@\n-a\n+b\n@@ -zz +1 @@\n+c\n").first)) == [1, 1])
    // A hunk cut short gets no phantom line from the text's final newline.
    #expect(try #require(parse("diff --git a/x b/x\n@@ -1,2 +1,2 @@\n").first).hunks[0].lines.isEmpty)
}

@Test func multipleHunksAndSections() throws {
    let body = (1...30).map { "\($0)\n" }.joined()
    let src = "fn main() {\n\(body)}\n"
    let files = try changed("hunks", [("m.rs", src)]) {
        write(
            $0, "m.rs",
            src.replacingOccurrences(of: "\n3\n", with: "\nthree\n").replacingOccurrences(of: "\n28\n", with: "\n"))
    }
    let f = try one(files, "m.rs")
    #expect(
        f.hunks.map { "\($0.oldStart),\($0.oldLen),\($0.newStart),\($0.newLen),\($0.section)" } == [
            "1,7,1,7,", "26,7,26,6,fn main() {",
        ])
    let del = try #require(lines(f).first { $0.kind == .del && $0.text == "28" })
    #expect(del.oldNo == 29 && del.newNo == nil)
}

@Test func namesThatAreNotUTF8DecodeLossily() throws {
    #expect(
        try #require(parse("diff --git \"a/\\377x\" \"b/\\377x\"\nindex 1111111..2222222 100644\n").first).path
            == "\u{FFFD}x")
}

@Test func rowCountMatchesRows() throws {
    let files = try changed("rows", [("a.txt", ten), ("b.dat", "\0"), ("run.sh", "x\n"), ("gone.txt", "g\n")]) { d in
        write(d, "a.txt", ten.replacingOccurrences(of: "2", with: "two").replacingOccurrences(of: "9", with: "nine"))
        write(d, "b.dat", "\0\u{1}")
        chmod755(d + "/run.sh")
        try FileManager.default.removeItem(atPath: d + "/gone.txt")
        write(d, "empty.txt", "")
        write(d, "eof.txt", "no newline")
    }
    for f in files {
        // Any window of rows is the same slice of the whole.
        let all = f.rows(from: 0, n: .max)
        for (from, n) in [(0, 1), (1, 2), (2, 3), (3, 100), (all.count - 1, 5), (all.count, 5)] {
            #expect(
                f.rows(from: from, n: n) == Array(all[min(from, all.count)..<min(from + n, all.count)]),
                "\(f.path) \(from)+\(n)")
        }
        #expect(all.count == f.rowCount && all.first == .fileHeader, "\(f.path)")
    }
    // Out-of-range windows clamp, never trap.
    let f = files[0]
    #expect(f.rows(from: -1, n: 1) == [.fileHeader] && f.rows(from: .min, n: .max).count == f.rowCount)
    #expect(f.rows(from: 0, n: -5).isEmpty && f.rows(from: .max, n: .max).isEmpty)
    // Files without hunks say why in one note row.
    let note = { (p: String) in try one(files, p).rows(from: 1, n: 1) }
    #expect(try note("b.dat") == [.note("Binary file")])
    #expect(try note("run.sh") == [.note("Mode 100644 → 100755")])
    #expect(try note("empty.txt") == [.note("No content changes")])
    // The no-newline marker is a flag on its line, not a row.
    var eof = line(.add, nil, 1, "no newline")
    eof.noNewline = true
    #expect(try one(files, "eof.txt").rows(from: 2, n: 1) == [.line(eof)])
}

// M1-4 (F-AI-1): a selection on one side ↔ line ranges on both.
@Test func selectionsMapToBothSides() throws {
    let forty = (1...40).map { "\($0)\n" }.joined()
    // Base 5 deleted; base 15-16 replaced by three lines; one line added after base 30.
    let files = try changed("span", [("a.txt", forty), ("gone.txt", "g\nh\n")]) { d in
        write(
            d, "a.txt",
            forty.replacingOccurrences(of: "\n5\n", with: "\n").replacingOccurrences(
                of: "\n15\n16\n", with: "\nx\ny\nz\n"
            )
            .replacingOccurrences(of: "\n30\n", with: "\n30\nnew\n"))
        write(d, "new.txt", "a\nb\nc\n")
        try FileManager.default.removeItem(atPath: d + "/gone.txt")
    }
    let f = try one(files, "a.txt")
    #expect(
        f.hunks.map { "\($0.oldStart),\($0.oldLen),\($0.newStart),\($0.newLen)" } == [
            "2,7,2,6", "12,8,11,9", "28,6,28,7",
        ])
    let cases: [(Side, Range<Int>, Range<Int>, Range<Int>)] = [
        (.base, 5..<6, 5..<6, 5..<5),  // delete only: an empty range where it was
        (.head, 31..<32, 31..<31, 31..<32),  // add only
        (.base, 15..<16, 15..<16, 14..<17),  // half a replacement maps to the whole block
        (.head, 15..<16, 15..<17, 15..<16),
        (.head, 14..<17, 15..<17, 14..<17),  // only the added side of a replacement
        (.base, 14..<17, 14..<17, 13..<17),  // context and changes
        (.head, 13..<18, 14..<18, 13..<18),
        (.base, 10..<14, 10..<14, 9..<13),  // from a gap into a hunk
        (.base, 3..<21, 3..<21, 3..<21),  // across hunks and gaps
        (.base, 20..<21, 20..<21, 20..<21),  // between hunks the offsets cancel
        (.head, 40..<42, 39..<41, 40..<42),  // after the last hunk
        (.base, 1..<2, 1..<2, 1..<2),  // before the first
    ]
    for (side, sel, base, head) in cases {
        let s = f.span(side, sel)
        #expect(s.base == base && s.head == head, "\(side) \(sel): \(s)")
    }
    #expect(try one(files, "new.txt").span(.head, 2..<4) == (1..<1, 2..<4))
    #expect(try one(files, "gone.txt").span(.base, 1..<3) == (1..<3, 1..<1))
}

@Test func zeroContextInsertionMapsAroundIt() throws {
    // `@@ -5,0 …`: the insertion comes after base line 5.
    let f = try #require(parse("diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -5,0 +6,2 @@\n+x\n+y\n").first)
    #expect(f.span(.base, 5..<7) == (5..<7, 5..<9))
    #expect(f.span(.head, 6..<8) == (6..<6, 6..<8))
}

@Test func extremeSelectionsNeverTrap() throws {
    let f = try #require(parse("diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -1,0 +2,1 @@\n+x\n").first)
    for side in [Side.base, .head] {
        for sel in [Int.min..<Int.min, Int.min..<Int.max, (Int.max - 1)..<Int.max, 0..<0] { _ = f.span(side, sel) }
    }
}

// M1-12: `n`/`p` stop where a change block starts.
@Test func changeBlocksStartAfterContextOrHeader() throws {
    let files = parse(
        """
        diff --git a/a b/a
        --- a/a
        +++ b/a
        @@ -1,6 +1,6 @@
        -one
        +ONE
         two
         three
        -four
         five
        +five and a half
        @@ -20,2 +20,3 @@
         twenty
        +twenty-one
         twenty-two
        diff --git a/b b/b
        Binary files a/b and b/b differ

        """)
    try #require(files.count == 2)
    let f = files[0]
    // Row 0 file header, 1 hunk header, 2 -one, 3 +ONE, 4 two, 5 three, 6 -four, 7 five,
    // 8 +five…, 9 hunk header, 10 twenty, 11 +twenty-one.
    #expect(f.changes == [2, 6, 8, 11])
    for r in f.changes {
        let rows = f.rows(from: r - 1, n: 2)
        guard case .line(let l) = rows[1] else {
            Issue.record("row \(r) is \(rows[1])")
            continue
        }
        #expect(l.kind != .context)
        if case .line(let before) = rows[0] { #expect(before.kind == .context) }
    }
    #expect(files[1].changes.isEmpty)
    // The whole-file view keeps the blocks, now between unchanged lines.
    let w = whole(
        f, path: "a",
        text: Array(
            (["ONE", "two", "three", "five", "five and a half"]
                + (6...19).map(String.init) + ["twenty", "twenty-one", "twenty-two"]).joined(separator: "\n").utf8 + [
                    10
                ]))
    #expect(w.changes.count == 4)
}
