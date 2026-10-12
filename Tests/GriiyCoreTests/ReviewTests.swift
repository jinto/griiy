// F-IN-2/F-IN-3: every input becomes `Review { base: sha, head: sha | worktree }`.
import Foundation
import System
import Testing

@testable import GriiyCore

/// main and feature diverge from `init`: feature adds feat.txt, main then adds main.txt.
/// feature is checked out.
private func diverged(_ name: String) -> TempDir {
    let r = repo(name, [("base.txt", "base\n")])
    git(r.path, ["checkout", "-qb", "feature"])
    write(r.path, "feat.txt", "feat\n")
    git(r.path, ["add", "-A"])
    git(r.path, ["commit", "-qm", "feat"])
    git(r.path, ["checkout", "-q", "main"])
    write(r.path, "main.txt", "main\n")
    git(r.path, ["add", "-A"])
    git(r.path, ["commit", "-qm", "main"])
    git(r.path, ["checkout", "-q", "feature"])
    return r
}

private func sha(_ r: TempDir, _ rev: String) -> String {
    git(r.path, ["rev-parse", rev]).trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Changed lines as `+text` / `-text`.
private func changes(_ r: Review) -> [String] {
    r.files.flatMap(\.hunks).flatMap(\.lines).compactMap {
        switch $0.kind {
        case .add: "+\($0.text)"
        case .del: "-\($0.text)"
        case .context: nil
        }
    }
}

private func paths(_ r: Review) -> [String] { r.files.map(\.path) }
private func range(_ b: String, _ h: String, _ m: Bool) -> Spec { .range(base: b, head: h, mergeBase: m) }
private func open(_ r: TempDir, _ spec: Spec) throws -> Review { try Review.open(FilePath(r.path), spec) }

private func expectBadRange(_ spec: String, _ body: () throws -> Review) {
    do {
        _ = try body()
        Issue.record("opened")
    } catch let e as GitError {
        guard case .badRange(let s, _) = e, s == spec else { return #expect(Bool(false), "\(e)") }
    } catch {
        Issue.record("\(error)")
    }
}

@Test func twoDotsComparesEndpoints() throws {
    let r = diverged("dots2")
    let review = try open(r, range("main", "feature", false))
    #expect(review.base == sha(r, "main") && review.head == .sha(sha(r, "feature")))
    #expect(paths(review) == ["feat.txt", "main.txt"])  // main.txt shows as deleted
    #expect(changes(review).contains("-main"))
}

@Test func threeDotsComparesAgainstTheMergeBase() throws {
    let r = diverged("dots3")
    let review = try open(r, range("main", "feature", true))
    #expect(review.base == git(r.path, ["merge-base", "main", "feature"]).trimmingCharacters(in: .newlines))
    #expect(review.head == .sha(sha(r, "feature")))
    #expect(paths(review) == ["feat.txt"])
    #expect(review.files[0].hunks[0].lines[0].text == "feat")
}

@Test func noCommonAncestorIsABadRange() {
    let r = repo("orphan", [("a.txt", "a\n")])
    git(r.path, ["checkout", "-q", "--orphan", "other"])
    git(r.path, ["commit", "-qm", "other"])
    expectBadRange("main...other") { try open(r, range("main", "other", true)) }
}

@Test func worktreeIncludesStagedAndUnstagedButNotUntracked() throws {
    let r = repo("wt", [("staged.txt", "a\n"), ("unstaged.txt", "a\n")])
    write(r.path, "staged.txt", "a\nstaged\n")
    git(r.path, ["add", "staged.txt"])
    write(r.path, "unstaged.txt", "a\nunstaged\n")
    write(r.path, "untracked.txt", "new\n")
    let review = try open(r, .default)
    #expect(review.base == sha(r, "HEAD") && review.head == .workTree)
    #expect(paths(review) == ["staged.txt", "unstaged.txt"])
    #expect(changes(review) == ["+staged", "+unstaged"])
}

@Test func singleRevComparesItWithTheWorktree() throws {
    let r = diverged("single")
    write(r.path, "feat.txt", "feat\nedited\n")
    let review = try open(r, .workTree(base: "main"))
    #expect(review.base == sha(r, "main") && review.head == .workTree)
    #expect(paths(review) == ["feat.txt", "main.txt"])
    #expect(changes(review).contains("+edited"))
}

@Test func aCleanTreeHasNoChanges() throws {
    #expect(try open(repo("clean", [("a.txt", "a\n")]), .default).files.isEmpty)
}

@Test func subdirectoryOpensTheWholeRepo() throws {
    let r = repo("subdir", [("d/a.txt", "a\n")])
    write(r.path, "d/a.txt", "b\n")
    let review = try Review.open(FilePath(r.path + "/d"), .default)
    #expect(review.repo == FilePath(r.path) && paths(review) == ["d/a.txt"])
}

@Test func labelsNameWhatWasAskedFor() {
    #expect(range("main", "feature", true).label == "main...feature")
    #expect(range("a", "b", false).label == "a..b")
    #expect(Spec.default.label == "HEAD vs working tree")
}

@Test func summaryNumbersComeFromTheParsedFiles() throws {
    let r = diverged("summary")
    let review = try open(r, range("main", "feature", false))
    let f = review.files[0]
    // header + hunk header + one line
    #expect(f.path == "feat.txt" && f.status == .added && st(f) == [1, 0] && f.rowCount == 3 && f.oldPath == nil)
    #expect(review.files[1].path == "main.txt" && review.files[1].status == .deleted)
    #expect(review.tracked.split(separator: "\n") == ["base.txt", "feat.txt"])
}

@Test func a120kLineDiffOpensWithRowsInWindows() throws {
    let line = { (f: Int, i: Int, tag: String) in "    let v_\(f)_\(i) = compute(\(i), \"\(tag)\");\n" }
    let base = (0..<300).map { f in
        (String(format: "src/m%d/file%03d.rs", f % 10, f), (1...400).map { line(f, $0, "a") }.joined())
    }
    let r = repo("big", base)
    for (f, (path, _)) in base.enumerated() {
        write(r.path, path, (1...400).map { line(f, $0, $0 % 5 == 0 ? "b" : "a") }.joined())
    }
    let review = try open(r, .default)
    #expect(review.files.map(\.rowCount).reduce(0, +) > 120_000)
    // A window deep in the diff is the same as the matching slice of the whole.
    let f = review.files[150]
    #expect(f.rows(from: 300, n: 40) == Array(f.rows(from: 0, n: .max)[300..<340]))
}

@Test func aWindowDeepInOneHugeFile() throws {
    let r = repo("huge", [("big.txt", (0..<60_000).map { "\($0)\n" }.joined())])
    write(r.path, "big.txt", (0..<60_000).map { "\($0 * 2)\n" }.joined())
    let f = try open(r, .default).files[0]
    let window = f.rows(from: 50_000, n: 50)
    #expect(window.count == 50 && window == Array(f.rows(from: 0, n: .max)[50_000..<50_050]))
}

@Test func unknownRevisionsAreBadRangesEvenOnAnUnbornBranch() {
    let r = repo("typo", [("a.txt", "a\n")])
    expectBadRange("nope") { try open(r, .workTree(base: "nope")) }
    // HEAD points nowhere, but the repo has commits: still a typo, not "no commits yet".
    git(r.path, ["checkout", "-q", "--orphan", "fresh"])
    expectBadRange("typo") { try open(r, range("main", "typo", false)) }
}

@Test func aRenamedFileStaysARename() throws {
    let r = repo("renamefd", [("old.txt", "1\n2\n3\n4\n5\n")])
    git(r.path, ["mv", "old.txt", "new.txt"])
    write(r.path, "new.txt", "1\n2\n3\n4\nfive\n")
    let f = try open(r, .default).files[0]
    #expect(f.path == "new.txt" && f.oldPath == "old.txt" && st(f) == [1, 1])
}

@Test func aCancelledReviewStopsAndSaysSo() {
    let r = repo("cancelreview", [("a.txt", "a\n")])
    let token = Cancel()
    token.cancel()
    #expect(throws: GitError.cancelled) { try Review.open(FilePath(r.path), .default, cancel: token) }
}
