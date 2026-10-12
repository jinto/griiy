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
