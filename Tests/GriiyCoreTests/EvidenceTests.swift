// M3-2 (F-AI-2 ①): the code around a selection, the same from the diff and the whole file.
import Foundation
import System
import Testing

@testable import GriiyCore

private let base120 = (1...120).map { "b\($0)" }

/// c.txt: 120 lines; head changes line 10, deletes 105, and adds a line after 115.
/// Also an added, a deleted, a renamed-and-changed and an untouched file.
private func fixture(_ name: String) -> (TempDir, Review) {
    let ten = (1...10).map { "m\($0)\n" }.joined()
    let r = repo(
        name,
        [("c.txt", base120.map { $0 + "\n" }.joined()), ("gone.txt", "g\n"), ("old.txt", ten), ("same.txt", "s\n")])
    var c = base120
    c.insert("new", at: 115)
    c.remove(at: 104)
    c[9] = "h10"
    write(r.path, "c.txt", c.map { $0 + "\n" }.joined())
    write(r.path, "add.txt", "a1\na2\n")
    write(r.path, "bin", "a\u{0}b\n")
    try? FileManager.default.removeItem(atPath: r.path + "/gone.txt")
    git(r.path, ["mv", "old.txt", "moved.txt"])
    write(r.path, "moved.txt", ten.replacingOccurrences(of: "m5\n", with: "M5\n"))
    git(r.path, ["add", "-A"])
    git(r.path, ["commit", "-qm", "change"])
    let review = try! Review.open(FilePath(r.path), .range(base: "HEAD~1", head: "HEAD", mergeBase: false))
    return (r, review)
}

@Test func diffAndWholeFileGiveTheSameEvidence() throws {
    let (t, review) = fixture("ev-same")
    defer { withExtendedLifetime(t) {} }
    // Evidence comes from the path and the span alone, so the views agree when their spans do.
    let diff = try #require(review.files.first { $0.path == "c.txt" })
    let whole = try review.whole("c.txt")
    let picks: [(Side, Range<Int>)] = [
        (.head, 10..<11),  // a changed line
        (.head, 8..<9),  // context inside the hunk
        (.base, 105..<106),  // deleted only
        (.head, 115..<116),  // added only
        (.base, 9..<107),  // across two hunks
        (.head, 1..<121),
    ]
    for (side, lines) in picks {
        #expect(diff.span(side, lines) == whole.span(side, lines), "\(side) \(lines)")
    }
    // Across the hunks: only changed lines, not the context the whole file has between them.
    #expect(try review.code("c.txt", .base, 9..<107).diff == "-b10\n+h10\n-b105\n")
}

@Test func excerptsAreFortyLinesAroundTheSpan() throws {
    let (t, review) = fixture("ev-range")
    defer { withExtendedLifetime(t) {} }
    // Line 10 changed: base and head 10, ±40 cut at the top.
    let near = try review.code("c.txt", .head, 10..<11)
    #expect(near.items.map(\.id) == ["code:c.txt:L1-50@base", "code:c.txt:L1-50@head"])
    #expect(near.diff == "-b10\n+h10\n")
    let head = near.items[1].text.split(separator: "\n")
    #expect(head.count == 50 && head[0] == "1\tb1" && head[9] == "10\th10" && head[49] == "50\tb50")
    // Deleted base 105 alone: head has nothing there, so its excerpt is around the gap (head 105).
    let del = try review.code("c.txt", .base, 105..<106)
    #expect(del.items.map(\.id) == ["code:c.txt:L65-120@base", "code:c.txt:L65-120@head"])
    #expect(del.diff == "-b105\n")
    #expect(del.items[1].text.split(separator: "\n").last == "120\tb120")
    // After the deletion the sides number apart: head 110 is base 111.
    let shifted = try review.code("c.txt", .head, 110..<111)
    #expect(shifted.items.map(\.id) == ["code:c.txt:L71-120@base", "code:c.txt:L70-120@head"])
    // Context far from any change: the same text on both sides, so head only.
    let far = try review.code("c.txt", .head, 60..<61)
    #expect(far.items.map(\.id) == ["code:c.txt:L20-100@head"] && far.diff.isEmpty)
}

@Test func sidesThatDontExistAreLeftOut() throws {
    let (t, review) = fixture("ev-sides")
    defer { withExtendedLifetime(t) {} }
    let add = try review.code("add.txt", .head, 1..<2)
    #expect(add.items == [Evidence(id: "code:add.txt:L1-2@head", text: "1\ta1\n2\ta2\n")])
    let gone = try review.code("gone.txt", .base, 1..<2)
    #expect(gone.items == [Evidence(id: "code:gone.txt:L1-1@base", text: "1\tg\n")])
    // A rename cites the base by its old path.
    let moved = try review.code("moved.txt", .head, 5..<6)
    #expect(moved.items.map(\.id) == ["code:old.txt:L1-10@base", "code:moved.txt:L1-10@head"])
    #expect(moved.items[1].text.contains("5\tM5\n") && moved.items[0].text.contains("5\tm5\n"))
    let same = try review.code("same.txt", .head, 1..<2)
    #expect(same.items == [Evidence(id: "code:same.txt:L1-1@head", text: "1\ts\n")] && same.diff.isEmpty)
    #expect(try review.code("bin", .head, 1..<2) == ("", []))
    // Past the end (the work tree moved on): no item, never `L3-2`.
    #expect(try review.code("same.txt", .head, 50..<51).items.isEmpty)
}

@Test func workTreeHeadComesFromTheDisk() throws {
    let (t, _) = fixture("ev-wt")
    write(t.path, "same.txt", "s\ndisk\n")
    let review = try Review.open(FilePath(t.path), .default)
    let ev = try review.code("same.txt", .head, 2..<3)
    #expect(ev.items.map(\.id) == ["code:same.txt:L1-1@base", "code:same.txt:L1-2@head"])
    #expect(ev.items[1].text == "1\ts\n2\tdisk\n" && ev.diff == "+disk\n")
}
