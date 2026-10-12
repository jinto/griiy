// git CLI wrapper and the errors shown on the in-window error screen (F-IN-5).
import Foundation
import Synchronization
import System

public enum GitError: Error, Equatable, Sendable {
    case gitMissing
    case notARepo(path: String)
    case noCommits(path: String)
    case badRange(spec: String, detail: String)
    case fetchFailed(remote: String, detail: String)
    case permissionDenied(path: String, detail: String)
    case git(detail: String)
    case cancelled

    public var title: String {
        switch self {
        case .gitMissing: "git is not installed"
        case .notARepo(let path): "\(path) is not a git repository"
        case .noCommits(let path): "\(path) has no commits yet"
        case .badRange(let spec, _): "Unknown revision or range: \(spec)"
        case .fetchFailed(let remote, _): "Could not fetch from \(remote)"
        case .permissionDenied(let path, _): "Permission denied: \(path)"
        case .git: "git failed"
        case .cancelled: "Cancelled"
        }
    }

    public var hint: String {
        switch self {
        case .gitMissing:
            "Install git (xcode-select --install or brew install git) and make sure it is on PATH."
        case .notARepo: "Run griiy inside a git repository, or pass its path: griiy -C path/to/repo."
        case .noCommits: "Make a first commit, then run griiy again."
        case .badRange:
            "Check the branch or commit names. Ranges look like main..feature or main...feature. To open another repository: griiy -C path/to/repo."
        case .fetchFailed: "Check your network and that the remote exists, then run griiy again."
        case .permissionDenied:
            "Check file permissions, or for a private repository, that you are logged in (gh auth status)."
        case .git: "git reported the error above. Fix it and run griiy again."
        case .cancelled: "The request was cancelled."
        }
    }

    public var detail: String {
        switch self {
        case .badRange(_, let d), .fetchFailed(_, let d), .permissionDenied(_, let d), .git(let d): d
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
    }
    private let state = Mutex(State())

    public init() {}

    public var isCancelled: Bool { state.withLock { $0.cancelled } }

    public func cancel() {
        let groups = state.withLock { s in
            s.cancelled = true
            return s.groups
        }
        for group in groups { kill(-group, SIGKILL) }
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
/// the whole tree, and only stdin/stdout/stderr are inherited.
private func spawn(_ program: String, repo: FilePath, _ args: [String], cancel: Cancel?) throws(GitError) -> (
    Int32, [UInt8], [UInt8]
) {
    var out: [Int32] = [0, 0]
    var err: [Int32] = [0, 0]
    guard pipe(&out) == 0 else { throw .git(detail: "pipe: \(String(cString: strerror(errno)))") }
    guard pipe(&err) == 0 else {
        close(out[0])
        close(out[1])
        throw .git(detail: "pipe: \(String(cString: strerror(errno)))")
    }
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_adddup2(&actions, out[1], 1)
    posix_spawn_file_actions_adddup2(&actions, err[1], 2)
    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    defer { posix_spawnattr_destroy(&attr) }
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
    posix_spawnattr_setpgroup(&attr, 0)

    // argv: program -C <repo bytes> args…; env: ours, with the settings that keep git's output parseable.
    var argv: [UnsafeMutablePointer<CChar>?] = [strdup(program), strdup("-C"), repo.withPlatformString { strdup($0) }]
    argv += args.map { strdup($0) } + [nil]
    var env = ProcessInfo.processInfo.environment
    env["LC_ALL"] = "C"
    env["GIT_TERMINAL_PROMPT"] = "0"
    // Paths come from git itself; never let them act as pathspec magic like `:(glob)`.
    env["GIT_LITERAL_PATHSPECS"] = "1"
    // Overrides -U on the command line; the diff parser needs git's own format.
    env["GIT_DIFF_OPTS"] = nil
    var envp: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0)=\($1)") } + [nil]
    defer { for p in argv + envp { free(p) } }

    var pid: pid_t = 0
    let rc = posix_spawnp(&pid, program, &actions, &attr, &argv, &envp)
    close(out[1])
    close(err[1])
    guard rc == 0 else {
        close(out[0])
        close(err[0])
        throw rc == ENOENT ? .gitMissing : .git(detail: "\(program): \(String(cString: strerror(rc)))")
    }
    cancel?.start(pid)
    // Drain both pipes at once so a chatty child can't block on a full pipe.
    let errFd = err[0]
    let stderrBytes = Background { () throws(GitError) in readAll(errFd) }
    let stdoutBytes = readAll(out[0])
    var status: Int32 = 0
    while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
    let errBytes = (try? stderrBytes.wait()) ?? []
    cancel?.finish(pid)
    if cancel?.isCancelled == true { throw .cancelled }
    let exit = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
    return (exit, stdoutBytes, errBytes)
}

private func readAll(_ fd: Int32) -> [UInt8] {
    defer { close(fd) }
    var bytes: [UInt8] = []
    var buf = [UInt8](repeating: 0, count: 1 << 16)
    while true {
        let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        if n > 0 {
            bytes += buf[..<n]
        } else if n == 0 || errno != EINTR {
            return bytes
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

/// `git fetch <remote> <refspec>` (M2-2 builds PR fetches on this).
public func fetch(_ repo: FilePath, remote: String, refspec: String) throws(GitError) {
    do {
        _ = try git(repo, ["fetch", "--no-tags", "--quiet", "--end-of-options", remote, refspec])
    } catch .git(let detail) {
        throw .fetchFailed(remote: remote, detail: detail)
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
