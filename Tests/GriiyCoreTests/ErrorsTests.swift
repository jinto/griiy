// F-IN-5: each failure becomes a GitError with a title and a fix, never a crash.
import Foundation
import System
import Testing

@testable import GriiyCore

private func explained(_ e: GitError) -> Bool { !e.title.isEmpty && !e.hint.isEmpty }

@Test func gitMissing() {
    let t = TempDir("nogit")
    #expect(throws: GitError.gitMissing) { try run("griiy-no-such-git", repo: FilePath(t.path), ["status"]) }
    #expect(explained(.gitMissing))
}

@Test func notARepository() {
    let t = TempDir("norepo")
    for dir in [t.path, t.path + "/does-not-exist"] {
        do {
            _ = try Review.open(FilePath(dir), .default)
            Issue.record("opened \(dir)")
        } catch {
            guard case .notARepo = error else { return #expect(Bool(false), "\(error)") }
            #expect(explained(error))
        }
    }
}

@Test func badRange() throws {
    let r = repo("range", [("a.txt", "a\n")])
    #expect(try resolve(FilePath(r.path), "main").count == 40)
    for spec in ["no-such-branch", "main~5", "--output=/tmp/x"] {
        do {
            _ = try resolve(FilePath(r.path), spec)
            Issue.record("resolved \(spec)")
        } catch {
            guard case .badRange(let s, _) = error, s == spec else { return #expect(Bool(false), "\(error)") }
            #expect(explained(error))
        }
    }
}

@Test func permissionDenied() throws {
    let t = TempDir("perm")
    let locked = t.path + "/locked"
    try FileManager.default.createDirectory(atPath: locked, withIntermediateDirectories: false)
    chmod(locked, 0)
    defer { chmod(locked, 0o755) }  // so TempDir can clean up
    if getuid() == 0 { return }  // root reads anything
    do {
        _ = try Review.open(FilePath(locked), .default)
        Issue.record("opened")
    } catch {
        guard case .permissionDenied = error else { return #expect(Bool(false), "\(error)") }
        #expect(explained(error))
    }
}

@Test func noCommitsYet() {
    let t = TempDir("empty")
    git(t.path, ["init", "-q"])
    do {
        _ = try Review.open(FilePath(t.path), .default)
        Issue.record("opened")
    } catch {
        guard case .noCommits = error else { return #expect(Bool(false), "\(error)") }
        #expect(explained(error))
    }
}

@Test func everyErrorExplainsItself() {
    for e: GitError in [
        .gitMissing, .notARepo(path: ""), .noCommits(path: ""), .badRange(spec: "", detail: ""),
        .fetchFailed(remote: "", detail: ""), .permissionDenied(path: "", detail: ""), .git(detail: ""), .cancelled,
        .noRemote(want: nil, number: 1, detail: ""), .ghMissing,
        .noRemote(want: GitHubRepo(owner: "o", name: "r"), number: 1, detail: ""),
    ] {
        #expect(explained(e), "\(e)")
    }
}

/// A fake git whose child outlives it and holds the pipes.
private func slowGit(_ dir: String) -> String {
    let fake = dir + "/slow-git"
    write(dir, "slow-git", "#!/bin/sh\nsleep 30 &\nwait\n")
    chmod(fake, 0o755)
    return fake
}

@Test func cancelKillsRunningGitAndItsChildren() {
    let dir = TempDir("cancel")
    let (fake, path) = (slowGit(dir.path), dir.path)
    let tokens = [Cancel(), Cancel()]
    let start = Date()
    // Blocking calls, as Review.open makes them: each on a thread of its own.
    let workers = tokens.map { token in
        Background { () throws(GitError) in try run(fake, repo: FilePath(path), [], cancel: token) }
    }
    Thread.sleep(forTimeInterval: 0.2)
    for token in tokens { token.cancel() }
    for w in workers { #expect(throws: GitError.cancelled) { try w.wait() } }
    #expect(Date().timeIntervalSince(start) < 2, "grandchildren held the pipes")
}

@Test func oneTokenCancelsEveryGitItStarted() {
    // Review.open runs ls-files and diff at once on one token: a git that finished early must not
    // make the token forget the one still running.
    let dir = TempDir("cancelpair")
    let (slow, path) = (slowGit(dir.path), dir.path)
    let token = Cancel()
    let start = Date()
    let running = Background { () throws(GitError) in try run(slow, repo: FilePath(path), [], cancel: token) }
    Thread.sleep(forTimeInterval: 0.1)
    #expect(throws: Never.self) { try run("/usr/bin/true", repo: FilePath(path), [], cancel: token) }
    token.cancel()
    #expect(throws: GitError.cancelled) { try running.wait() }
    #expect(Date().timeIntervalSince(start) < 2, "the slow git survived the cancel")
}

@Test func cancelledBeforeStartNeverSpawns() {
    let token = Cancel()
    token.cancel()
    #expect(throws: GitError.cancelled) { try run("/bin/sleep", repo: FilePath("/"), ["30"], cancel: token) }
}
