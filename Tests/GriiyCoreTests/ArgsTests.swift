// F-IN-1: `griiy [<range>] [-C <repo>]`, with git's range meanings (F-IN-2).
import Foundation
import System
import Testing

@testable import GriiyCore

private func p(_ args: [String]) -> Result<Args, UsageError> { parseArgs(args.map { Array($0.utf8) }) }
private func spec(_ args: [String]) throws -> Spec { try p(args).get().spec }
private func wt(_ base: String) -> Spec { .workTree(base: base) }
private func range(_ base: String, _ head: String, _ mergeBase: Bool) -> Spec {
    .range(base: base, head: head, mergeBase: mergeBase)
}

@Test func rangesFollowGit() throws {
    #expect(try spec([]) == wt("HEAD"))
    #expect(try spec([]) == Spec.default)
    #expect(try spec(["main"]) == wt("main"))
    #expect(try spec(["a..b"]) == range("a", "b", false))
    #expect(try spec(["a...b"]) == range("a", "b", true))
    #expect(try spec(["main.."]) == range("main", "HEAD", false))
    #expect(try spec(["..b"]) == range("HEAD", "b", false))
    #expect(try spec(["...b"]) == range("HEAD", "b", true))
    #expect(try spec([".."]) == range("HEAD", "HEAD", false))
    #expect(try spec(["..."]) == range("HEAD", "HEAD", true))
    // Odd shapes go to git as revisions; resolve() rejects them on the error screen.
    #expect(try spec(["a....b"]) == range("a", ".b", true))
    #expect(try spec(["feature/x...origin/main"]) == range("feature/x", "origin/main", true))
}

@Test func repoFlag() throws {
    #expect(try p([]).get().repo == FilePath("."))
    for args in [["-C", "x", "a..b"], ["a..b", "-C", "x"]] {
        let a = try p(args).get()
        #expect(a.repo == FilePath("x") && a.spec == range("a", "b", false))
    }
    #expect(try p(["-C", "한글 dir"]).get().repo == FilePath("한글 dir"))
    // Paths are bytes on Unix: a non-UTF-8 directory must reach git unchanged.
    let raw: [UInt8] = Array("repo-".utf8) + [0xFF]
    let a = try parseArgs([Array("-C".utf8), raw]).get()
    #expect(
        a.repo.withPlatformString {
            Array(UnsafeBufferPointer(start: $0, count: strlen($0))).map { UInt8(bitPattern: $0) }
        } == raw)
}

@Test(arguments: [
    ["-C"], ["-C", "x", "-C", "y"], ["a", "b"], ["--foo"], ["-x"], ["--output=/tmp/x..HEAD"],
    ["-C", "x", "--output=/tmp/x"],
])
func usageErrors(args: [String]) {
    guard case .failure(let e) = p(args) else {
        Issue.record("\(args) parsed")
        return
    }
    #expect(e.message.hasPrefix("griiy: ") && e.message.contains("usage"), "\(args): \(e.message)")
}

@Test func revisionsMustBeUTF8() {
    guard case .failure(let e) = parseArgs([Array("main..".utf8) + [0xFF]]) else {
        Issue.record("parsed")
        return
    }
    #expect(e.message.contains("usage"))
}

@Test func pullRequests() throws {
    let pr = { (o: String, r: String, n: Int) in Spec.pullRequest(repo: GitHubRepo(owner: o, name: r), number: n) }
    for url in [
        "https://github.com/o/r/pull/42", "https://github.com/o/r/pull/42/", "https://github.com/o/r/pull/42/files",
        "https://github.com/o/r/pull/42/commits/abc123", "https://github.com/o/r/pull/42?w=1",
        "https://github.com/o/r/pull/42#discussion_r1", "http://github.com/o/r/pull/42",
        "https://www.github.com/o/r/pull/42", "HTTPS://GitHub.com/O/R/pull/42", "https://github.com/o/r.git/pull/42",
        "https://github.com/o/r/pull/42/some-future-tab",
    ] {
        #expect(try spec([url]) == pr("o", "r", 42), "\(url)")
    }
    #expect(try spec(["https://github.com/o/.github/pull/1"]) == pr("o", ".github", 1))
    #expect(try spec(["#42"]) == .pullRequest(repo: nil, number: 42))
    let a = try p(["-C", "x", "#3"]).get()
    #expect(a.repo == FilePath("x") && a.spec == .pullRequest(repo: nil, number: 3))
    #expect(pr("O", "R", 4).label == "o/r#4" && Spec.pullRequest(repo: nil, number: 4).label == "#4")
}

@Test(arguments: [
    "https://github.com/o/r/pull/", "https://github.com/o/r/pull/0", "https://github.com/o/r/pull/x",
    "https://github.com/o/r/pull/4x", "https://github.com/o/r/pull/+4", "https://github.com/o/r/issues/3",
    "https://github.com/o/r", "https://gitlab.com/o/r/pull/1", "https://github.com.evil.com/o/r/pull/1",
    "https://user@github.com/o/r/pull/1", "https://github.com/o/../pull/1", "https://github.com/o/%2e%2e/pull/1",
    "https://github.com/o/a%2Fb/pull/1", "https://github.com/o r/x/pull/1", "https://github.com//r/pull/1",
    "https://github.com/o/r/pull/99999999999999999999", "#", "#0", "#1a", "#-1", "#+1", "# 1", "#99999999999999999999",
])
func badPullRequests(arg: String) {
    guard case .failure(let e) = p([arg]) else {
        Issue.record("\(arg) parsed")
        return
    }
    #expect(e.message.hasPrefix("griiy: ") && e.message.contains("usage"), "\(arg): \(e.message)")
}
