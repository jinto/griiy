// Bitbucket Cloud PRs (F-PR-2): the API names the PR's branches and commits, git fetches them.
// Bitbucket has no PR refs, so the branches are fetched by name and the API's commits pin base
// and head (a merged PR's branch is already in its target, and may be gone).
import Foundation
import System

/// An Atlassian account's email and API token, sent as HTTP Basic auth to api.bitbucket.org only.
public struct BitbucketAuth: Sendable {
    public var email, token: String

    public init(email: String, token: String) {
        self.email = email
        self.token = token
    }
}

/// Bitbucket's JSON is snake_case.
private let snake = {
    let d = JSONDecoder()
    d.keyDecodingStrategy = .convertFromSnakeCase
    return d
}()

/// What griiy needs of a Bitbucket PR.
struct BitbucketPR: Equatable, Sendable {
    var info: PullRequest
    /// Branch names, as Bitbucket sent them (checked before they reach git).
    var source, destination: String
    /// Where the source branch lives: this repo, a fork, or nil once the fork is deleted.
    var sourceRepo: HostedRepo?
    /// Bitbucket's 12-character commit hashes, when it sent them.
    var sourceCommit, destinationCommit, mergeCommit: String?
    var open: Bool
}

/// GET `https://api.bitbucket.org/2.0/<path>`. Blocking. `config` is where tests put their
/// URLProtocol. The token goes to that one host: redirects are refused.
func bitbucketGet(
    _ path: String, _ query: [URLQueryItem] = [], auth: BitbucketAuth?, cancel: Cancel?,
    config: URLSessionConfiguration = .ephemeral
) throws(GitError) -> (status: Int, body: Data) {
    var c = URLComponents()
    c.scheme = "https"
    c.host = "api.bitbucket.org"
    c.path = "/2.0/" + path
    c.queryItems = query.isEmpty ? nil : query
    guard let url = c.url else { throw .git(detail: "bad Bitbucket URL: \(path)") }
    var req = URLRequest(url: url, timeoutInterval: 30)
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    if let auth {
        let basic = Data("\(auth.email):\(auth.token)".utf8).base64EncodedString()
        req.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
    }
    config.httpCookieStorage = nil
    config.urlCache = nil
    config.urlCredentialStorage = nil
    let reply = Reply()
    let session = URLSession(configuration: config, delegate: reply, delegateQueue: nil)
    let task = session.dataTask(with: req)
    cancel?.onCancel { task.cancel() }
    task.resume()
    reply.done.wait()
    session.finishTasksAndInvalidate()
    if cancel?.isCancelled == true { throw .cancelled }
    return try reply.result()
}

/// The delegate of one request; its callbacks come one at a time, `result()` reads after `done`.
private final class Reply: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let done = DispatchSemaphore(value: 0)
    private var status = 0
    private var body = Data()
    private var failure: String?

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)  // the 3xx itself comes back as the answer
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        status = (response as? HTTPURLResponse)?.statusCode ?? 0
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if body.count < 8 << 20 { body += data }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        failure = error?.localizedDescription
        done.signal()
    }

    func result() throws(GitError) -> (status: Int, body: Data) {
        if let failure { throw .fetchFailed(remote: "Bitbucket", detail: failure) }
        return (status, body)
    }
}

/// The error for a non-200 answer. Asked without a token, a private repo answers 401, 403 or 404:
/// all ask for one. With a token, only 401 does; 403 and 404 say what's missing, so a saved token
/// that lacks a scope doesn't bring the token form back forever.
func bitbucketFailure(_ status: Int, _ body: Data, auth: BitbucketAuth?) -> GitError {
    if status == 401 || (auth == nil && [403, 404].contains(status)) { return .bitbucketAuth }
    struct Answer: Decodable {
        struct Inner: Decodable { var message: String? }
        var error: Inner?
    }
    var why = (try? JSONDecoder().decode(Answer.self, from: body))?.error?.message ?? ""
    why = String(why.split(whereSeparator: \.isNewline).first?.prefix(300) ?? "")
    // Server text shown on screen never carries the token, even if the server echoed it.
    if let auth, !auth.token.isEmpty { why = why.replacingOccurrences(of: auth.token, with: "<token>") }
    let missing =
        [403, 404].contains(status)
        ? " The token may lack read:pullrequest:bitbucket or read:repository:bitbucket, or this account can't see it."
        : ""
    return .fetchFailed(remote: "Bitbucket", detail: "HTTP \(status)\(why.isEmpty ? "" : ": " + why).\(missing)")
}

/// PR `number` of `pr`. Blocking.
func bitbucketPR(_ pr: HostedRepo, _ number: Int, auth: BitbucketAuth?, cancel: Cancel?) throws(GitError)
    -> BitbucketPR
{
    let (status, body) = try bitbucketGet(
        "repositories/\(pr.owner)/\(pr.name)/pullrequests/\(number)", auth: auth, cancel: cancel)
    guard status == 200 else { throw bitbucketFailure(status, body, auth: auth) }
    return try decodeBitbucketPR(body)
}

func decodeBitbucketPR(_ body: Data) throws(GitError) -> BitbucketPR {
    struct Ref: Decodable {
        struct Name: Decodable { var name: String }
        struct Commit: Decodable { var hash: String }
        struct Repo: Decodable { var fullName: String }
        var branch: Name?
        var commit: Commit?
        var repository: Repo?
    }
    struct Answer: Decodable {
        struct User: Decodable { var displayName: String? }
        struct Text: Decodable { var raw: String? }
        struct Links: Decodable {
            struct Href: Decodable { var href: String }
            var html: Href?
        }
        var title: String
        var summary: Text?
        var author: User?
        var state: String
        var links: Links?
        var source, destination: Ref
        var mergeCommit: Ref.Commit?
    }
    guard let a = try? snake.decode(Answer.self, from: body), let source = a.source.branch?.name,
        let destination = a.destination.branch?.name
    else { throw .fetchFailed(remote: "Bitbucket", detail: "unexpected answer from api.bitbucket.org") }
    let fork = a.source.repository.flatMap { r -> HostedRepo? in
        let parts = r.fullName.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 ? HostedRepo(.bitbucket, owner: parts[0], name: parts[1]) : nil
    }
    let info = PullRequest(
        title: a.title, body: a.summary?.raw ?? "", author: a.author?.displayName ?? "ghost",
        url: a.links?.html?.href ?? "", state: a.state, comments: [], threads: [], issues: [], truncated: false)
    return BitbucketPR(
        info: info, source: source, destination: destination, sourceRepo: fork,
        sourceCommit: a.source.commit?.hash, destinationCommit: a.destination.commit?.hash,
        mergeCommit: a.mergeCommit?.hash, open: a.state == "OPEN")
}

/// Fetches PR `number`'s branches into `prRefs` and returns base and head: the commits the API
/// names where this repo has them, else the fetched tips. Blocking. A closed PR's source branch
/// may be gone; its commit usually came along with the target branch it was merged into.
func fetchBitbucketPR(
    _ repo: FilePath, remote: String, url: String, _ pr: HostedRepo, _ number: Int, _ bb: BitbucketPR,
    cancel: Cancel?
) throws(GitError) -> (base: String, head: String) {
    // Names from the API go into refspecs: git's own rules, and never an option.
    for b in [bb.source, bb.destination] {
        guard !b.hasPrefix("-"), (try? git(repo, ["check-ref-format", "refs/heads/\(b)"], cancel: cancel)) != nil
        else { throw .git(detail: "Bitbucket sent a branch name git can't use: \(b)") }
    }
    let ns = prRefs(pr, number)
    try fetchRefs(repo, from: remote, ["+refs/heads/\(bb.destination):\(ns)/base"], cancel: cancel)
    let from = bb.sourceRepo.map { $0 == pr ? remote : forkURL($0, like: url) }
    var fetched = false
    if let from {
        do {
            try fetchRefs(repo, from: from, ["+refs/heads/\(bb.source):\(ns)/head"], cancel: cancel)
            fetched = true
        } catch {
            // Closed: any failure (gone, or no access) falls back to the API's commit below.
            if bb.open || error == .cancelled { throw error }
        }
    }
    func local(_ hash: String?) -> String? {
        guard let hash, (7...64).contains(hash.utf8.count),
            hash.utf8.allSatisfy({
                (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
                    || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0)
            })
        else { return nil }
        return try? resolve(repo, hash, cancel: cancel)
    }
    let tip = { (side: String) in try? resolve(repo, "\(ns)/\(side)", cancel: cancel) }
    // An open PR is compared with its target as it is now (merge-base takes care of a target
    // that moved); a closed one with the target Bitbucket recorded.
    guard let base = (bb.open ? nil : local(bb.destinationCommit)) ?? tip("base") else {
        throw .git(detail: "can't read \(ns)/base")
    }
    // An open PR shows its branch as it is now; a closed one as Bitbucket recorded it.
    guard let head = (bb.open ? nil : local(bb.sourceCommit)) ?? (fetched ? tip("head") : nil) else {
        let gone =
            bb.sourceRepo == nil
            ? "The pull request's fork was deleted." : "The pull request's branch \(bb.source) is gone."
        let merged = bb.mergeCommit.map { " Its merge commit shows the change: griiy \($0)^1..\($0)" } ?? ""
        throw .fetchFailed(remote: remote, detail: gone + merged)
    }
    return (base, head)
}

/// A fork's URL, made from its name in the transport of the remote's `url` (ssh keys, port 443,
/// or https), never by editing that URL: it can carry a user or a token.
func forkURL(_ fork: HostedRepo, like url: String) -> String {
    let u = url.lowercased()
    if u.hasPrefix("https://") || u.hasPrefix("http://") { return "https://bitbucket.org/\(fork.label).git" }
    if u.contains("altssh.bitbucket.org") { return "ssh://git@altssh.bitbucket.org:443/\(fork.label).git" }
    return "git@bitbucket.org:\(fork.label).git"
}

/// The open PRs of `pr`, newest first, at most 50. Blocking.
func bitbucketOpenPRs(_ pr: HostedRepo, auth: BitbucketAuth?, cancel: Cancel?) throws(GitError) -> [OpenPR] {
    let query = [
        URLQueryItem(name: "state", value: "OPEN"), URLQueryItem(name: "pagelen", value: "50"),
        URLQueryItem(
            name: "fields", value: "values.id,values.title,values.author.display_name,values.source.branch.name"),
    ]
    let (status, body) = try bitbucketGet(
        "repositories/\(pr.owner)/\(pr.name)/pullrequests", query, auth: auth, cancel: cancel)
    guard status == 200 else { throw bitbucketFailure(status, body, auth: auth) }
    return try decodeBitbucketList(body)
}

func decodeBitbucketList(_ body: Data) throws(GitError) -> [OpenPR] {
    struct Answer: Decodable {
        struct Row: Decodable {
            struct User: Decodable { var displayName: String? }
            struct Ref: Decodable {
                struct Name: Decodable { var name: String }
                var branch: Name?
            }
            var id: Int
            var title: String
            var author: User?
            var source: Ref?
        }
        var values: [Row]
    }
    guard let a = try? snake.decode(Answer.self, from: body) else {
        throw .fetchFailed(remote: "Bitbucket", detail: "unexpected answer from api.bitbucket.org")
    }
    return a.values.map {
        OpenPR(
            number: $0.id, title: $0.title, author: $0.author?.displayName ?? "ghost",
            branch: $0.source?.branch?.name ?? "")
    }
}
