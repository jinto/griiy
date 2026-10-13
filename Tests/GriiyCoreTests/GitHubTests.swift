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
    git(r.path, ["config", "url.git@github.com:.insteadOf", "gh:"])
    // No remote has x/y: stops before asking GitHub anything.
    #expect(throws: GitError.noRemote(want: gh("x", "y"), number: 5, detail: "origin → github.com/me/r")) {
        try Review.open(FilePath(r.path), .pullRequest(repo: gh("x", "y"), number: 5))
    }
}

@Test func refNamesAreValid() {
    let cases = [
        ("o", "r", "refs/griiy/gh/o/r/7"), ("o", ".github", "refs/griiy/gh/o/%2Egithub/7"),
        ("o", "a..b", "refs/griiy/gh/o/a%2E%2Eb/7"), ("o", "x.lock", "refs/griiy/gh/o/x%2Elock/7"),
        ("-o", "r_2", "refs/griiy/gh/-o/r_2/7"),
    ]
    for (owner, name, ns) in cases {
        #expect(prRefs(gh(owner, name), 7) == ns)
        for leaf in ["head", "base"] { git("/", ["check-ref-format", "\(ns)/\(leaf)"]) }
    }
}

@Test func baseShaIsOneFullObjectID() {
    let sha1 = String(repeating: "0123456789", count: 4)
    let sha256 = String(repeating: "abcdef01", count: 8)
    #expect(baseSha(sha1 + "\n") == sha1)
    #expect(baseSha(sha256 + "\n") == sha256)
    #expect(baseSha(sha1) == sha1)
    for out in [
        "", "\n", "null\n", sha256.uppercased() + "\n", " " + sha1, sha1 + " \n", sha1 + "\n\n", "\(sha1)\n\(sha1)\n",
        String(sha1.dropLast()), sha1 + "0", ":refs/heads/x", "{\"message\":\"Not Found\",\"status\":\"404\"}",
        sha1.dropLast() + "g",
    ] {
        #expect(baseSha(out) == nil, "\(out)")
    }
}

/// Every ref outside refs/griiy, and the files a fetch could write besides objects.
private func outsideGriiy(_ dir: String) -> String {
    let refs = git(dir, ["for-each-ref", "--format=%(refname) %(objectname)"]).split(separator: "\n")
        .filter { !$0.hasPrefix("refs/griiy/") }.joined(separator: "\n")
    let files = ["FETCH_HEAD", "objects/info/commit-graph", "objects/info/commit-graphs", "shallow"].filter {
        FileManager.default.fileExists(atPath: "\(dir)/.git/\($0)")
    }
    return refs + "\n" + files.joined(separator: " ")
}

/// A "GitHub" remote (a local repo) with PR 1, and a clone of it set up the way people set theirs up.
private func prRepos() -> (remote: TempDir, local: TempDir, base: String) {
    let remote = repo("prremote", [("a.txt", "a\n")])
    let base = git(remote.path, ["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
    git(remote.path, ["checkout", "-qb", "feature"])
    write(remote.path, "a.txt", "b\n")
    git(remote.path, ["commit", "-qam", "pr"])
    git(remote.path, ["update-ref", "refs/pull/1/head", "feature"])
    // main moves on after the PR branched: the diff base is the merge-base, not main's tip.
    git(remote.path, ["checkout", "-q", "main"])
    write(remote.path, "z.txt", "z\n")
    git(remote.path, ["add", "z.txt"])
    git(remote.path, ["commit", "-qm", "later"])
    git(remote.path, ["update-ref", "-d", "refs/heads/feature"])
    let local = TempDir("prlocal")
    git(local.path, ["clone", "-q", remote.path, "."])
    // A tag the PR's commit picks up after the clone: a plain fetch would bring it along.
    git(remote.path, ["tag", "v-pr", "refs/pull/1/head"])
    // Settings that make a plain fetch write more than refs/griiy.
    git(local.path, ["config", "--add", "remote.origin.fetch", "+refs/pull/*/head:refs/remotes/origin/pr/*"])
    git(local.path, ["config", "fetch.writeCommitGraph", "true"])
    git(local.path, ["config", "fetch.prune", "true"])
    git(local.path, ["update-ref", "refs/remotes/origin/stale", "HEAD"])
    return (remote, local, base)
}

@Test func fetchWritesOnlyGriiyRefs() throws {
    let (remote, local, base) = prRepos()
    let dir = FilePath(local.path)
    let tip = git(remote.path, ["rev-parse", "main"]).trimmingCharacters(in: .whitespacesAndNewlines)
    let before = outsideGriiy(local.path)
    let pr = gh("O", "R")
    let shas = try fetchPullRequest(dir, remote: "origin", pr, 1, base: tip)
    #expect(outsideGriiy(local.path) == before)
    #expect(shas.base == tip)
    #expect(
        shas.head
            == git(remote.path, ["rev-parse", "refs/pull/1/head"]).trimmingCharacters(in: .whitespacesAndNewlines))
    #expect(git(local.path, ["rev-parse", "refs/griiy/gh/o/r/1/head"]).hasPrefix(shas.head))
    #expect(try mergeBase(dir, shas.base, shas.head, label: "o/r#1") == base)

    // Force-push: the PR now points at an unrelated commit, and fetching again follows it.
    git(remote.path, ["checkout", "-q", "--orphan", "other"])
    git(remote.path, ["commit", "-qm", "rewritten"])
    git(remote.path, ["update-ref", "refs/pull/1/head", "other"])
    let again = try fetchPullRequest(dir, remote: "origin", pr, 1, base: tip)
    #expect(again.head == git(remote.path, ["rev-parse", "other"]).trimmingCharacters(in: .whitespacesAndNewlines))
    #expect(outsideGriiy(local.path) == before)
    // The base can move backwards too (a base branch reset, or a closed PR's older base).
    #expect(try fetchPullRequest(dir, remote: "origin", pr, 1, base: base).base == base)
    // No common ancestor now.
    #expect(throws: GitError.badRange(spec: "o/r#1", detail: "no common ancestor")) {
        try mergeBase(dir, again.base, again.head, label: "o/r#1")
    }
}

@Test func openingAPullRequest() throws {
    let (remote, local, base) = prRepos()
    defer { withExtendedLifetime(remote) {} }
    let dir = FilePath(local.path)
    let tip = git(local.path, ["rev-parse", "main"]).trimmingCharacters(in: .whitespacesAndNewlines)
    // What open does after gh answers, for a URL and for `#n` alike: both arrive with the repo.
    let (spec, b, head) = try Review.pullRequest(dir, remote: "origin", gh("O", "R"), 1, base: tip, cancel: nil)
    #expect(spec == .pullRequest(repo: gh("o", "r"), number: 1))
    #expect(spec.label == "o/r#1")
    #expect(b == base)
    #expect(
        head
            == .sha(
                git(local.path, ["rev-parse", "refs/griiy/gh/o/r/1/head"]).trimmingCharacters(
                    in: .whitespacesAndNewlines)))
    let review = Review(repo: dir, spec: spec, base: b, head: head, files: [], tracked: "", gitMs: 0)
    #expect(review.key == reviewKey(.gitHub(owner: "o", repo: "r", number: 1)))
}

@Test func fetchFailures() throws {
    let (remote, local, _) = prRepos()
    defer { withExtendedLifetime(remote) {} }
    let dir = FilePath(local.path)
    let tip = git(local.path, ["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
    for (remote, n, base) in [
        ("origin", 2, tip), ("origin", 1, String(repeating: "1", count: 40)), ("nowhere", 1, tip),
        // An ssh failure is about the remote, never the user's checkout.
        ("ssh://git@127.0.0.1:1/o/r.git", 1, tip),
        // Error text quotes the URL: a token in it stays off the screen.
        ("https://me:secret@127.0.0.1:1/o/r.git", 1, tip),
    ] {
        do {
            _ = try fetchPullRequest(dir, remote: remote, gh("o", "r"), n, base: base)
            Issue.record("fetched \(remote) #\(n)")
        } catch {
            guard case .fetchFailed(remote, let detail) = error else {
                Issue.record("\(remote) #\(n): \(error)")
                continue
            }
            #expect(!detail.isEmpty && !detail.contains("secret"), "\(detail)")
        }
    }
}

@Test func shallowCloneSaysSo() throws {
    let (remote, _, _) = prRepos()
    let shallow = TempDir("prshallow")
    git(shallow.path, ["clone", "-q", "--depth=1", "file://\(remote.path)", "."])
    let dir = FilePath(shallow.path)
    let tip = git(shallow.path, ["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
    let shas = try fetchPullRequest(dir, remote: "origin", gh("o", "r"), 1, base: tip)
    do {
        _ = try mergeBase(dir, shas.base, shas.head, label: "o/r#1")
        Issue.record("found a merge-base in a depth-1 clone")
    } catch {
        guard case .badRange(_, let detail) = error else { return #expect(Bool(false), "\(error)") }
        #expect(detail.contains("--unshallow"))
    }
}
