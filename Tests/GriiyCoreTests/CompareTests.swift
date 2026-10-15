// M4-6: what the ⌘K picker offers, branches and open pull requests.
import Foundation
import System
import Testing

@testable import GriiyCore

@Test func branchesNewestFirstWithoutRemoteHead() {
    let out = """
        refs/heads/feature
        refs/remotes/origin/HEAD
        refs/remotes/origin/fix/x
        refs/heads/main
        refs/remotes/origin/main

        """
    let (names, base) = parseBranches(out, originHead: "refs/remotes/origin/main\n")
    #expect(names == ["feature", "origin/fix/x", "main", "origin/main"])
    #expect(base == "origin/main")
    // No origin/HEAD: main, then master, local before remote.
    #expect(parseBranches(out, originHead: nil).base == "main")
    #expect(parseBranches("refs/remotes/origin/master\n", originHead: nil).base == "origin/master")
    #expect(parseBranches("refs/heads/dev\n", originHead: nil).base == nil)
    // origin/HEAD pointing at a branch that isn't listed isn't a base.
    #expect(parseBranches("refs/heads/dev\n", originHead: "refs/remotes/origin/gone").base == nil)
}

@Test func branchesOfARepository() throws {
    let t = repo("cmp-branches", [("a.txt", "a\n")])
    git(t.path, ["switch", "-qc", "topic"])
    write(t.path, "a.txt", "b\n")
    git(t.path, ["commit", "-qam", "topic"])
    let (names, base) = try branches(FilePath(t.path))
    #expect(Set(names) == ["main", "topic"] && base == "main")
}

@Test func openPullRequestsFromGh() throws {
    let json = """
        [{"number":12,"title":"Fix it","author":{"login":"octo"},"headRefName":"fix/it","url":"https://github.com/o/r/pull/12"},
         {"number":9,"title":"Old","author":null,"headRefName":"old","url":"https://github.com/o/r/pull/9"}]
        """
    let prs = try decodeOpenPRs(status: 0, out: Array(json.utf8), err: [])
    #expect(
        prs == [
            OpenPR(number: 12, title: "Fix it", author: "octo", branch: "fix/it"),
            OpenPR(number: 9, title: "Old", author: "ghost", branch: "old"),
        ])
    #expect(throws: GitError.ghAuth) { try decodeOpenPRs(status: 4, out: [], err: []) }
    #expect(throws: GitError.fetchFailed(remote: "GitHub", detail: "boom")) {
        try decodeOpenPRs(status: 1, out: [], err: Array("boom\n".utf8))
    }
    #expect(throws: GitError.fetchFailed(remote: "GitHub", detail: "unexpected answer from gh")) {
        try decodeOpenPRs(status: 0, out: Array("{}".utf8), err: [])
    }
}

@Test func noGitHubRemoteMeansNoPullRequests() throws {
    let t = repo("cmp-noremote", [("a.txt", "a\n")])
    #expect(try openPullRequests(FilePath(t.path)).isEmpty)
}

@Test func pickedItemsParseBackAsTheirSpecs() throws {
    // What ⌘K relaunches griiy with.
    #expect(
        try parseArgs([Array("origin/main...fix/x".utf8)]).get().spec
            == .range(base: "origin/main", head: "fix/x", mergeBase: true))
    #expect(try parseArgs([Array("#12".utf8)]).get().spec == .pullRequest(repo: nil, number: 12))
    // Any remote's HEAD is left out, not only origin's.
    #expect(
        parseBranches("refs/remotes/upstream/HEAD\nrefs/remotes/upstream/dev\n", originHead: nil).names == [
            "upstream/dev"
        ])
}
