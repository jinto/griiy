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
    /// Every file in head, NUL-separated, for the tree: the commit's tree, or the index for the work tree.
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
        var spec = spec
        let base: String
        let head: Head
        switch spec {
        case .workTree(let b):
            (base, head) = (try sha(b), .workTree)
        case .range(let b, let h, let mergeBase):
            let (a, z) = (try sha(b), try sha(h))
            base = mergeBase ? try GriiyCore.mergeBase(repo, a, z, label: spec.label, cancel: cancel) : a
            head = .sha(z)
        case .pullRequest(let want, let number):
            let (remote, pr) = try prRemote(git(repo, ["remote", "-v"], cancel: cancel), want, number: number)
            (spec, base, head) = try pullRequest(
                repo, remote: remote, pr, number, base: pullBase(pr, number, cancel: cancel), cancel: cancel)
        }
        // The tree's listing runs alongside the diff instead of after it. -z: names unquoted.
        let list =
            if case .sha(let h) = head { ["ls-tree", "-r", "-z", "--name-only", h] } else { ["ls-files", "-z"] }
        let tracked = Background { () throws(GitError) in try git(repo, list, cancel: cancel) }
        let files = parseDiff(try run("git", repo: repo, diffArgs(base, head), cancel: cancel))
        let ls = try tracked.wait()
        return Review(
            repo: repo, spec: spec, base: base, head: head, files: files, tracked: ls,
            gitMs: Int(Date().timeIntervalSince(start) * 1000))
    }

    /// PR `number` fetched, as a resolved spec and a three-dot diff like GitHub's "Files changed".
    /// The spec names the repo even for `#n`, so the key and label are the PR URL's.
    static func pullRequest(
        _ repo: FilePath, remote: String, _ pr: GitHubRepo, _ number: Int, base: String, cancel: Cancel?
    ) throws(GitError) -> (Spec, String, Head) {
        let spec = Spec.pullRequest(repo: pr, number: number)
        let shas = try fetchPullRequest(repo, remote: remote, pr, number, base: base, cancel: cancel)
        return (spec, try mergeBase(repo, shas.base, shas.head, label: spec.label, cancel: cancel), .sha(shas.head))
    }

    /// The whole head version of `path` with its changes marked (F-DV-5). Blocking. Added, deleted
    /// and binary files come straight from the diff, which already holds all there is to show.
    public func whole(_ path: String, cancel: Cancel? = nil) throws(GitError) -> File {
        let f = files.first { $0.path == path }
        if let f, f.binary || f.status == .added || f.status == .deleted { return f }
        let bytes: [UInt8]
        switch head {
        case .sha(let h):
            bytes = try run("git", repo: repo, ["cat-file", "blob", "\(h):\(path)"], cancel: cancel)
        case .workTree:
            // Through a directory swapped for a symlink, the file could be anywhere: it must still be in the repo.
            guard let dir = canonical(repo.appending(path).removingLastComponent()), let root = canonical(repo),
                dir.starts(with: root)
            else { throw .git(detail: "\(path) is outside the repository") }
            let full = repo.appending(path).string
            // A symlink shows its target, as git stores it, and is never followed.
            if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: full) {
                bytes = Array(target.utf8)
            } else if let data = FileManager.default.contents(atPath: full) {
                bytes = Array(data)
            } else {
                throw .git(detail: "can't read \(path)")
            }
        }
        return GriiyCore.whole(f, path: path, text: bytes)
    }
}

/// merge-base(a, z), the one `git diff a...z` uses when there are several. With both sides
/// resolved, failing means no common ancestor (exit 1, empty stderr), or history cut off by a
/// shallow clone.
func mergeBase(_ repo: FilePath, _ a: String, _ z: String, label: String, cancel: Cancel? = nil) throws(GitError)
    -> String
{
    do {
        return try git(repo, ["merge-base", a, z], cancel: cancel).trimmingCharacters(in: .whitespacesAndNewlines)
    } catch .git {
        if (try? git(repo, ["rev-parse", "--is-shallow-repository"], cancel: cancel))?.hasPrefix("true") == true {
            throw .badRange(
                spec: label, detail: "no common ancestor in this shallow clone. Fetch the rest: git fetch --unshallow")
        }
        throw .badRange(spec: label, detail: "no common ancestor")
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

// ---- Seen marks (F-DV-9): `"seen": {path: version}` in the review's store document ----

extension File {
    /// The change a seen mark is for: blobs and modes on both sides, so a new head (or base) that
    /// leaves this file alone keeps the mark. Status and old path tell apart the blobless changes
    /// (pure renames, mode-only) that would otherwise all read the same.
    public var version: String {
        "\(status.rawValue) \(oldPath ?? "") \(oldBlob ?? "")..\(newBlob ?? "") \(oldMode ?? "")..\(newMode ?? "")"
    }
}

extension Review {
    /// The store key: ref names, not shas (PRD §7.4). `a..b` and `a...b` share it, and the work
    /// tree's key ignores its base; marks hold only for the same `version`, so that's harmless.
    public var key: String {
        switch spec {
        case .workTree: reviewKey(.workTree(repo: repo))
        case .range(let base, let head, _): reviewKey(.range(repo: repo, base: base, head: head))
        // open resolves `#n` to its repo, so `repo` is never nil here.
        case .pullRequest(let r, let n): reviewKey(.gitHub(owner: r?.owner ?? "", repo: r?.name ?? "", number: n))
        }
    }

    /// Indices of the files whose stored mark is for the change shown now.
    public func seen(in doc: [String: Any]) -> Set<Int> {
        let marks = doc["seen"] as? [String: String] ?? [:]
        return Set(files.indices.filter { marks[files[$0].path] == files[$0].version })
    }

    /// `doc` with file `f`'s mark set or removed. Other paths keep theirs: a stale mark is
    /// harmless, and reviews sharing the key don't erase each other's.
    // ponytail: marks are per display path, so a type change (two files, one path) or two
    // non-UTF-8 names that decode alike share one mark. Key by path bytes if that ever matters.
    public func marking(_ f: Int, _ on: Bool, in doc: [String: Any]) -> [String: Any] {
        var doc = doc
        var marks = doc["seen"] as? [String: String] ?? [:]
        marks[files[f].path] = on ? files[f].version : nil
        doc["seen"] = marks
        return doc
    }
}
