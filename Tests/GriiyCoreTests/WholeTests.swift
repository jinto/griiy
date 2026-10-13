// M1-10 (F-DV-5): any file, whole, with its changes in place.
import Foundation
import System
import Testing

@testable import GriiyCore

private let twenty = (1...20).map { "\($0)\n" }.joined()

/// Committed: a.txt changed at lines 2 and 19, gone.txt deleted, same.txt and 한글.txt untouched.
private func committed(_ name: String) -> (TempDir, Review) {
    let r = repo(name, [("a.txt", twenty), ("gone.txt", "g\nh\n"), ("same.txt", "s\nt"), ("한글.txt", "k\n")])
    var a = (1...20).map(String.init)
    a[1] = "two"
    a.remove(at: 18)
    write(r.path, "a.txt", a.map { $0 + "\n" }.joined())
    try? FileManager.default.removeItem(atPath: r.path + "/gone.txt")
    git(r.path, ["commit", "-qam", "change"])
    // Only in the index: the commit's tree, not the index, is what head has.
    write(r.path, "staged.txt", "x\n")
    git(r.path, ["add", "staged.txt"])
    let review = try! Review.open(FilePath(r.path), .range(base: "HEAD~1", head: "HEAD", mergeBase: false))
    return (r, review)
}

private func texts(_ f: File) -> [String] { f.hunks.flatMap(\.lines).map(\.text) }

@Test func changedFileShowsEveryLineWithChangesInPlace() throws {
    let (r, review) = committed("whole-mod")
    defer { withExtendedLifetime(r) {} }
    let f = try review.whole("a.txt")
    #expect(texts(f) == ["1", "2", "two"] + (3...20).map(String.init))
    let rows = f.hunks.flatMap(\.lines)
    #expect(rows.map(\.kind) == [.context, .del, .add] + Array(repeating: .context, count: 16) + [.del, .context])
    // Lines between the hunks (6–15) come from the text with both numbers; after the deleted 19,
    // base and head differ by one.
    #expect(rows[10].text == "10" && rows[10].oldNo == 10 && rows[10].newNo == 10)
    #expect(rows.count == 21 && rows[20].oldNo == 20 && rows[20].newNo == 19)
    let h = try #require(f.hunks.first)
    #expect([h.oldStart, h.oldLen, h.newStart, h.newLen] == [1, 20, 1, 19] && f.hunks.count == 1)
    // A selection maps the same in the whole file as in the diff (M3-2 relies on it).
    let diff = try #require(review.files.first { $0.path == "a.txt" })
    for (side, sel) in [(Side.base, 2..<3), (.head, 2..<3), (.base, 19..<20), (.head, 4..<17), (.base, 1..<21)] {
        #expect(f.span(side, sel) == diff.span(side, sel), "\(side) \(sel)")
    }
}

@Test func unchangedAndDeletedFiles() throws {
    let (r, review) = committed("whole-same")
    defer { withExtendedLifetime(r) {} }
    let same = try review.whole("same.txt")
    #expect(same.status == .unchanged && texts(same) == ["s", "t"])
    #expect(same.hunks.flatMap(\.lines).allSatisfy { $0.kind == .context && $0.oldNo == $0.newNo })
    #expect(same.hunks.last?.lines.last?.noNewline == true)
    // Deleted: the base version, every line, straight from the diff.
    let gone = try review.whole("gone.txt")
    #expect(gone.status == .deleted && texts(gone) == ["g", "h"])
    #expect(try review.whole("한글.txt").status == .unchanged)
}

@Test func treeListsHeadUnquoted() throws {
    let (r, review) = committed("whole-tree")
    #expect(review.tracked.split(separator: "\0") == ["a.txt", "same.txt", "한글.txt"])
    let wt = try Review.open(FilePath(r.path), .default)
    #expect(wt.tracked.split(separator: "\0") == ["a.txt", "same.txt", "staged.txt", "한글.txt"])
}

@Test func workTreeReadsTheDisk() throws {
    let (r, _) = committed("whole-wt")
    write(r.path, "same.txt", "s\nchanged\n")
    try FileManager.default.createSymbolicLink(atPath: r.path + "/link", withDestinationPath: "/etc/hosts")
    try FileManager.default.createDirectory(atPath: r.path + "/dir", withIntermediateDirectories: true)
    git(r.path, ["add", "link"])
    git(r.path, ["commit", "-qm", "link"])
    let review = try Review.open(FilePath(r.path), .default)
    let same = try review.whole("same.txt")
    #expect(same.status == .modified && texts(same) == ["s", "t", "changed"])
    // `staged.txt` is added in the work-tree diff; `a.txt` is unchanged against HEAD.
    #expect(try review.whole("a.txt").status == .unchanged)
    // A symlink is its target path, not the file it points at.
    #expect(try texts(review.whole("link")) == ["/etc/hosts"])
    #expect(throws: GitError.self) { try review.whole("dir") }
    #expect(throws: GitError.self) { try review.whole("missing") }
}

@Test func wholeTextEdgeCases() {
    let lines = { (s: String) in texts(whole(nil, path: "x", text: Array(s.utf8))) }
    #expect(lines("") == [] && lines("\n") == [""] && lines("a\r\nb") == ["a\r", "b"])
    #expect(whole(nil, path: "x", text: [0x61, 0, 0x62]).binary)
    // The disk moved on since the diff: lines run out, hunks still show, nothing traps.
    let diff = parseDiff(Array("diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -50,2 +50,2 @@\n-p\n+q\n r\n".utf8))
    #expect(texts(whole(diff.first, path: "x", text: Array("1\n2\n".utf8))) == ["1", "2", "p", "q", "r"])
    // Zero context: `+1,0` sits after head line 1, `-1,0` after base line 1.
    let del = parseDiff(Array("diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -2,1 +1,0 @@\n-b\n".utf8))
    #expect(texts(whole(del.first, path: "x", text: Array("a\nc\n".utf8))) == ["a", "b", "c"])
    let add = parseDiff(Array("diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1,0 +2,1 @@\n+b\n".utf8))
    let rows = whole(add.first, path: "x", text: Array("a\nb\nc\n".utf8)).hunks.flatMap(\.lines)
    #expect(rows.map(\.text) == ["a", "b", "c"] && rows[2].oldNo == 2 && rows[2].newNo == 3)
}

@Test func aDirectorySwappedForASymlinkCantLeadOut() throws {
    let (r, _) = committed("whole-escape")
    let outside = TempDir("whole-outside")
    write(outside.path, "secret.txt", "secret\n")
    write(r.path, "dir/secret.txt", "mine\n")
    git(r.path, ["add", "dir"])
    git(r.path, ["commit", "-qm", "dir"])
    // Hidden from the diff, so the file is read from disk.
    git(r.path, ["update-index", "--skip-worktree", "dir/secret.txt"])
    try FileManager.default.removeItem(atPath: r.path + "/dir")
    try FileManager.default.createSymbolicLink(atPath: r.path + "/dir", withDestinationPath: outside.path)
    let review = try Review.open(FilePath(r.path), .default)
    #expect(review.files.allSatisfy { $0.path != "dir/secret.txt" })
    #expect(throws: GitError.self) { try review.whole("dir/secret.txt") }
}

@Test func extremeHunkNumbersNeverTrap() {
    var f = File(path: "x", status: .modified)
    for (s, l) in [(Int.max, 0), (Int.max, 1), (Int.min, 0), (0, Int.max)] {
        f.hunks = [Hunk(oldStart: s, oldLen: l, newStart: s, newLen: l, section: "")]
        _ = whole(f, path: "x", text: Array("a\nb\n".utf8))
    }
}
