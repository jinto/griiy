// What the window shows (F-IN-3): any input normalized to `base` (a sha) and `head` (a sha or the
// working tree). Every diff is computed from the resolved shas, so user-typed revisions never reach
// git outside `resolve`.
import Foundation
import System

public enum Head: Equatable, Sendable {
    case sha(String)
    case workTree
}

public struct Review: Sendable {
    public var repo: FilePath
    /// Kept for the store key (M1-13), which wants the ref names, not the shas.
    public var spec: Spec
    public var base: String
    public var head: Head
    /// The parsed diff. A file's index here is its ID.
    public var files: [File]
    /// `git ls-files` output, one path per line, for the tree.
    public var tracked: String
    public var gitMs: Int

    /// Blocking: run it off the main thread. `cancel` stops the git running now and any after it.
    public static func open(_ dir: FilePath, _ spec: Spec, cancel: Cancel? = nil) throws(GitError) -> Review {
        let start = Date()
        var top = try run("git", repo: dir, ["rev-parse", "--show-toplevel"], cancel: cancel)
        while top.last == UInt8(ascii: "\n") { top.removeLast() }
        // Bytes, not a String: the repo path may not be UTF-8.
        let repo = FilePath(platformString: top.map { CChar(bitPattern: $0) } + [0])
        func sha(_ rev: String) throws(GitError) -> String {
            do {
                return try resolve(repo, rev, cancel: cancel)
            } catch .badRange(let spec, let detail) {
                // Only on failure: an unborn HEAD in a repo with commits (orphan branch) is still a typo.
                if (try? git(repo, ["rev-list", "-n1", "--all"], cancel: cancel))?.isEmpty == true {
                    throw .noCommits(path: repo.string)
                }
                throw .badRange(spec: spec, detail: detail)
            }
        }
        let base: String
        let head: Head
        switch spec {
        case .workTree(let b):
            (base, head) = (try sha(b), .workTree)
        case .range(let b, let h, let mergeBase):
            let (a, z) = (try sha(b), try sha(h))
            if mergeBase {
                // git prints one base when there are several: the one `git diff a...b` uses. With
                // both sides resolved, failing means no common ancestor (exit 1, empty stderr).
                do {
                    base = try git(repo, ["merge-base", a, z], cancel: cancel).trimmingCharacters(
                        in: .whitespacesAndNewlines)
                } catch .git {
                    throw .badRange(spec: spec.label, detail: "no common ancestor")
                }
            } else {
                base = a
            }
            head = .sha(z)
        }
        // ls-files (for the tree) runs alongside the diff instead of after it.
        let tracked = Background { () throws(GitError) in try git(repo, ["ls-files"], cancel: cancel) }
        let files = parseDiff(try run("git", repo: repo, diffArgs(base, head), cancel: cancel))
        let ls = try tracked.wait()
        return Review(
            repo: repo, spec: spec, base: base, head: head, files: files, tracked: ls,
            gitMs: Int(Date().timeIntervalSince(start) * 1000))
    }
}

/// `git diff <base> [<head>]`, from resolved shas only, in the one format `parse` reads: every
/// option that user config could change is pinned.
func diffArgs(_ base: String, _ head: Head) -> [String] {
    var args = [
        "diff", "--no-color", "--no-ext-diff", "--no-textconv", "--src-prefix=a/", "--dst-prefix=b/", "--no-relative",
        "--full-index", "-U3", "--submodule=short", "--ignore-submodules=none",
        // Renames, and copies from files changed in the same diff (--find-copies-harder scans the tree).
        "-C", base,
    ]
    if case .sha(let h) = head { args.append(h) }
    return args
}
