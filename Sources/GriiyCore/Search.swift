// Search (F-DV-7): ⌘P file names and `/` diff text. The diff is parsed whole up front, so text
// search covers files with no row views yet. Both scan bytes and fold ASCII case only.

/// Indices of the `paths` holding `query` as a subsequence, best first, at most `limit`. Word
/// starts, runs and a match inside the file name score higher; ties go to the shorter path, then
/// the given order. An empty query keeps the given order.
public func fuzzy(_ query: String, in paths: [String], limit: Int = 50) -> [Int] {
    let q = query.utf8.map(lower)
    let limit = max(limit, 0)
    if q.isEmpty { return Array(paths.indices.prefix(limit)) }
    var found: [(score: Int, length: Int, i: Int)] = []
    for (i, var p) in paths.enumerated() {
        if let s = p.withUTF8({ score(q, $0) }) { found.append((s, p.utf8.count, i)) }
    }
    found.sort { ($1.score, $0.length, $0.i) < ($0.score, $1.length, $1.i) }
    return found.prefix(limit).map(\.i)
}

private func lower(_ b: UInt8) -> UInt8 { b >= 65 && b <= 90 ? b + 32 : b }

private func score(_ q: [UInt8], _ p: UnsafeBufferPointer<UInt8>) -> Int? {
    let name = (p.lastIndex(of: UInt8(ascii: "/")) ?? -1) + 1
    guard let at = align(q, p, from: name) ?? align(q, p, from: 0) else { return nil }
    var s = at[0] >= name ? 10 : 0
    for (k, j) in at.enumerated() {
        s += 1
        let before = j == 0 ? UInt8(ascii: "/") : p[j - 1]
        if "/_-. ".utf8.contains(before) || (before >= 97 && before <= 122 && p[j] >= 65 && p[j] <= 90) { s += 8 }
        if k > 0 && at[k - 1] == j - 1 { s += 8 }
    }
    return s
}

/// Where each query byte matches: the first match at or after `from`, tightened backward from its
/// end (fzf v1).
// ponytail: can miss a better-scoring alignment further right; fzf v2's DP if rankings disappoint.
private func align(_ q: [UInt8], _ p: UnsafeBufferPointer<UInt8>, from: Int) -> [Int]? {
    var j = from
    for c in q {
        while j < p.count && lower(p[j]) != c { j += 1 }
        if j == p.count { return nil }
        j += 1
    }
    var at = q.map { _ in 0 }
    for k in q.indices.reversed() {
        j -= 1
        while lower(p[j]) != q[k] { j -= 1 }
        at[k] = j
    }
    return at
}

/// A line holding the query: `row` indexes `files[file].rows(from:n:)`.
public struct Hit: Equatable, Sendable {
    public var file: Int
    public var row: Int
}

/// Every line holding `query`, in diff order. Smart case: a query without capitals ignores case.
/// Only line text is searched; file names are ⌘P's.
public func search(_ files: [File], for query: String) -> [Hit] {
    let fold = !query.utf8.contains { $0 >= 65 && $0 <= 90 }
    let q = Array(query.utf8)
    guard !q.isEmpty else { return [] }
    var hits: [Hit] = []
    for (i, f) in files.enumerated() {
        var row = 0
        for h in f.hunks {
            row += 1
            for var l in h.lines {
                row += 1
                if l.text.withUTF8({ holds($0, q, fold) }) { hits.append(Hit(file: i, row: row)) }
            }
        }
    }
    return hits
}

private func holds(_ t: UnsafeBufferPointer<UInt8>, _ q: [UInt8], _ fold: Bool) -> Bool {
    guard t.count >= q.count else { return false }
    outer: for s in t.startIndex...(t.endIndex - q.count) {
        for k in q.indices where (fold ? lower(t[s + k]) : t[s + k]) != q[k] { continue outer }
        return true
    }
    return false
}
