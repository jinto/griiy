// Command line: `griiy [<range>] [-C <repo>]` (F-IN-1), ranges meaning what they mean to git (F-IN-2).
import System

let usage = "usage: griiy [<rev> | <a>..<b> | <a>...<b>] [-C <repo>]"

public enum Spec: Equatable, Sendable {
    /// `griiy` or `griiy <rev>`: `base` (default HEAD) vs the working tree, index included.
    case workTree(base: String)
    /// `a..b` compares the endpoints; `a...b` (`mergeBase`) compares b with merge-base(a, b).
    /// An empty side is HEAD.
    case range(base: String, head: String, mergeBase: Bool)

    public static let `default` = Spec.workTree(base: "HEAD")

    /// What the user asked for, for the window header and error messages.
    public var label: String {
        switch self {
        case .workTree(let base): "\(base) vs working tree"
        case .range(let base, let head, let mergeBase): base + (mergeBase ? "..." : "..") + head
        }
    }
}

public struct Args: Sendable {
    public var repo: FilePath
    public var spec: Spec
}

public struct UsageError: Error, Sendable {
    public let message: String
}

/// Parses the arguments after the program name, as raw bytes. The repository path stays bytes;
/// a revision must be UTF-8 (git ref names in practice are).
public func parseArgs(_ args: [[UInt8]]) -> Result<Args, UsageError> {
    let unexpected = { (arg: [UInt8]) in
        UsageError(message: "griiy: unexpected argument '\(String(decoding: arg, as: UTF8.self))'\n\(usage)")
    }
    var repo: FilePath?
    var rev: String?
    var it = args.makeIterator()
    while let arg = it.next() {
        if arg == Array("-C".utf8) && repo == nil {
            guard let path = it.next() else { return .failure(UsageError(message: "griiy: -C needs a path\n\(usage)")) }
            repo = FilePath(platformString: path.map { CChar(bitPattern: $0) } + [0])
        } else if rev != nil {
            return .failure(unexpected(arg))
        } else {
            // Checked before range splitting, so `--output=x..HEAD` never reaches git.
            guard let r = String(validating: arg, as: UTF8.self), !r.hasPrefix("-") else {
                return .failure(unexpected(arg))
            }
            rev = r
        }
    }
    let side = { (s: Substring) in s.isEmpty ? "HEAD" : String(s) }
    let spec: Spec =
        switch rev {
        case nil: .default
        case let r?:
            if let dots = r.range(of: "...") {
                .range(base: side(r[..<dots.lowerBound]), head: side(r[dots.upperBound...]), mergeBase: true)
            } else if let dots = r.range(of: "..") {
                .range(base: side(r[..<dots.lowerBound]), head: side(r[dots.upperBound...]), mergeBase: false)
            } else {
                .workTree(base: r)
            }
        }
    return .success(Args(repo: repo ?? FilePath("."), spec: spec))
}
