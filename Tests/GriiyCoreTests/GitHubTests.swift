// F-PR-1: a PR's owner/repo, from its URL or the remotes, and the remote to fetch it from.
import Foundation
import System
import Testing

@testable import GriiyCore

private func gh(_ owner: String, _ name: String) -> GitHubRepo { GitHubRepo(owner: owner, name: name)! }

/// `git remote -v` output: fetch and push lines per remote, sorted by name like git's.
private func remotes(_ pairs: [(String, String)]) -> String {
    pairs.map { "\($0.0)\t\($0.1) (fetch)\n\($0.0)\t\($0.1) (push)\n" }.joined()
}

@Test func namesAreGitHubsAndLowercase() {
    #expect(gh("Octo-Cat", "Hello.World_2") == gh("octo-cat", "hello.world_2"))
    #expect(gh("Octo", "R").owner == "octo" && gh("Octo", "R").name == "r")
    // Valid GitHub names that aren't valid ref components: M2-2 encodes them, parsing keeps them.
    #expect(GitHubRepo(owner: "o", name: ".github") != nil)
    #expect(GitHubRepo(owner: "o", name: "a..b") != nil)
    for (owner, name) in [
        ("", "r"), ("o", ""), ("o", "."), ("o", ".."), ("o.x", "r"), ("o_x", "r"), ("o", "a/b"), ("o", "a b"),
        ("o", "%2e%2e"), ("o", "r\0"), ("o", "r\n"), ("오", "r"), ("o", "-r?"),
    ] {
        #expect(GitHubRepo(owner: owner, name: name) == nil, "\(owner)/\(name)")
    }
}

@Test func remoteURLs() {
    for url in [
        "https://github.com/o/r.git", "https://github.com/o/r", "https://github.com/o/r/", "http://github.com/o/r",
        "https://user:tok@en@github.com/o/r.git", "https://GitHub.com/O/R.git", "https://www.github.com/o/r",
        "https://github.com:443/o/r", "ssh://git@github.com/o/r.git", "ssh://git@github.com:22/o/r",
        "ssh://git@ssh.github.com:443/o/r.git", "git+ssh://git@github.com/o/r", "git://github.com/o/r",
        "git@github.com:o/r.git", "git@github.com:o/r", "https://user:tok@github.com:443/o/r.git",
        "ssh://user:pw@github.com:22/o/r.git", "SSH://git@github.com/o/r", "github.com:o/r", "git@github.com:/o/r.git",
    ] {
        #expect(gitHubRepo(remoteURL: url) == gh("o", "r"), "\(url)")
    }
    for url in [
        "https://gitlab.com/o/r.git", "https://github.com.evil.com/o/r", "https://evilgithub.com/o/r",
        "https://github.com/o", "https://github.com/o/r/x", "https://github.com//o/r", "git@github.com:o",
        "/srv/git/o/r.git", "../r", "file:///github.com/o/r", "git@gitlab.com:o/r.git", "https://github.com/o/%2e%2e",
        "github-work:o/r", "", "ftp://github.com/o/r", "foo://github.com/o/r", "persistent-https://github.com/o/r",
    ] {
        #expect(gitHubRepo(remoteURL: url) == nil, "\(url)")
    }
}

private func pick(_ out: String, _ want: GitHubRepo?, _ n: Int = 7) throws(GitError) -> String {
    try prRemote(out, want, number: n).remote
}

@Test func urlPicksTheMatchingRemote() throws {
    let out = remotes([("mine", "git@github.com:me/r.git"), ("theirs", "https://github.com/O/R.git")])
    #expect(try pick(out, gh("o", "r")) == "theirs")
    #expect(try prRemote(out, gh("O", "r"), number: 7).repo == gh("o", "r"))
    // https and ssh remotes of one repo: upstream, then origin, then the first by name.
    let two = remotes([("a", "https://github.com/o/r"), ("origin", "git@github.com:o/r.git")])
    #expect(try pick(two, gh("o", "r")) == "origin")
    let three = two + remotes([("upstream", "ssh://git@github.com/o/r")])
    #expect(try pick(three, gh("o", "r")) == "upstream")
    #expect(try pick(remotes([("b", "https://github.com/o/r"), ("a", "https://github.com/o/r")]), gh("o", "r")) == "a")
}

@Test func forkPR() throws {
    // A fork's clone: the PR lives in the base repo, reached through upstream.
    let fork = remotes([("origin", "git@github.com:me/r.git"), ("upstream", "https://github.com/o/r.git")])
    #expect(try pick(fork, gh("o", "r")) == "upstream")
    #expect(try pick(fork, nil) == "upstream")
    // Only the fork: no remote has the base repo's PRs.
    #expect(throws: GitError.self) { try pick(remotes([("origin", "git@github.com:me/r.git")]), gh("o", "r")) }
}

@Test func numberUsesTheOnlyRepoOrUpstreamOrOrigin() throws {
    #expect(try prRemote(remotes([("gh", "git@github.com:O/R")]), nil, number: 3).repo == gh("o", "r"))
    #expect(try pick(remotes([("a", "https://github.com/o/r"), ("b", "git@github.com:o/r")]), nil) == "a")
    let two = remotes([("a", "https://github.com/x/y"), ("origin", "https://github.com/o/r")])
    #expect(try prRemote(two, nil, number: 3).repo == gh("o", "r"))
    // An upstream that isn't on GitHub doesn't count.
    let gitlab = remotes([("origin", "https://github.com/o/r"), ("upstream", "https://gitlab.com/x/y")])
    #expect(try pick(gitlab, nil) == "origin")
}

@Test func noRemote() {
    let token = "https://ghp_secret@github.com/me/r.git"
    let cases: [(String, GitHubRepo?)] = [
        ("", gh("o", "r")),
        (remotes([("origin", token)]), gh("o", "r")),
        ("", nil),
        (remotes([("origin", "https://gitlab.com/o/r")]), nil),
        // Two repos and neither is upstream or origin: which one is #n in?
        (remotes([("a", token), ("b", "https://github.com/x/y")]), nil),
    ]
    for (out, want) in cases {
        do {
            _ = try prRemote(out, want, number: 7)
            Issue.record("picked a remote from \(out)")
        } catch {
            guard case .noRemote(let w, 7, let detail) = error, w == want else {
                return #expect(Bool(false), "\(error)")
            }
            #expect(!error.title.isEmpty && !error.hint.isEmpty)
            // Remote URLs can carry tokens: the screen shows names and owner/repo only.
            #expect(!"\(error.title)\(error.hint)\(detail)".contains("secret"))
            if let w { #expect(error.title.contains("\(w.owner)/\(w.name)")) }
        }
    }
}

@Test func remoteLinesAreFetchOnly() throws {
    // A pushurl-only remote prints `name<TAB>`; push URLs never decide; junk lines are skipped.
    let out =
        "nofetch\t\n" + "p\thttps://gitlab.com/x/y (fetch)\np\thttps://github.com/o/r.git/ (push)\n"
        + "q\thttps://github.com/o/r (fetch) trailing\n" + "no tab line (fetch)\n"
        + "r\thttps://github.com/o/r  (fetch)\n"
    #expect(try pick(out, gh("o", "r")) == "r")
}

@Test func openPicksTheRemote() throws {
    let r = repo("pr", [("a.txt", "a\n")])
    git(r.path, ["remote", "add", "origin", "gh:me/r"])
    git(r.path, ["remote", "add", "upstream", "gh:O/R"])
    git(r.path, ["config", "url.git@github.com:.insteadOf", "gh:"])
    let dir = FilePath(r.path)
    // Fetching comes in M2-2: for now opening a PR stops at the remote it would fetch from.
    for spec in [Spec.pullRequest(repo: gh("o", "r"), number: 5), .pullRequest(repo: nil, number: 5)] {
        #expect(throws: GitError.fetchFailed(remote: "upstream", detail: "fetching pull requests comes in M2-2")) {
            try Review.open(dir, spec)
        }
    }
    #expect(
        throws: GitError.noRemote(
            want: gh("x", "y"), number: 5, detail: "origin → github.com/me/r\nupstream → github.com/o/r")
    ) {
        try Review.open(dir, .pullRequest(repo: gh("x", "y"), number: 5))
    }
}
