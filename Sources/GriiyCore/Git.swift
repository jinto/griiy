// git CLI wrapper and the errors shown on the in-window error screen (F-IN-5).
import Foundation
import Synchronization
import System

public enum GitError: Error, Equatable, Sendable {
    case gitMissing
    case ghMissing
    /// gh is there but not logged in, or its token no longer works.
    case ghAuth
    case notARepo(path: String)
    case noCommits(path: String)
    case badRange(spec: String, detail: String)
    case fetchFailed(remote: String, detail: String)
    /// No remote has the PR's repo (`want`), or for `#n` (`want` nil) no single GitHub repo to look in.
    case noRemote(want: GitHubRepo?, number: Int, detail: String)
    case permissionDenied(path: String, detail: String)
    case git(detail: String)
    case cancelled

    public var title: String {
        switch self {
        case .gitMissing: "git is not installed"
        case .ghMissing: "The GitHub CLI (gh) is not installed"
        case .ghAuth: "Log in to the GitHub CLI"
        case .notARepo(let path): "\(path) is not a git repository"
        case .noCommits(let path): "\(path) has no commits yet"
        case .badRange(let spec, _): "Unknown revision or range: \(spec)"
        case .fetchFailed(let remote, _): "Could not fetch from \(remote)"
        case .noRemote(let want?, _, _): "No remote for github.com/\(want.label)"
        case .noRemote(nil, let n, _): "Can't tell which GitHub repository #\(n) is in"
        case .permissionDenied(let path, _): "Permission denied: \(path)"
        case .git: "git failed"
        case .cancelled: "Cancelled"
        }
    }

    public var hint: String {
        switch self {
        case .gitMissing:
            "Install git (xcode-select --install or brew install git) and make sure it is on PATH."
        case .ghMissing:
            "griiy asks GitHub about pull requests through gh: brew install gh, then gh auth login."
        case .ghAuth:
            "griiy reads pull requests through gh, which isn't logged in to github.com: gh auth login. Logged in already? gh auth status shows what's wrong."
        case .notARepo: "Run griiy inside a git repository, or pass its path: griiy -C path/to/repo."
        case .noCommits: "Make a first commit, then run griiy again."
        case .badRange:
            "Check the branch or commit names. Ranges look like main..feature or main...feature. To open another repository: griiy -C path/to/repo."
        case .fetchFailed:
            "Check your network and that the remote exists. For a private repository, log in (gh auth login) and let git use it (gh auth setup-git)."
        case .noRemote(let want?, _, _):
            "Add it as a remote (git remote add upstream https://github.com/\(want.label).git), or clone it: gh repo clone \(want.label)."
        case .noRemote(nil, let n, _):
            "Pass the pull request's URL instead: griiy https://github.com/<owner>/<repo>/pull/\(n)."
        case .permissionDenied:
            "Check file permissions, or for a private repository, that you are logged in (gh auth status)."
        case .git: "git reported the error above. Fix it and run griiy again."
        case .cancelled: "The request was cancelled."
        }
    }

    public var detail: String {
        switch self {
        case .badRange(_, let d), .fetchFailed(_, let d), .noRemote(_, _, let d), .permissionDenied(_, let d),
            .git(let d):
            d
        default: ""
        }
    }
}

/// Stops the git a request is running, and any git it would start next. Cancelling kills the
/// child's whole process group (ssh, remote helpers, anything that holds the pipes).
public final class Cancel: Sendable {
    private struct State {
        var cancelled = false
        /// Every git running for this request: Review.open runs ls-files and diff at once.
        var groups: Set<pid_t> = []
        /// What else stops with the request (an HTTP request).
        var hooks: [@Sendable () -> Void] = []
    }
    private let state = Mutex(State())

    public init() {}

    public var isCancelled: Bool { state.withLock { $0.cancelled } }

    public func cancel() {
        let (groups, hooks) = state.withLock { s in
            s.cancelled = true
            defer { s.hooks = [] }
            return (s.groups, s.hooks)
        }
        for group in groups { kill(-group, SIGKILL) }
        for hook in hooks { hook() }
    }

    /// Runs `hook` when the request is cancelled, or now if it already is.
    func onCancel(_ hook: @escaping @Sendable () -> Void) {
        let cancelled = state.withLock { s in
            if !s.cancelled { s.hooks.append(hook) }
            return s.cancelled
        }
        if cancelled { hook() }
    }

    /// Records a running group, or kills it at once if the request is already cancelled.
    fileprivate func start(_ group: pid_t) {
        let cancelled = state.withLock { s in
            s.groups.insert(group)
            return s.cancelled
        }
        if cancelled { kill(-group, SIGKILL) }
    }

    fileprivate func finish(_ group: pid_t) { _ = state.withLock { $0.groups.remove(group) } }
}

/// Runs `<program> -C <repo> <args>` and returns stdout. Messages are forced to English
/// (LC_ALL=C) so failures can be classified from stderr.
public func run(_ program: String, repo: FilePath, _ args: [String], cancel: Cancel? = nil) throws(GitError) -> [UInt8]
{
    if cancel?.isCancelled == true { throw .cancelled }
    let (status, stdout, stderr) = try spawn(program, repo: repo, args, cancel: cancel)
    if status == 0 { return stdout }
    let err = String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    let path = repo.string
    if err.contains("Permission denied") { throw .permissionDenied(path: path, detail: err) }
    if err.contains("not a git repository") || err.contains("cannot change to") { throw .notARepo(path: path) }
    // /usr/bin/git is a shim that fails this way until the Command Line Tools are installed.
    if err.contains("xcode-select") { throw .gitMissing }
    throw .git(detail: err)
}

/// posix_spawn rather than Process: the child gets its own process group, so cancelling can kill
/// the whole tree, and only stdin/stdout/stderr are inherited. `repo` nil: no `-C` (gh). A missing
/// program is `.gitMissing`; callers running something else say so.
///
/// `stdin` nil reads /dev/null. `cwd` must exist. `onStdout` gets stdout as it comes, on the
/// calling thread, and the returned stdout is then empty.
func spawn(
    _ program: String, repo: FilePath?, _ args: [String], cancel: Cancel?, stdin: [UInt8]? = nil,
    cwd: FilePath? = nil, onStdout: ((ArraySlice<UInt8>) -> Void)? = nil
) throws(GitError) -> (Int32, [UInt8], [UInt8]) {
    var out: [Int32] = [-1, -1]
    var err: [Int32] = [-1, -1]
    var inp: [Int32] = [-1, -1]
    guard pipe(&out) == 0 else { throw .git(detail: "pipe: \(String(cString: strerror(errno)))") }
    guard pipe(&err) == 0, stdin == nil || pipe(&inp) == 0 else {
        for fd in out + err + inp where fd >= 0 { close(fd) }
        throw .git(detail: "pipe: \(String(cString: strerror(errno)))")
    }
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    if stdin == nil {
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    } else {
        posix_spawn_file_actions_adddup2(&actions, inp[0], 0)
    }
    posix_spawn_file_actions_adddup2(&actions, out[1], 1)
    posix_spawn_file_actions_adddup2(&actions, err[1], 2)
    if let cwd { _ = cwd.withPlatformString { posix_spawn_file_actions_addchdir_np(&actions, $0) } }
    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    defer { posix_spawnattr_destroy(&attr) }
    posix_spawnattr_setflags(
        &attr,
        Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
    posix_spawnattr_setpgroup(&attr, 0)
    // Signals as a shell would give them. The calling thread's mask (SIGTERM blocked) carried
    // into git, and a failed fetch waited forever for the upload-pack it had told to stop (tested).
    // Ignored signals (SIGPIPE) would carry over the same way.
    var none = sigset_t()
    var all = sigset_t()
    sigemptyset(&none)
    sigfillset(&all)
    posix_spawnattr_setsigmask(&attr, &none)
    posix_spawnattr_setsigdefault(&attr, &all)

    // argv: program -C <repo bytes> args…; env: ours, with the settings that keep git's output parseable.
    var argv: [UnsafeMutablePointer<CChar>?] = [strdup(program)]
    if let repo { argv += [strdup("-C"), repo.withPlatformString { strdup($0) }] }
    argv += args.map { strdup($0) } + [nil]
    var env = ProcessInfo.processInfo.environment
    env["LC_ALL"] = "C"
    env["GIT_TERMINAL_PROMPT"] = "0"
    // Paths come from git itself; never let them act as pathspec magic like `:(glob)`.
    env["GIT_LITERAL_PATHSPECS"] = "1"
    // Overrides -U on the command line; the diff parser needs git's own format.
    env["GIT_DIFF_OPTS"] = nil
    // gh: plain output on the pipe, never a pager or a prompt.
    env["GH_PAGER"] = ""
    env["GH_FORCE_TTY"] = nil
    env["GH_PROMPT_DISABLED"] = "1"
    env["NO_COLOR"] = "1"
    // claude: no memory folder under ~/.claude/projects for the folder it runs in.
    env["CLAUDE_CODE_DISABLE_AUTO_MEMORY"] = "1"
    var envp: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0)=\($1)") } + [nil]
    defer { for p in argv + envp { free(p) } }

    var pid: pid_t = 0
    let rc = posix_spawnp(&pid, program, &actions, &attr, &argv, &envp)
    close(out[1])
    close(err[1])
    if inp[0] >= 0 { close(inp[0]) }
    guard rc == 0 else {
        for fd in [out[0], err[0], inp[1]] where fd >= 0 { close(fd) }
        throw rc == ENOENT ? .gitMissing : .git(detail: "\(program): \(String(cString: strerror(rc)))")
    }
    cancel?.start(pid)
    // Feed stdin and drain both pipes at once so a chatty child can't block on a full pipe.
    let inFd = inp[1]
    let fed = stdin.map { bytes in Background { () throws(GitError) in writeAll(inFd, bytes) } }
    let errFd = err[0]
    let stderrBytes = Background { () throws(GitError) in readAll(errFd) }
    let stdoutBytes = readAll(out[0], onStdout)
    var status: Int32 = 0
    while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
    // ponytail: a grandchild holding stdin or stdout keeps us here until it exits, as with git;
    // cancelling kills the group. Close the pipes after waitpid if that ever matters.
    try? fed?.wait()
    let errBytes = (try? stderrBytes.wait()) ?? []
    cancel?.finish(pid)
    if cancel?.isCancelled == true { throw .cancelled }
    let exit = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
    return (exit, stdoutBytes, errBytes)
}

private func readAll(_ fd: Int32, _ each: ((ArraySlice<UInt8>) -> Void)? = nil) -> [UInt8] {
    defer { close(fd) }
    var bytes: [UInt8] = []
    var buf = [UInt8](repeating: 0, count: 1 << 16)
    while true {
        let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        if n > 0 {
            if let each { each(buf[..<n]) } else { bytes += buf[..<n] }
        } else if n == 0 || errno != EINTR {
            return bytes
        }
    }
}

/// Writes until done or the child stops reading (EPIPE, without SIGPIPE), then closes `fd`.
private func writeAll(_ fd: Int32, _ bytes: [UInt8]) {
    defer { close(fd) }
    _ = fcntl(fd, F_SETNOSIGPIPE, 1)
    var at = 0
    while at < bytes.count {
        let n = bytes[at...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        if n > 0 {
            at += n
        } else if n < 0 && errno != EINTR {
            return
        }
    }
}

func git(_ repo: FilePath, _ args: [String], cancel: Cancel? = nil) throws(GitError) -> String {
    String(decoding: try run("git", repo: repo, args, cancel: cancel), as: UTF8.self)
}

/// Commit sha for a revision. The only place user-typed revisions reach git.
public func resolve(_ repo: FilePath, _ rev: String, cancel: Cancel? = nil) throws(GitError) -> String {
    do {
        return try git(repo, ["rev-parse", "--verify", "--end-of-options", "\(rev)^{commit}"], cancel: cancel)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    } catch .git(let detail) {
        throw .badRange(spec: rev, detail: detail)
    }
}

/// A blocking call on a thread of its own (not the cooperative pool, which blocking would starve).
final class Background<T: Sendable>: @unchecked Sendable {
    private var result: Result<T, GitError> = .failure(.cancelled)
    private let done = DispatchSemaphore(value: 0)

    init(_ work: @escaping @Sendable () throws(GitError) -> T) {
        Thread.detachNewThread { [self] in
            result = Result(catching: work)
            done.signal()
        }
    }

    func wait() throws(GitError) -> T {
        done.wait()
        return try result.get()
    }
}

/// Branches for the ⌘K picker (M4-6), newest commit first, and the base to compare them with.
public func branches(_ repo: FilePath, cancel: Cancel? = nil) throws(GitError) -> (names: [String], base: String?) {
    let refs = ["for-each-ref", "--sort=-committerdate", "--format=%(refname)", "refs/heads", "refs/remotes"]
    let out = try git(repo, refs, cancel: cancel)
    return parseBranches(
        out, originHead: try? git(repo, ["symbolic-ref", "-q", "refs/remotes/origin/HEAD"], cancel: cancel))
}

/// Full ref names in, short names out, a remote's HEAD left out (`refname:short` would print
/// it as the bare remote name). The base is what origin/HEAD points at, else main or master.
// ponytail: a short name can be ambiguous (a tag, or a local branch named origin/x); git then
// warns and picks one. Pass full ref names if that ever bites.
func parseBranches(_ out: String, originHead: String?) -> (names: [String], base: String?) {
    let names = out.split(separator: "\n").compactMap { ref -> String? in
        if ref.hasPrefix("refs/remotes/") && ref.hasSuffix("/HEAD") { return nil }
        return ["refs/heads/", "refs/remotes/"].first(where: ref.hasPrefix).map { String(ref.dropFirst($0.count)) }
    }
    let head = originHead?.trimmingCharacters(in: .whitespacesAndNewlines)
    let origin = head.flatMap { $0.hasPrefix("refs/remotes/") ? String($0.dropFirst(13)) : nil }
    let base =
        origin.flatMap { names.contains($0) ? $0 : nil }
        ?? ["main", "master", "origin/main", "origin/master"].first(where: names.contains)
    return (names, base)
}
