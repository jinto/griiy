// M6-1 (F-PR-2): Bitbucket Cloud PRs, from the URL to the fetched commits.
import Foundation
import Synchronization
import System
import Testing

@testable import GriiyCore

private func bb(_ owner: String, _ name: String) -> HostedRepo { HostedRepo(.bitbucket, owner: owner, name: name)! }

private func remotes(_ pairs: [(String, String)]) -> String {
    pairs.map { "\($0.0)\t\($0.1) (fetch)\n\($0.0)\t\($0.1) (push)\n" }.joined()
}

@Test func bitbucketURLs() {
    for url in [
        "https://bitbucket.org/Loco_Labs/Repo.git/pull-requests/42",
        "https://bitbucket.org/loco_labs/repo/pull-requests/42/",
        "https://bitbucket.org/loco_labs/repo/pull-requests/42/diff?w=1#chg",
        "http://www.bitbucket.org/loco_labs/repo/pull-requests/42",
    ] {
        #expect(pullRequest(url) == .pullRequest(repo: bb("loco_labs", "repo"), number: 42), "\(url)")
    }
    for url in [
        "https://bitbucket.org/w/r/pull/42", "https://bitbucket.org/w/r/pull-requests/x",
        "https://bitbucket.org/w/pull-requests/42", "https://github.com/o/r/pull-requests/1",
        "https://bitbucket.org.evil.com/w/r/pull-requests/1",
    ] {
        #expect(pullRequest(url) == nil, "\(url)")
    }
    // `_` is a workspace character on Bitbucket, not an owner one on GitHub.
    #expect(HostedRepo(.gitHub, owner: "a_b", name: "r") == nil)
    #expect(bb("w", "r") != HostedRepo(.gitHub, owner: "w", name: "r"))
}

@Test func bitbucketRemotes() {
    for url in [
        "git@bitbucket.org:Loco_Labs/repo.git", "https://user@bitbucket.org/loco_labs/repo.git",
        "ssh://git@altssh.bitbucket.org:443/loco_labs/repo.git", "https://bitbucket.org/loco_labs/repo",
    ] {
        #expect(hostedRepo(remoteURL: url) == bb("loco_labs", "repo"), "\(url)")
    }
    #expect(hostedRepo(remoteURL: "git@bitbucket.org.evil.com:w/r.git") == nil)
}

@Test func numberWithBothHostsIsAQuestion() throws {
    let both = remotes([("origin", "git@bitbucket.org:w/r.git"), ("upstream", "https://github.com/o/r")])
    #expect(
        throws: GitError.noRemote(want: nil, number: 3, detail: "origin → bitbucket.org/w/r\nupstream → github.com/o/r")
    ) {
        try prRemote(both, nil, number: 3)
    }
    // The URL settles it, and the remote's URL comes back for a fork's transport.
    let pick = try prRemote(both, bb("w", "r"), number: 3)
    #expect(pick.remote == "origin" && pick.url == "git@bitbucket.org:w/r.git")
    #expect(try prRemote(remotes([("origin", "git@bitbucket.org:w/r.git")]), nil, number: 3).repo == bb("w", "r"))
}

/// A trimmed real answer of `GET /2.0/repositories/{ws}/{repo}/pullrequests/{id}`.
private func answer(
    state: String = "OPEN", source: String = "feature", sourceRepo: String? = #"{"full_name":"w/r"}"#,
    sourceHash: String = "aaaaaaaaaaaa", destHash: String = "bbbbbbbbbbbb", author: String = #"{"display_name":"Jay"}"#
) -> Data {
    Data(
        """
        {"id":7,"title":"Fix it","state":"\(state)","author":\(author),
         "summary":{"raw":"Body **md**","markup":"markdown"},
         "links":{"html":{"href":"https://bitbucket.org/w/r/pull-requests/7"}},
         "source":{"branch":{"name":"\(source)"},"commit":{"hash":"\(sourceHash)"},"repository":\(sourceRepo ?? "null")},
         "destination":{"branch":{"name":"main"},"commit":{"hash":"\(destHash)"},"repository":{"full_name":"w/r"}},
         "merge_commit":{"hash":"cccccccccccc"}}
        """.utf8)
}

@Test func decodesAPullRequest() throws {
    let pr = try decodeBitbucketPR(answer())
    #expect(pr.info.title == "Fix it" && pr.info.body == "Body **md**" && pr.info.author == "Jay")
    #expect(pr.info.url == "https://bitbucket.org/w/r/pull-requests/7" && pr.info.state == "OPEN" && pr.open)
    #expect(pr.source == "feature" && pr.destination == "main" && pr.sourceRepo == bb("w", "r"))
    #expect(pr.sourceCommit == "aaaaaaaaaaaa" && pr.destinationCommit == "bbbbbbbbbbbb")
    // A deleted fork and a deleted account.
    let gone = try decodeBitbucketPR(answer(state: "MERGED", sourceRepo: nil, author: "null"))
    #expect(gone.sourceRepo == nil && gone.info.author == "ghost" && !gone.open)
    #expect(gone.mergeCommit == "cccccccccccc")
    #expect(throws: GitError.self) { try decodeBitbucketPR(Data("{}".utf8)) }
}

@Test func failuresAskForATokenOnlyWhenOneCouldHelp() {
    let auth = BitbucketAuth(email: "a@b.c", token: "SECRET")
    let body = Data(#"{"type":"error","error":{"message":"Bad token SECRET here"}}"#.utf8)
    #expect(bitbucketFailure(401, body, auth: auth) == .bitbucketAuth)
    #expect(bitbucketFailure(404, body, auth: nil) == .bitbucketAuth)
    #expect(bitbucketFailure(403, body, auth: nil) == .bitbucketAuth)
    // With a token, 403/404 say what's missing instead of asking again.
    guard case .fetchFailed("Bitbucket", let detail) = bitbucketFailure(404, body, auth: auth) else {
        Issue.record("expected fetchFailed")
        return
    }
    #expect(detail.contains("HTTP 404") && detail.contains("read:pullrequest:bitbucket"))
    #expect(!detail.contains("SECRET") && detail.contains("<token>"))
}

@Test func reviewKeysDifferByHost() {
    let review = { (r: HostedRepo) in
        Review(
            repo: FilePath("/x"), spec: .pullRequest(repo: r, number: 1), base: "", head: .workTree, files: [],
            tracked: "", gitMs: 0)
    }
    #expect(review(bb("W", "R")).key == "bb-w-r-1")
    #expect(review(HostedRepo(owner: "w", name: "r")!).key == "gh-w-r-1")
}

// ---- Fetching, with a local repository as the remote ----

/// Remote: main, a later commit on main, and `feature` branched before it. Local: a clone.
private func repos() -> (remote: TempDir, local: TempDir, feature: String, mainBefore: String) {
    let remote = repo("bbremote", [("a.txt", "a\n")])
    let before = git(remote.path, ["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
    git(remote.path, ["checkout", "-qb", "feature"])
    write(remote.path, "a.txt", "b\n")
    git(remote.path, ["commit", "-qam", "pr"])
    let feature = git(remote.path, ["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
    git(remote.path, ["checkout", "-q", "main"])
    write(remote.path, "z.txt", "z\n")
    git(remote.path, ["add", "z.txt"])
    git(remote.path, ["commit", "-qm", "later"])
    let local = TempDir("bblocal")
    git(local.path, ["clone", "-q", remote.path, "."])
    return (remote, local, feature, before)
}

private func pr(
    state: String = "OPEN", source: String = "feature", sourceRepo: HostedRepo? = bb("w", "r"), sourceCommit: String?,
    destinationCommit: String?
) -> BitbucketPR {
    let info = PullRequest(
        title: "", body: "", author: "", url: "", state: state, comments: [], threads: [], issues: [], truncated: false)
    return BitbucketPR(
        info: info, source: source, destination: "main", sourceRepo: sourceRepo, sourceCommit: sourceCommit,
        destinationCommit: destinationCommit, mergeCommit: nil, open: state == "OPEN")
}

@Test func fetchesAnOpenPullRequestByBranch() throws {
    let (remote, local, feature, before) = repos()
    defer { withExtendedLifetime(remote) {} }
    let dir = FilePath(local.path)
    // Open: the branches as they are now, whatever older commits the API names.
    let main = git(remote.path, ["rev-parse", "main"]).trimmingCharacters(in: .whitespacesAndNewlines)
    let shas = try fetchBitbucketPR(
        dir, remote: "origin", url: remote.path, bb("w", "r"), 7,
        pr(sourceCommit: String(feature.prefix(12)), destinationCommit: String(before.prefix(12))), cancel: nil)
    #expect([shas.base, shas.head] == [main, feature])
    #expect(
        git(local.path, ["for-each-ref", "--format=%(refname)", "refs/griiy"])
            == "refs/griiy/bb/w/r/7/base\nrefs/griiy/bb/w/r/7/head\n")
    // Closed: the commits Bitbucket recorded; ones this repo doesn't have, the fetched tips.
    let declined = try fetchBitbucketPR(
        dir, remote: "origin", url: remote.path, bb("w", "r"), 7,
        pr(state: "DECLINED", sourceCommit: String(feature.prefix(12)), destinationCommit: String(before.prefix(12))),
        cancel: nil)
    #expect([declined.base, declined.head] == [before, feature])
    let tips = try fetchBitbucketPR(
        dir, remote: "origin", url: remote.path, bb("w", "r"), 7,
        pr(state: "DECLINED", sourceCommit: nil, destinationCommit: "0123456789ab"), cancel: nil)
    #expect([tips.base, tips.head] == [main, feature])
}

@Test func aMergedPullRequestWithItsBranchGone() throws {
    let (remote, local, feature, before) = repos()
    defer { withExtendedLifetime(remote) {} }
    git(remote.path, ["merge", "-q", "--no-ff", "-m", "merge", "feature"])
    git(remote.path, ["branch", "-qD", "feature"])
    let dir = FilePath(local.path)
    // The source branch is gone, its commit came with main: the PR as it was, not "no changes".
    let merged = pr(
        state: "MERGED", sourceCommit: String(feature.prefix(12)), destinationCommit: String(before.prefix(12)))
    let shas = try fetchBitbucketPR(dir, remote: "origin", url: remote.path, bb("w", "r"), 7, merged, cancel: nil)
    #expect([shas.base, shas.head] == [before, feature])
    // Open with its branch gone, or its fork deleted: nothing to show.
    for gone in [
        pr(sourceCommit: nil, destinationCommit: nil),
        pr(state: "DECLINED", sourceRepo: nil, sourceCommit: "0123456789ab", destinationCommit: nil),
    ] {
        #expect(throws: GitError.self) {
            try fetchBitbucketPR(dir, remote: "origin", url: remote.path, bb("w", "r"), 7, gone, cancel: nil)
        }
    }
}

@Test func branchNamesFromTheAPIAreChecked() {
    let (remote, local, _, _) = repos()
    defer { withExtendedLifetime(remote) {} }
    for name in ["-upload-pack=x", "a..b", "x.lock", "a:b", "a b"] {
        #expect(throws: GitError.self, "\(name)") {
            try fetchBitbucketPR(
                FilePath(local.path), remote: "origin", url: remote.path, bb("w", "r"), 7,
                pr(source: name, sourceCommit: nil, destinationCommit: nil), cancel: nil)
        }
    }
}

// ---- HTTP ----

final class FakeBitbucket: URLProtocol, @unchecked Sendable {
    /// Keyed by URL path.
    static let replies = Mutex<[String: (Int, [String: String], String)]>([:])
    static let seen = Mutex<[String: URLRequest]>([:])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        FakeBitbucket.seen.withLock { $0[path] = request }
        guard let (status, headers, body) = FakeBitbucket.replies.withLock({ $0[path] }), let url = request.url,
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)
        else { return client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)) ?? () }
        if (300..<400).contains(status), let to = headers["Location"].flatMap(URL.init(string:)) {
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: to), redirectResponse: response)
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func fake() -> URLSessionConfiguration {
    let c = URLSessionConfiguration.ephemeral
    c.protocolClasses = [FakeBitbucket.self]
    return c
}

@Test func requestsCarryBasicAuthToTheAPIOnly() throws {
    FakeBitbucket.replies.withLock {
        $0["/2.0/repositories/w/r/pullrequests"] = (
            200, [:], #"{"values":[{"id":3,"title":"T","author":null,"source":{"branch":{"name":"f"}}}]}"#
        )
        $0["/2.0/moved"] = (301, ["Location": "https://evil.example/steal"], "")
    }
    let auth = BitbucketAuth(email: "a@b.c", token: "tok")
    let query = [
        URLQueryItem(name: "state", value: "OPEN"), URLQueryItem(name: "fields", value: "values.id,values.title"),
    ]
    let (status, body) = try bitbucketGet(
        "repositories/w/r/pullrequests", query, auth: auth, cancel: nil, config: fake())
    #expect(status == 200)
    #expect(try decodeBitbucketList(body) == [OpenPR(number: 3, title: "T", author: "ghost", branch: "f")])
    let seen = try #require(FakeBitbucket.seen.withLock { $0["/2.0/repositories/w/r/pullrequests"] })
    #expect(seen.url?.host == "api.bitbucket.org" && seen.url?.query == "state=OPEN&fields=values.id,values.title")
    #expect(seen.value(forHTTPHeaderField: "Authorization") == "Basic " + Data("a@b.c:tok".utf8).base64EncodedString())
    // A redirect is the answer, never followed with the token.
    #expect(try bitbucketGet("moved", auth: auth, cancel: nil, config: fake()).status == 301)
    #expect(FakeBitbucket.seen.withLock { $0["/steal"] } == nil)
}

@Test func childrenDontInheritTheToken() throws {
    setenv("BITBUCKET_API_TOKEN", "tok", 1)
    defer { unsetenv("BITBUCKET_API_TOKEN") }
    let (_, out, _) = try spawn("/usr/bin/env", repo: nil, [], cancel: nil)
    #expect(!String(decoding: out, as: UTF8.self).contains("BITBUCKET_API_TOKEN"))
}

@Test func forksAreFetchedTheWayTheRemoteIs() {
    let fork = bb("me", "r")
    #expect(forkURL(fork, like: "https://user:tok@bitbucket.org/w/r.git") == "https://bitbucket.org/me/r.git")
    #expect(forkURL(fork, like: "git@bitbucket.org:w/r.git") == "git@bitbucket.org:me/r.git")
    #expect(
        forkURL(fork, like: "ssh://git@altssh.bitbucket.org:443/w/r.git")
            == "ssh://git@altssh.bitbucket.org:443/me/r.git")
}
