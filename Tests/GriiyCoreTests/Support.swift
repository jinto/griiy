// Throwaway git repositories for tests (ported from the Rust tests/common/mod.rs, commit a97e3b8).
import Foundation
import GriiyCore

/// A fresh directory under the system temp dir, removed when the value goes away.
final class TempDir {
    let url: URL
    var path: String { url.path }

    nonisolated(unsafe) private static var counter = 0
    private static let lock = NSLock()

    init(_ name: String) {
        let n = TempDir.lock.withLock {
            TempDir.counter += 1
            return TempDir.counter
        }
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("griiy-test-\(name)-\(getpid())-\(n)")
        try? FileManager.default.removeItem(at: base)
        try! FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // Canonical, like Rust's canonicalize: /var/folders → /private/var/folders.
        url = URL(fileURLWithPath: realpathString(base.path))
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}

func realpathString(_ path: String) -> String {
    guard let p = realpath(path, nil) else { return path }
    defer { free(p) }
    return String(cString: p)
}

/// git with no user/system config, so tests behave the same on any machine or CI runner.
@discardableResult
func git(_ dir: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    p.arguments =
        ["-c", "user.name=griiy", "-c", "user.email=griiy@example.com", "-c", "commit.gpgsign=false", "-C", dir]
        + args
    var env = ProcessInfo.processInfo.environment
    env["GIT_CONFIG_GLOBAL"] = "/dev/null"
    env["GIT_CONFIG_NOSYSTEM"] = "1"
    p.environment = env
    let out = Pipe()
    let err = Pipe()
    p.standardOutput = out
    p.standardError = err
    try! p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    let errData = err.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    precondition(p.terminationStatus == 0, "git \(args): \(String(decoding: errData, as: UTF8.self))")
    return String(decoding: data, as: UTF8.self)
}

/// A repo on `main` with one commit containing `files`.
func repo(_ name: String, _ files: [(String, String)]) -> TempDir {
    let t = TempDir(name)
    git(t.path, ["init", "-q", "-b", "main"])
    for (path, text) in files { write(t.path, path, text) }
    git(t.path, ["add", "-A"])
    git(t.path, ["commit", "-qm", "init"])
    return t
}

func write(_ dir: String, _ path: String, _ text: String) {
    let url = URL(fileURLWithPath: dir).appendingPathComponent(path)
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! Data(text.utf8).write(to: url)
}

/// (added, deleted) as an array: tuples don't compare inside #expect.
func st(_ f: File) -> [Int] { [f.stats.add, f.stats.del] }
