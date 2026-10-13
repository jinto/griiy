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

/// The PR's base commit as GitHub has it: the base branch tip while open, kept as it was once
/// closed or merged (closed PRs have no `refs/pull/<n>/merge` to find it from). Blocking.
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
