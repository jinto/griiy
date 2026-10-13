// GitHub PRs (F-PR-1): owner/repo from a PR URL or the remotes, and the remote to fetch from.
import Foundation
import System

/// A github.com repository, lowercased: GitHub names ignore case, and so do the store key and
/// macOS ref files. Only GitHub's own name characters get in, so no `/`, `%`, space or NUL. Names
/// like `.github` still aren't valid ref components: `prRefs` encodes them.
public struct GitHubRepo: Equatable, Sendable {
    public let owner: String
    public let name: String

    public init?(owner: some StringProtocol, name: some StringProtocol) {
        func only(_ s: some StringProtocol, _ extra: String) -> Bool {
            !s.isEmpty
                && s.utf8.allSatisfy {
                    (UInt8(ascii: "a")...UInt8(ascii: "z")).contains($0 | 0x20)
                        || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) || extra.utf8.contains($0)
                }
        }
        // GitHub drops `.git` from names, so `r.git` in a URL is `r`.
        let name = Substring(name.hasSuffix(".git") ? name.dropLast(4) : name[...])
        guard only(owner, "-"), only(name, "-._"), name != ".", name != ".." else { return nil }
        self.owner = owner.lowercased()
        self.name = name.lowercased()
    }

    var label: String { "\(owner)/\(name)" }
}

/// `https://github.com/<owner>/<repo>/pull/<n>[/…][?…][#…]` or `#<n>`; nil for anything else. Any
/// path after the number is fine: GitHub's PR tabs (`/files`, `/commits/<sha>`, …) come and go.
func pullRequest(_ arg: String) -> Spec? {
    if arg.hasPrefix("#") { return number(arg.dropFirst()).map { .pullRequest(repo: nil, number: $0) } }
    guard let scheme = ["https://", "http://"].first(where: arg.lowercased().hasPrefix) else { return nil }
    let rest = arg.dropFirst(scheme.count).prefix { $0 != "?" && $0 != "#" }
    let parts = rest.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count >= 5, ["github.com", "www.github.com"].contains(parts[0].lowercased()), parts[3] == "pull",
        let repo = GitHubRepo(owner: parts[1], name: parts[2]), let n = number(parts[4])
    else { return nil }
    return .pullRequest(repo: repo, number: n)
}

/// A PR number: digits only, at least 1.
private func number(_ s: Substring) -> Int? {
    guard !s.isEmpty, s.utf8.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }), let n = Int(s), n > 0
    else { return nil }
    return n
}

/// owner/repo of a github.com remote URL (`https://…`, `ssh://…`, `git@github.com:o/r.git`), nil
/// for any other host or shape.
func gitHubRepo(remoteURL url: String) -> GitHubRepo? {
    var host: Substring
    var path: Substring
    if let sep = url.range(of: "://") {
        // Transports GitHub serves; anything else (ftp, a remote helper) isn't GitHub.
        guard ["https", "http", "ssh", "git", "git+ssh", "ssh+git"].contains(url[..<sep.lowerBound].lowercased())
        else { return nil }
        let rest = url[sep.upperBound...]
        host = rest.prefix { $0 != "/" }
        path = rest.dropFirst(host.count)
        if let at = host.lastIndex(of: "@") { host = host[host.index(after: at)...] }
        if let colon = host.lastIndex(of: ":") { host = host[..<colon] }
    } else {
        // scp-like `[user@]host:path`: a colon before any slash, or git reads it as a local path.
        guard let colon = url.firstIndex(of: ":"), !url[..<colon].contains("/") else { return nil }
        (host, path) = (url[..<colon], url[url.index(after: colon)...])
    }
    if let at = host.lastIndex(of: "@") { host = host[host.index(after: at)...] }
    guard ["github.com", "www.github.com", "ssh.github.com"].contains(host.lowercased()) else { return nil }
    if path.hasPrefix("/") { path = path.dropFirst() }
    if path.hasSuffix("/") { path = path.dropLast() }
    let parts = path.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 2 else { return nil }
    return GitHubRepo(owner: parts[0], name: parts[1])
}

/// The remote to fetch PR `number` from, given `git remote -v` output: one whose fetch URL is
/// `want`, or for `#n` (`want == nil`) the only GitHub repo among the remotes. Several fit: upstream,
/// then origin, then the first by name.
func prRemote(_ remotes: String, _ want: GitHubRepo?, number: Int) throws(GitError) -> (
    remote: String, repo: GitHubRepo
) {
    // `name<TAB>url (fetch)`. A remote with only a pushurl prints `name<TAB>`.
    let all: [(remote: String, repo: GitHubRepo)] = remotes.split(separator: "\n").compactMap { line in
        guard let tab = line.firstIndex(of: "\t"), line.hasSuffix(" (fetch)") else { return nil }
        let url = line[line.index(after: tab)...].dropLast(" (fetch)".count).trimmingCharacters(in: .whitespaces)
        return gitHubRepo(remoteURL: url).map { (String(line[..<tab]), $0) }
    }
    var fits = all.filter { want == nil || $0.repo == want }
    if want == nil && Set(fits.map(\.repo.label)).count > 1 {
        fits = fits.filter { ["upstream", "origin"].contains($0.remote) }
    }
    guard
        let pick = fits.first(where: { $0.remote == "upstream" }) ?? fits.first(where: { $0.remote == "origin" })
            ?? fits.min(by: { $0.remote < $1.remote })
    else {
        // Names and owner/repo only: a remote URL can carry a token.
        throw .noRemote(
            want: want, number: number,
            detail: all.map { "\($0.remote) → github.com/\($0.repo.label)" }.joined(separator: "\n"))
    }
    return pick
}

/// Where PR `number`'s `head` and `base` are fetched to (F-PR-1). Bytes outside `[a-z0-9_-]` become
/// `%XX`, so names that aren't valid ref components (`.github`, `a..b`, `x.lock`) still make refs.
func prRefs(_ pr: GitHubRepo, _ number: Int) -> String {
    func ref(_ s: String) -> String {
        s.utf8.map { b in
            (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(b) || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(b)
                || b == UInt8(ascii: "_") || b == UInt8(ascii: "-")
                ? String(UnicodeScalar(b)) : String(format: "%%%02X", b)
        }.joined()
    }
    return "refs/griiy/gh/\(ref(pr.owner))/\(ref(pr.name))/\(number)"
}

/// The PR's base commit as GitHub last synced it, kept as it was once closed or merged (closed PRs
/// have no `refs/pull/<n>/merge` to find it from). Blocking. The REST call, not `pullRequestInfo`:
/// that one takes seconds on a busy PR, so it runs alongside the fetch instead of before it.
func pullBase(_ pr: GitHubRepo, _ number: Int, cancel: Cancel?) throws(GitError) -> String {
    // --hostname: GH_HOST could point gh at another server.
    let args = ["api", "--hostname", "github.com", "repos/\(pr.label)/pulls/\(number)", "--jq", ".base.sha"]
    let (status, out, err): (Int32, [UInt8], [UInt8])
    do {
        (status, out, err) = try spawn("gh", repo: nil, args, cancel: cancel)
    } catch .gitMissing {
        throw .ghMissing
    }
    let answer = String(decoding: out, as: UTF8.self)
    guard status == 0, let sha = baseSha(answer) else {
        if isAuthFailure(status, err) { throw .ghAuth }
        let why = String(decoding: err, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        throw .fetchFailed(remote: "GitHub", detail: why.isEmpty ? "unexpected answer: \(answer.prefix(200))" : why)
    }
    return sha
}

/// gh's answer for `.base.sha`: one full lowercase object id (SHA-1 or SHA-256) and a newline,
/// nothing else. It goes into a refspec, and a 404 prints a JSON body here.
func baseSha(_ out: String) -> String? {
    let sha = out.hasSuffix("\n") ? out.dropLast() : out[...]
    guard [40, 64].contains(sha.utf8.count),
        sha.utf8.allSatisfy({
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0)
        })
    else { return nil }
    return String(sha)
}

/// Fetches PR `number` and commit `base` into `prRefs` and returns both shas. Blocking. The options
/// keep the fetch to refs/griiy (F-PR-6) whatever the user's config says: no remote-tracking
/// refs from `remote.*.fetch` (--refmap=), no FETCH_HEAD, tags, submodules, maintenance or
/// commit-graph. `+`: a force-pushed PR fetches again.
// ponytail: two windows opening the same PR while it is force-pushed can read each other's refs;
// both are real PR commits. Fetch into per-run refs if that ever matters.
func fetchPullRequest(
    _ repo: FilePath, remote: String, _ pr: GitHubRepo, _ number: Int, base: String, cancel: Cancel? = nil
)
    throws(GitError) -> (base: String, head: String)
{
    let ns = prRefs(pr, number)
    let args = [
        "-c", "fetch.writeCommitGraph=false", "fetch", "--no-tags", "--quiet", "--refmap=", "--no-write-fetch-head",
        "--no-recurse-submodules", "--no-auto-maintenance", "--end-of-options", remote,
        "+refs/pull/\(number)/head:\(ns)/head", "+\(base):\(ns)/base",
    ]
    // Not `run`: its stderr reading would call ssh's "Permission denied" the checkout's fault.
    let (status, _, err) = try spawn("git", repo: repo, args, cancel: cancel)
    guard status == 0 else {
        let why = String(decoding: err, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        // git leaves tokens in remote URLs out of its messages (tested). --quiet can leave it empty.
        throw .fetchFailed(remote: remote, detail: why.isEmpty ? "git fetch exited with \(status)" : why)
    }
    let shas = try git(repo, ["rev-parse", "\(ns)/base^{commit}", "\(ns)/head^{commit}"], cancel: cancel)
        .split(separator: "\n").map(String.init)
    guard shas.count == 2 else { throw .git(detail: "can't read \(ns)") }
    return (shas[0], shas[1])
}

// ---- The PR as GitHub has it (F-PR-4, F-AI-2 ③): one GraphQL query ----

public struct PullRequest: Equatable, Sendable {
    public var title, body, author, url: String
    /// OPEN, CLOSED or MERGED, as GitHub says it.
    public var state: String
    /// Issue comments and reviews, oldest first. Bodies are Markdown as written (F-PR-5 is the panel's).
    public var comments: [Comment]
    public var threads: [ReviewThread]
    /// GitHub's linked issues: closed by a keyword in the body, or linked by hand.
    public var issues: [LinkedIssue]
    /// A list had more than the query asks for (100 each, 20 issues): GitHub has the rest.
    public var truncated: Bool
}

public struct Comment: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case issue
        case review(state: String)
        case reviewComment
    }
    public var kind: Kind
    public var author, body: String
    /// ISO-8601 UTC, as GitHub sends it.
    public var created: String
    /// Its page on GitHub; the anchor tells the kind and id (`#issuecomment-…`, `#discussion_r…`).
    public var url: String
}

/// Line comments on one spot, replies in order.
public struct ReviewThread: Equatable, Sendable {
    public var path: String
    public var side: Side
    /// File lines on `side` in this diff; nil when there is no place for it: outdated, a file
    /// comment, or anything GitHub sends that doesn't fit.
    public var lines: Range<Int>?
    public var resolved, outdated: Bool
    public var comments: [Comment]
}

public struct LinkedIssue: Equatable, Sendable {
    public var number: Int
    /// owner/name: a linked issue can be in another repository.
    public var repo, title, body, state, url: String
}

private let prQuery = """
    query($owner: String!, $name: String!, $n: Int!) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $n) {
          title body state url author { login }
          comments(first: 100) { totalCount nodes { author { login } body createdAt url } }
          reviews(first: 100, states: [APPROVED, CHANGES_REQUESTED, COMMENTED, DISMISSED]) {
            totalCount nodes { author { login } body state submittedAt url }
          }
          reviewThreads(first: 100) {
            totalCount
            nodes {
              path diffSide startDiffSide line startLine isResolved isOutdated subjectType
              comments(first: 100) { totalCount nodes { author { login } body createdAt url state } }
            }
          }
          closingIssuesReferences(first: 20) {
            totalCount nodes { number title body state url repository { nameWithOwner } }
          }
        }
      }
    }
    """

/// PR `number`'s title, body, comments, line comments and linked issues. Blocking; seconds on a busy PR.
// ponytail: no paging past 100 per list; `truncated` says so. Page with `after:` if it matters.
func pullRequestInfo(_ pr: GitHubRepo, _ number: Int, cancel: Cancel?) throws(GitError) -> PullRequest {
    // -f: owner and name stay strings (-F would make `123` a number and read `@x` from a file).
    let args = [
        "api", "graphql", "--hostname", "github.com", "-f", "owner=\(pr.owner)", "-f", "name=\(pr.name)", "-F",
        "n=\(number)", "-f", "query=\(prQuery)",
    ]
    do {
        let (status, out, err) = try spawn("gh", repo: nil, args, cancel: cancel)
        return try decodePullRequest(status: status, out: out, err: err)
    } catch .gitMissing {
        throw .ghMissing
    }
}

/// gh's answer, judged by what is on stdout: any GraphQL `errors` entry makes gh exit 1 even
/// when the PR came back whole (a linked issue we can't see), and then the PR still opens.
func decodePullRequest(status: Int32, out: [UInt8], err: [UInt8]) throws(GitError) -> PullRequest {
    if isAuthFailure(status, err) { throw .ghAuth }
    let stderr = String(decoding: err, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    let answer = try? JSONDecoder().decode(Answer.self, from: Data(out))
    if let pr = answer?.data?.repository?.pullRequest { return pr.model }
    let why = answer?.errors?.first?.message ?? (stderr.hasPrefix("gh: ") ? String(stderr.dropFirst(4)) : stderr)
    throw .fetchFailed(
        remote: "GitHub",
        detail: !why.isEmpty ? why : status != 0 ? "gh exited with \(status)" : "unexpected answer from gh")
}

/// Not logged in is exit 4; a revoked or expired token is exit 1 with GitHub's 401.
private func isAuthFailure(_ status: Int32, _ err: [UInt8]) -> Bool {
    status == 4 || String(decoding: err, as: UTF8.self).contains("(HTTP 401)")
}

/// File lines `start...end`, or nil unless both are real line numbers in order.
func lineRange(_ start: Int?, _ end: Int?) -> Range<Int>? {
    guard let end, end < Int.max else { return nil }
    let start = start ?? end
    guard start > 0, start <= end else { return nil }
    return start..<end + 1
}

// The answer's shape. Everything GitHub may leave out or null is optional.
private struct Answer: Decodable {
    struct Data: Decodable { var repository: Repository? }
    struct Repository: Decodable { var pullRequest: PR? }
    struct Failure: Decodable { var message: String? }
    var data: Data?
    var errors: [Failure]?
}

private struct Login: Decodable { var login: String }

private struct List<T: Decodable>: Decodable {
    var totalCount: Int
    /// Null, or holding nulls, where a partial error left a gap; GitHub still has those.
    var nodes: [T?]?
    var all: [T] { (nodes ?? []).compactMap { $0 } }
    var cut: Bool { totalCount > all.count }
}

private struct PR: Decodable {
    struct Note: Decodable {
        var author: Login?
        var body: String
        var createdAt: String?
        var submittedAt: String?
        var url: String
        var state: String?
        func model(_ kind: Comment.Kind) -> Comment {
            // A deleted account comes back null; GitHub's pages call it ghost.
            Comment(
                kind: kind, author: author?.login ?? "ghost", body: body, created: createdAt ?? submittedAt ?? "",
                url: url)
        }
    }
    struct Thread: Decodable {
        var path: String
        var diffSide, startDiffSide, subjectType: String?
        var line, startLine: Int?
        var isResolved, isOutdated: Bool
        var comments: List<Note>
    }
    struct Issue: Decodable {
        struct Repo: Decodable { var nameWithOwner: String }
        var number: Int
        var title, body, state, url: String
        var repository: Repo
    }
    var title, body, state, url: String
    var author: Login?
    var comments: List<Note>
    /// Nullable in GitHub's schema: a partial error can null them out.
    var reviews: List<Note>?
    var reviewThreads: List<Thread>
    var closingIssuesReferences: List<Issue>?

    var model: PullRequest {
        // A COMMENTED review with no body is only the envelope its line comments came in.
        let said = (reviews?.all ?? []).filter { !$0.body.isEmpty || $0.state != "COMMENTED" }
        let notes =
            comments.all.map { $0.model(.issue) } + said.map { $0.model(.review(state: $0.state ?? "")) }
        // A thread holding only the viewer's unsent drafts isn't there for anyone else.
        let threads = reviewThreads.all.filter { $0.comments.all.contains { $0.state == "SUBMITTED" } }.map { t in
            let side: Side? = ["LEFT": .base, "RIGHT": .head][t.diffSide ?? ""]
            // A range across both sides (a -/+ block) keeps its end line; span() widens it to the block.
            let start = (t.startDiffSide ?? t.diffSide) == t.diffSide ? t.startLine : nil
            let placed = side != nil && !t.isOutdated && t.subjectType == "LINE"
            return ReviewThread(
                path: t.path, side: side ?? .head, lines: placed ? lineRange(start, t.line) : nil,
                resolved: t.isResolved, outdated: t.isOutdated,
                // A PENDING comment is an unsent draft, seen only by its author.
                comments: t.comments.all.filter { $0.state == "SUBMITTED" }.map { $0.model(.reviewComment) })
        }
        return PullRequest(
            title: title, body: body, author: author?.login ?? "ghost", url: url, state: state,
            // ISO-8601 UTC strings of one format sort as times; ties keep their order (sort is stable).
            comments: notes.sorted { $0.created < $1.created },
            threads: threads,
            issues: (closingIssuesReferences?.all ?? []).map {
                LinkedIssue(
                    number: $0.number, repo: $0.repository.nameWithOwner, title: $0.title, body: $0.body,
                    state: $0.state, url: $0.url)
            },
            truncated: comments.cut || reviews?.cut ?? true || reviewThreads.cut || closingIssuesReferences?.cut ?? true
                || reviewThreads.all.contains { $0.comments.cut })
    }
}
