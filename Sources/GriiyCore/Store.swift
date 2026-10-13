// Per-review JSON documents (PRD §7.4): `<root>/<key>.json` with a schema `version`.
// Keys are byte-for-byte the Rust version's, so review files carry over.
import Foundation
import Synchronization
import System

public let storeVersion = 1

public enum Source: Sendable {
    case gitHub(owner: String, repo: String, number: Int)
    /// Ref names, not shas, so the key survives new commits. `repo` is the worktree top level.
    case range(repo: FilePath, base: String, head: String)
    case workTree(repo: FilePath)
}

public func reviewKey(_ s: Source) -> String {
    let key =
        switch s {
        // GitHub names are case-insensitive, and so is the macOS file system.
        case .gitHub(let owner, let repo, let number):
            "gh-\(enc(owner.lowercased()))-\(enc(repo.lowercased()))-\(number)"
        case .range(let repo, let base, let head): "local-\(repoHash(repo))-\(enc(base))-\(enc(head))"
        case .workTree(let repo): "local-\(repoHash(repo))-worktree"
        }
    // File names max out at 255 bytes; long ref names keep a readable prefix plus a hash of the rest.
    // The key is ASCII (enc), so bytes and characters line up.
    let bytes = Array(key.utf8)
    if bytes.count <= 200 { return key }
    return String(decoding: bytes[..<180], as: UTF8.self) + "-" + hex(fnv(bytes))
}

/// Bytes outside `[A-Za-z0-9._]` become `%XX`, so `-` stays an unambiguous field separator
/// and `/` in ref names can't escape the directory.
private func enc(_ s: String) -> String {
    var out = ""
    for b in s.utf8 {
        switch b {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
            UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "."), UInt8(ascii: "_"):
            out.append(Character(Unicode.Scalar(b)))
        default:
            out += "%" + String(b, radix: 16, uppercase: true).leftPadded(2)
        }
    }
    return out
}

// 64-bit FNV-1a; collisions need ~4 billion repos. Stable forever, unlike Hasher.
private func fnv(_ bytes: [UInt8]) -> UInt64 {
    bytes.reduce(0xcbf2_9ce4_8422_2325) { ($0 ^ UInt64($1)) &* 0x100_0000_01b3 }
}

private func hex(_ n: UInt64) -> String { String(n, radix: 16).leftPadded(16) }

/// Resolves symlinks and relative paths first, so one repo always hashes the same.
private func repoHash(_ repo: FilePath) -> String {
    let bytes = (canonical(repo) ?? repo).withPlatformString {
        Array(UnsafeBufferPointer(start: $0, count: strlen($0))).map { UInt8(bitPattern: $0) }
    }
    return hex(fnv(bytes))
}

/// realpath(3), like Rust's canonicalize: URL.resolvingSymlinksInPath would drop /private. nil if
/// the path doesn't exist.
func canonical(_ p: FilePath) -> FilePath? {
    p.withPlatformString { c in
        guard let r = realpath(c, nil) else { return nil }
        defer { free(r) }
        return FilePath(platformString: r)
    }
}

extension String {
    fileprivate func leftPadded(_ n: Int) -> String { String(repeating: "0", count: max(0, n - count)) + self }
}

public struct StoreError: Error, Sendable {
    public let message: String
}

public struct Store: Sendable {
    let root: FilePath

    public init(root: FilePath) { self.root = root }

    private func path(_ key: String) -> FilePath { root.appending("\(key).json") }

    /// A missing file is a fresh document. A corrupt or unknown-version file is moved aside to
    /// `<key>.json.corrupt-<id>` (never deleted) and a fresh document is returned.
    public func load(_ key: String) throws(StoreError) -> [String: Any] {
        let data: Data
        do {
            data = try Data(contentsOf: URL(filePath: path(key).string))
        } catch let e as CocoaError where e.code == .fileReadNoSuchFile {
            return fresh()
        } catch {
            throw StoreError(message: "\(error)")
        }
        if let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any], validVersion(doc["version"]) {
            return doc
        }
        guard rename(path(key).string, root.appending("\(key).json.corrupt-\(unique())").string) == 0 else {
            throw StoreError(message: "backing up \(key).json: \(String(cString: strerror(errno)))")
        }
        return fresh()
    }

    /// Write to a temp file, fsync, then rename over the old file, so a crash leaves either
    /// version whole. (Data.write(.atomic) renames but never fsyncs.)
    // ponytail: no cross-process lock; two windows on one review is last-write-wins.
    public func save(_ key: String, _ doc: [String: Any]) throws(StoreError) {
        let fail = { (what: String) in StoreError(message: "\(what): \(String(cString: strerror(errno)))") }
        do {
            try FileManager.default.createDirectory(atPath: root.string, withIntermediateDirectories: true)
        } catch {
            throw StoreError(message: "\(error)")
        }
        // Stamp the version so a document saved without one isn't treated as corrupt on load.
        var doc = doc
        if doc["version"] == nil { doc["version"] = storeVersion }
        let bytes: Data
        do {
            bytes = try JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys])
        } catch {
            throw StoreError(message: "\(error)")
        }
        let tmp = root.appending("\(key).json.tmp-\(unique())").string
        let fd = open(tmp, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw fail("creating \(tmp)") }
        let ok = bytes.withUnsafeBytes { buf in
            var off = 0
            while off < buf.count {
                let n = Darwin.write(fd, buf.baseAddress?.advanced(by: off), buf.count - off)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { return false }
                off += n
            }
            return true
        }
        // errno is read before close() can overwrite it.
        let synced = ok && fsync(fd) == 0
        let failure = synced ? nil : fail("writing \(tmp)")
        close(fd)
        if let failure {
            unlink(tmp)
            throw failure
        }
        guard rename(tmp, path(key).string) == 0 else {
            let e = fail("renaming over \(key).json")
            unlink(tmp)
            throw e
        }
        // The data is already in place; a failed directory fsync only weakens crash durability.
        let dir = open(root.string, O_RDONLY)
        if dir >= 0 {
            fsync(dir)
            close(dir)
        }
    }
}

private func fresh() -> [String: Any] { ["version": storeVersion] }

/// An integer 1...storeVersion: not a bool, a string or a float.
private func validVersion(_ v: Any?) -> Bool {
    guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), !CFNumberIsFloatType(n) else { return false }
    return (1...storeVersion).contains(n.intValue)
}

private let counter = Atomic<Int>(0)

/// Unique within and across processes: time, pid, and a counter.
private func unique() -> String {
    let t = UInt64(Date().timeIntervalSince1970 * 1e9)
    return "\(t)-\(getpid())-\(counter.add(1, ordering: .relaxed).oldValue)"
}
