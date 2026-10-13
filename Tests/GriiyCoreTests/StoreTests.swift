// PRD §7.4: per-review JSON documents. Keys must match the Rust version byte for byte.
import Foundation
import System
import Testing

@testable import GriiyCore

@Test func keys() {
    let gh = { (o: String, r: String, n: Int) in reviewKey(.gitHub(owner: o, repo: r, number: n)) }
    #expect(gh("Octo", "Hello.World", 42) == "gh-octo-hello.world-42")
    #expect(gh("a-b", "c", 1) != gh("a", "b-c", 1), "`-` inside a name can't fake a separator")

    let repo = FilePath("/Users/me/src/app")
    // Golden values from the Rust implementation (64-bit FNV-1a of the path bytes).
    let range = reviewKey(.range(repo: repo, base: "main", head: "feature/x"))
    #expect(range == "local-13b1027cea066130-main-feature%2Fx")
    #expect(reviewKey(.workTree(repo: repo)) == "local-13b1027cea066130-worktree")
    #expect(reviewKey(.workTree(repo: FilePath("/Users/me/src/other"))) == "local-2d6e9630bcc2ff51-worktree")

    let long = String(repeating: "x/", count: 300)
    let k = reviewKey(.range(repo: repo, base: "main", head: long))
    #expect(k == "local-13b1027cea066130-main-" + String(repeating: "x%2F", count: 38) + "-09ee6b1e05928e31")
    #expect(k.utf8.count <= 200 && !k.contains("/"))
    #expect(k != reviewKey(.range(repo: repo, base: "main", head: long + "y")), "long keys stay distinct")
}

@Test func localRangeKeySurvivesANewCommit() throws {
    let r = repo("key", [("a.txt", "a\n")])
    git(r.path, ["checkout", "-qb", "feature"])
    write(r.path, "sub/b.txt", "b\n")
    git(r.path, ["add", "-A"])
    git(r.path, ["commit", "-qm", "b"])
    let top = { (dir: String) in git(dir, ["rev-parse", "--show-toplevel"]).trimmingCharacters(in: .newlines) }
    let key = { (dir: String) in reviewKey(.range(repo: FilePath(top(dir)), base: "main", head: "feature")) }
    let before = key(r.path)
    write(r.path, "a.txt", "changed\n")
    git(r.path, ["commit", "-qam", "more"])
    #expect(key(r.path) == before)
    #expect(key(r.path + "/sub") == before, "same key from a subdirectory")
    let link = r.path + ".link"
    try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: r.path)
    defer { try? FileManager.default.removeItem(atPath: link) }
    #expect(
        reviewKey(.range(repo: FilePath(link), base: "main", head: "feature")) == before, "same key through a symlink")
}

private func same(_ a: [String: Any], _ b: [String: Any]) -> Bool { NSDictionary(dictionary: a).isEqual(to: b) }

@Test func saveThenLoad() throws {
    let t = TempDir("store")
    let store = Store(root: FilePath(t.path + "/reviews"))
    #expect(same(try store.load("k"), ["version": 1]), "missing → fresh")
    let doc: [String: Any] = ["version": 1, "seen": ["a.txt": "blob"]]
    try store.save("k", doc)
    try store.save("k", doc)
    #expect(same(try store.load("k"), doc))
    #expect(
        try FileManager.default.contentsOfDirectory(atPath: t.path + "/reviews") == ["k.json"],
        "no temp files left behind")
    try store.save("n", ["seen": [String: Any]()])
    #expect(same(try store.load("n"), ["version": 1, "seen": [String: Any]()]), "version stamped on save")
}

@Test(arguments: [
    "{not json", "", "[1,2]", #"{"seen":{}}"#, #"{"version":99}"#, #"{"version":"1"}"#, #"{"version":true}"#,
    #"{"version":1.5}"#,
])
func corruptFilesAreBackedUp(bad: String) throws {
    let t = TempDir("corrupt")
    let store = Store(root: FilePath(t.path))
    write(t.path, "k.json", bad)
    #expect(same(try store.load("k"), ["version": 1]), "\(bad)")
    let backups = try FileManager.default.contentsOfDirectory(atPath: t.path).filter { $0.hasPrefix("k.json.corrupt-") }
    #expect(backups.count == 1)
    #expect(try String(contentsOfFile: t.path + "/" + backups[0], encoding: .utf8) == bad, "original kept")
    #expect(!FileManager.default.fileExists(atPath: t.path + "/k.json"))
}

// F-DV-9: a seen mark holds while the file's change is the same, across reruns and new commits.
private func reopen(_ r: TempDir, _ spec: Spec) throws -> Review { try Review.open(FilePath(r.path), spec) }
private func seenPaths(_ r: Review, _ doc: [String: Any]) -> Set<String> {
    Set(r.seen(in: doc).map { r.files[$0].path })
}
private let feature = Spec.range(base: "main", head: "feature", mergeBase: false)

/// Every file in the review marked seen, starting from `doc`.
private func markAll(_ r: Review, _ doc: [String: Any]) -> [String: Any] {
    r.files.indices.reduce(doc) { r.marking($1, true, in: $0) }
}

@Test func seenMarksCarryOverWhileTheChangeIsTheSame() throws {
    let r = repo(
        "seen", [("a.txt", "a\n"), ("b.txt", "b\n"), ("c.txt", "c\n"), ("m.sh", "m\n"), ("old.txt", "same\n")])
    git(r.path, ["checkout", "-qb", "feature"])
    for p in ["a.txt", "b.txt", "c.txt"] { write(r.path, p, p + "2\n") }
    chmod(r.path + "/m.sh", 0o755)
    git(r.path, ["mv", "old.txt", "new.txt"])
    git(r.path, ["commit", "-qam", "f"])
    let store = Store(root: FilePath(TempDir("seen-store").path))

    var review = try reopen(r, feature)
    #expect(Set(review.files.map(\.path)) == ["a.txt", "b.txt", "c.txt", "m.sh", "new.txt"])
    #expect(review.key == (try reopen(r, .range(base: "main", head: "feature", mergeBase: true))).key)
    try store.save(review.key, markAll(review, ["other": 1]))

    // Rerun: everything stays seen, blobless mode-only and pure-rename changes included.
    review = try reopen(r, feature)
    #expect(seenPaths(review, try store.load(review.key)) == ["a.txt", "b.txt", "c.txt", "m.sh", "new.txt"])

    // A new commit on feature changes a.txt: the key is the same, the rest stay seen.
    write(r.path, "a.txt", "a3\n")
    git(r.path, ["commit", "-qam", "more"])
    review = try reopen(r, feature)
    #expect(seenPaths(review, try store.load(review.key)) == ["b.txt", "c.txt", "m.sh", "new.txt"])

    // main changes b.txt: head's blob is the same but the change shown isn't.
    git(r.path, ["checkout", "-q", "main"])
    write(r.path, "b.txt", "b on main\n")
    git(r.path, ["commit", "-qam", "main b"])
    review = try reopen(r, feature)
    var doc = try store.load(review.key)
    #expect(seenPaths(review, doc) == ["c.txt", "m.sh", "new.txt"])

    // Unmarking one path leaves the other marks and the document's other keys alone.
    doc = review.marking(try #require(review.files.firstIndex { $0.path == "c.txt" }), false, in: doc)
    #expect(seenPaths(review, doc) == ["m.sh", "new.txt"])
    #expect(doc["other"] as? Int == 1)
}

@Test func aPureRenameIsNotAnotherPureRename() throws {
    let r = repo("seen-mv", [("x.txt", "same\n"), ("y.txt", "same\n")])
    git(r.path, ["checkout", "-qb", "feature"])
    git(r.path, ["mv", "x.txt", "new.txt"])
    git(r.path, ["commit", "-qm", "x"])
    let doc = markAll(try reopen(r, feature), [:])
    git(r.path, ["reset", "-q", "--hard", "main"])
    git(r.path, ["mv", "y.txt", "new.txt"])
    git(r.path, ["commit", "-qm", "y"])
    #expect(seenPaths(try reopen(r, feature), doc).isEmpty)
}

@Test func seenInTheWorkTree() throws {
    let r = repo("seen-wt", [("a.txt", "a\n")])
    write(r.path, "a.txt", "a2\n")
    let doc = (try reopen(r, .default)).marking(0, true, in: [:])
    #expect(seenPaths(try reopen(r, .default), doc) == ["a.txt"], "same edit: still seen")
    write(r.path, "a.txt", "a3\n")
    #expect(seenPaths(try reopen(r, .default), doc).isEmpty, "edited again: not seen")
}

@Test func malformedSeenIsIgnored() throws {
    let r = repo("seen-bad", [("a.txt", "a\n")])
    write(r.path, "a.txt", "a2\n")
    let review = try reopen(r, .default)
    for bad: Any in [1, ["a.txt": 1], ["a.txt"]] {
        #expect(review.seen(in: ["seen": bad]).isEmpty)
        #expect(review.seen(in: review.marking(0, true, in: ["seen": bad])) == [0], "replaced")
    }
}
