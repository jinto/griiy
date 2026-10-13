// F-AI-5: the claude CLI (tools off) and the Messages API, streamed and cancellable. The CLI is
// a fake shell script that replays real stream-json output; the API is a URLProtocol.
import Foundation
import Synchronization
import Testing

@testable import GriiyCore

// MARK: - claude CLI

private let initOK =
    #"{"type":"system","subtype":"init","tools":[],"mcp_servers":[],"model":"claude-haiku-5-5","claude_code_version":"2.1.296"}"#
private let status = #"{"type":"system","subtype":"status","status":"requesting"}"#
private func delta(_ text: String) -> String {
    #"{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"\#(text)"}}}"#
}
private let thinking =
    #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hm"}}}"#
private let resultOK =
    #"{"type":"result","subtype":"success","is_error":false,"result":"NO-TOOLS 한글","stop_reason":"end_turn"}"#
private let rateLimit = #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed"}}"#
private func failure(_ code: String, _ message: String) -> [String] {
    [
        initOK,
        #"{"type":"assistant","message":{"model":"<synthetic>","content":[{"type":"text","text":"\#(message)"}]},"error":"\#(code)"}"#,
        rateLimit,
        #"{"type":"result","subtype":"success","is_error":true,"result":"\#(message)","stop_reason":"stop_sequence"}"#,
    ]
}

/// A `claude` that answers `--version` with `version` and otherwise records its argv, cwd and
/// stdin in `dir`, then runs `body`.
private func fakeClaude(_ dir: TempDir, version: String = "2.1.296 (Claude Code)", _ body: String) -> String {
    let path = dir.path + "/claude"
    let script = """
        #!/bin/sh
        D='\(dir.path)'
        if [ "$1" = "--version" ]; then echo '\(version)'; exit 0; fi
        printf '%s\\n' "$@" > "$D/argv"; pwd -P > "$D/cwd"; cat > "$D/stdin"
        \(body)
        """
    FileManager.default.createFile(atPath: path, contents: Data(script.utf8), attributes: [.posixPermissions: 0o755])
    return path
}

/// Prints `lines` as they are; `$D/out` holds them so quoting stays out of the script.
private func replay(_ dir: TempDir, _ lines: [String], exit code: Int = 0) -> String {
    FileManager.default.createFile(
        atPath: dir.path + "/out", contents: Data((lines.joined(separator: "\n") + "\n").utf8))
    return fakeClaude(dir, "cat \"$D/out\"; exit \(code)")
}

private let request = AIRequest(model: "claude-haiku-5-5", system: "You answer.", prompt: "Read secret.txt")

private final class Chunks: Sendable {
    let all = Mutex<[String]>([])
    var text: String { all.withLock { $0.joined() } }
    func add(_ s: String) { all.withLock { $0.append(s) } }
}

private func askCollecting(_ b: AIBackend, _ r: AIRequest = request, cancel: Cancel = Cancel()) -> (
    Result<AIAnswer, AIError>, Chunks
) {
    let chunks = Chunks()
    let result = Result { () throws(AIError) in try ask(b, r, cancel: cancel, onText: chunks.add) }
    return (result, chunks)
}

@Test func cliAnswersWithItsToolsOff() throws {
    let t = TempDir("cli-ok")
    let path = replay(t, [initOK, status, thinking, delta("NO-"), rateLimit, delta("TOOLS 한글"), resultOK])
    let (result, chunks) = askCollecting(.claudeCli(path: path))
    #expect(try result.get() == AIAnswer(text: "NO-TOOLS 한글", model: "claude-haiku-5-5", truncated: false))
    #expect(chunks.all.withLock { $0 } == ["NO-", "TOOLS 한글"])

    let argv = try String(contentsOfFile: t.path + "/argv", encoding: .utf8).split(
        separator: "\n", omittingEmptySubsequences: false)
    func value(_ flag: String) -> Substring? { argv.firstIndex(of: Substring(flag)).map { argv[$0 + 1] } }
    #expect(value("--tools") == "")
    #expect(value("--setting-sources") == "")
    #expect(value("--model") == "claude-haiku-5-5")
    #expect(value("--system-prompt") == "You answer.")
    #expect(value("--output-format") == "stream-json")
    for flag in [
        "-p", "--strict-mcp-config", "--disable-slash-commands", "--no-session-persistence",
        "--include-partial-messages",
    ] {
        #expect(argv.contains(Substring(flag)), "\(flag)")
    }
    // The prompt goes in on stdin, never argv; the CLI runs away from the repository.
    #expect(!argv.contains("Read secret.txt"))
    #expect(try String(contentsOfFile: t.path + "/stdin", encoding: .utf8) == "Read secret.txt")
    let cwd = try String(contentsOfFile: t.path + "/cwd", encoding: .utf8).trimmingCharacters(in: .newlines)
    #expect(cwd.hasSuffix("/griiy-ask"))
    #expect(cwd != FileManager.default.currentDirectoryPath)
}

@Test func cliTextArrivesWhileTheAnswerIsStillComing() throws {
    // The script waits for `go`, which only the first onText writes: no streaming → it gives up.
    let t = TempDir("cli-stream")
    FileManager.default.createFile(
        atPath: t.path + "/first", contents: Data((initOK + "\n" + delta("one") + "\n").utf8))
    FileManager.default.createFile(
        atPath: t.path + "/rest", contents: Data((delta("two") + "\n" + resultOK + "\n").utf8))
    let path = fakeClaude(
        t,
        """
        cat "$D/first"
        n=0; while [ ! -f "$D/go" ]; do n=$((n+1)); [ $n -gt 100 ] && exit 3; sleep 0.05; done
        cat "$D/rest"
        """)
    let go = t.path + "/go"
    let answer = try ask(.claudeCli(path: path), request, cancel: Cancel()) { _ in
        FileManager.default.createFile(atPath: go, contents: nil)
    }
    #expect(answer.text == "NO-TOOLS 한글")
}

@Test func cliTakesALargePrompt() throws {
    let t = TempDir("cli-large")
    let path = replay(t, [initOK, resultOK])
    let big = AIRequest(model: "m", system: "s", prompt: String(repeating: "가나다라 abc\n", count: 80_000))
    #expect(try ask(.claudeCli(path: path), big, cancel: Cancel()) { _ in }.text == "NO-TOOLS 한글")
    #expect(try String(contentsOfFile: t.path + "/stdin", encoding: .utf8) == big.prompt)
}

@Test func cliWithAnyToolOnIsStoppedBeforeItAnswers() {
    let mcp =
        #"{"type":"system","subtype":"init","tools":[],"mcp_servers":[{"name":"x","status":"connected"}],"model":"m"}"#
    let tool = #"{"type":"system","subtype":"init","tools":["Read"],"mcp_servers":[],"model":"m"}"#
    let noFields = #"{"type":"system","subtype":"init","model":"m"}"#
    for lines in [
        [tool, delta("secret"), resultOK], [mcp, delta("secret"), resultOK], [noFields, resultOK],
        [delta("secret"), resultOK], [resultOK], [],
    ] {
        let t = TempDir("cli-tools")
        let (result, chunks) = askCollecting(.claudeCli(path: replay(t, lines)))
        #expect(throws: AIError.toolsNotOff) { try result.get() }
        #expect(chunks.text == "")
    }
}

@Test func aCliWithToolsOnIsKilled() throws {
    // Ignoring its output is not enough: a CLI with tools could go on using them.
    let t = TempDir("cli-kill")
    let tool = #"{"type":"system","subtype":"init","tools":["Bash"],"mcp_servers":[],"model":"m"}"#
    FileManager.default.createFile(atPath: t.path + "/first", contents: Data((tool + "\n").utf8))
    let path = fakeClaude(t, "sleep 30 & echo $! > \"$D/pid\"; cat \"$D/first\"; wait")
    let start = Date()
    #expect(throws: AIError.toolsNotOff) { try ask(.claudeCli(path: path), request, cancel: Cancel()) { _ in } }
    #expect(Date().timeIntervalSince(start) < 5)
    let pid = try #require(
        pid_t(try String(contentsOfFile: t.path + "/pid", encoding: .utf8).trimmingCharacters(in: .newlines)))
    usleep(50_000)
    #expect(kill(pid, 0) == -1)
}

@Test func cliFailuresSayWhatToDo() {
    let cases: [([String], Int, AIError)] = [
        (failure("authentication_failed", "Not logged in · Please run /login"), 1, .cliAuth),
        (failure("model_not_found", "There's an issue with the selected model"), 1, .badModel("claude-haiku-5-5")),
        (failure("rate_limit", "You've hit your limit"), 1, .failed("You've hit your limit")),
        ([initOK, delta("half")], 0, .failed("claude stopped before answering")),
    ]
    for (lines, code, want) in cases {
        let t = TempDir("cli-fail")
        let (result, _) = askCollecting(.claudeCli(path: replay(t, lines, exit: code)))
        #expect(throws: want) { try result.get() }
        #expect(!want.title.isEmpty && !want.hint.isEmpty)
    }
}

@Test func anOldOrMissingCliIsNamed() {
    let t = TempDir("cli-old")
    let old = fakeClaude(t, version: "2.1.217 (Claude Code)", "exit 9")
    #expect(throws: AIError.cliTooOld(version: "2.1.217")) {
        try ask(.claudeCli(path: old), request, cancel: Cancel()) { _ in }
    }
    // A flag the CLI doesn't know, whatever version it claims.
    let u = TempDir("cli-unknown")
    let unknown = fakeClaude(u, "echo \"error: unknown option '--tools'\" >&2; exit 1")
    #expect(throws: AIError.cliTooOld(version: "2.1.296")) {
        try ask(.claudeCli(path: unknown), request, cancel: Cancel()) { _ in }
    }
    #expect(throws: AIError.cliMissing) {
        try ask(.claudeCli(path: t.path + "/nope"), request, cancel: Cancel()) { _ in }
    }
}

@Test func cliVersions() {
    #expect(cliVersion("2.1.296 (Claude Code)") == [2, 1, 296])
    #expect(cliVersion("10.0.0\n") == [10, 0, 0])
    #expect(cliVersion("claude") == nil)
    #expect(cliVersion("") == nil)
    #expect([2, 1, 217].lexicographicallyPrecedes(minimumCli))
    #expect(!minimumCli.lexicographicallyPrecedes(minimumCli))
    #expect(!([2, 2, 0].lexicographicallyPrecedes(minimumCli)))
}

@Test func cancellingStopsTheCliAndItsChildren() throws {
    let t = TempDir("cli-cancel")
    FileManager.default.createFile(
        atPath: t.path + "/first", contents: Data((initOK + "\n" + delta("one") + "\n").utf8))
    let path = fakeClaude(t, "cat \"$D/first\"; sleep 30 & echo $! > \"$D/pid\"; wait")
    let token = Cancel()
    let chunks = Chunks()
    let done = Background { () throws(GitError) in
        Result { () throws(AIError) in try ask(.claudeCli(path: path), request, cancel: token, onText: chunks.add) }
    }
    var n = 0
    while !FileManager.default.fileExists(atPath: t.path + "/pid") || chunks.text.isEmpty {
        n += 1
        try #require(n < 1000)
        usleep(10_000)
    }
    let start = Date()
    token.cancel()
    #expect(throws: AIError.cancelled) { try done.wait().get() }
    #expect(Date().timeIntervalSince(start) < 2)
    let pid = try #require(
        pid_t(try String(contentsOfFile: t.path + "/pid", encoding: .utf8).trimmingCharacters(in: .newlines)))
    usleep(50_000)
    #expect(kill(pid, 0) == -1)
    #expect(chunks.text == "one")
}

@Test func noTextAfterCancel() {
    // Lines already in the pipe when the group dies still arrive; they are not shown.
    let t = TempDir("cli-late")
    let token = Cancel()
    let path = replay(t, [initOK, delta("one"), delta("two"), resultOK])
    let chunks = Chunks()
    let result = Result { () throws(AIError) in
        try ask(.claudeCli(path: path), request, cancel: token) {
            chunks.add($0)
            token.cancel()
        }
    }
    #expect(throws: AIError.cancelled) { try result.get() }
    #expect(chunks.text == "one")
}

// MARK: - Messages API

/// Stands in for api.anthropic.com. Each test picks its replies by the API key it sends.
final class FakeAPI: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status = 200
        var raw: [Data]
        /// Never finish: the request waits until it is cancelled.
        var hold = false
        /// End with a dropped connection instead of a clean finish.
        var drop = false

        init(status: Int = 200, raw: [Data]) {
            self.status = status
            self.raw = raw
        }

        init(status: Int = 200, chunks: [String], hold: Bool = false) {
            self.init(status: status, raw: chunks.map { Data($0.utf8) })
            self.hold = hold
        }
    }
    struct Seen: Sendable {
        var headers: [String: String]
        var body: [String: Any]? { try? JSONSerialization.jsonObject(with: raw) as? [String: Any] }
        var raw: Data
        var url: URL?
    }
    static let replies = Mutex<[String: Reply]>([:])
    static let seen = Mutex<[String: Seen]>([:])
    static let stopped = Mutex<Set<String>>([])

    private var key: String { request.value(forHTTPHeaderField: "x-api-key") ?? "" }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var raw = Data()
        if let s = request.httpBodyStream {
            s.open()
            var buf = [UInt8](repeating: 0, count: 1 << 16)
            while case let n = s.read(&buf, maxLength: buf.count), n > 0 { raw.append(buf, count: n) }
            s.close()
        }
        let key = key
        FakeAPI.seen.withLock {
            $0[key] = Seen(headers: request.allHTTPHeaderFields ?? [:], raw: request.httpBody ?? raw, url: request.url)
        }
        guard let reply = FakeAPI.replies.withLock({ $0[key] }), let url = request.url,
            let response = HTTPURLResponse(
                url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": reply.status == 200 ? "text/event-stream" : "application/json"])
        else { return client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)) ?? () }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in reply.raw { client?.urlProtocol(self, didLoad: chunk) }
        if reply.drop {
            // Later, as a real connection would: failing at once drops data not yet delivered.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { [self] in
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            }
        } else if !reply.hold {
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() { _ = FakeAPI.stopped.withLock { $0.insert(key) } }
}

private func fakeSession() -> URLSessionConfiguration {
    let c = URLSessionConfiguration.ephemeral
    c.protocolClasses = [FakeAPI.self]
    return c
}

private func sse(_ event: String, _ data: String) -> String { "event: \(event)\ndata: \(data)\n\n" }
private let start = sse("message_start", #"{"type":"message_start","message":{"id":"m1","model":"claude-opus-5-5"}}"#)
private func apiDelta(_ t: String) -> String {
    sse(
        "content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"\#(t)"}}"#
    )
}
private func stop(_ reason: String) -> String {
    sse("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"\#(reason)"},"usage":{"output_tokens":3}}"#)
        + sse("message_stop", #"{"type":"message_stop"}"#)
}

private func askAPI(_ name: String, _ reply: FakeAPI.Reply, cancel: Cancel = Cancel()) -> (
    Result<AIAnswer, AIError>, Chunks
) {
    let key = "sk-test-\(name)"
    FakeAPI.replies.withLock { $0[key] = reply }
    let chunks = Chunks()
    let result = Result { () throws(AIError) in
        try askApi(key: key, request, config: fakeSession(), cancel: cancel, onText: chunks.add)
    }
    return (result, chunks)
}

@Test func apiStreamsAnAnswer() throws {
    // A multibyte letter split between chunks, a ping and a comment between events, and
    // several events in one chunk.
    let body = Array(
        (start + apiDelta("Hel") + ": keep-alive\n\n" + sse("ping", #"{"type": "ping"}"#) + apiDelta("lo 한글")
            + stop("end_turn")).utf8)
    let cut = try #require(body.firstIndex(of: 0xED)) + 1  // inside 한
    let (result, chunks) = askAPI("stream", .init(raw: [Data(body[..<cut]), Data(body[cut...])]))
    #expect(try result.get() == AIAnswer(text: "Hello 한글", model: "claude-opus-5-5", truncated: false))
    #expect(chunks.all.withLock { $0 } == ["Hel", "lo 한글"])
}

@Test func apiSendsTheRequestItShould() throws {
    let (result, _) = askAPI("request", .init(chunks: [start, apiDelta("ok"), stop("end_turn")]))
    #expect(try result.get().text == "ok")
    let seen = try #require(FakeAPI.seen.withLock { $0["sk-test-request"] })
    #expect(seen.url?.absoluteString == "https://api.anthropic.com/v1/messages")
    #expect(seen.headers["anthropic-version"] == "2023-06-01")
    #expect(seen.headers["anthropic-beta"] == "server-side-fallback-2026-07-01")
    let body = try #require(seen.body)
    #expect(body["model"] as? String == "claude-haiku-5-5")
    #expect(body["system"] as? String == "You answer.")
    #expect(body["stream"] as? Bool == true)
    #expect(body["fallbacks"] as? String == "default")
    #expect((body["messages"] as? [[String: String]]) == [["role": "user", "content": "Read secret.txt"]])
    #expect(body["thinking"] == nil && body["temperature"] == nil)
}

@Test func apiAnswersThatEndEarlyOrAreCutAreSaidSo() throws {
    let (cut, _) = askAPI("cut", .init(chunks: [start, apiDelta("par"), stop("max_tokens")]))
    #expect(try cut.get() == AIAnswer(text: "par", model: "claude-opus-5-5", truncated: true))
    let (early, _) = askAPI("early", .init(chunks: [start, apiDelta("par")]))
    #expect(throws: AIError.failed("The answer stopped early")) { try early.get() }
    let (noStart, _) = askAPI("nostart", .init(chunks: [apiDelta("par"), stop("end_turn")]))
    #expect(throws: AIError.failed("The answer stopped early")) { try noStart.get() }
    let (refused, _) = askAPI("refused", .init(chunks: [start, stop("refusal")]))
    #expect(throws: AIError.refused) { try refused.get() }
    // Nothing after message_stop counts, not even a dropped connection.
    var after = FakeAPI.Reply(chunks: [start, apiDelta("ok"), stop("end_turn"), apiDelta("more"), stop("refusal")])
    after.drop = true
    let (whole, chunks) = askAPI("after", after)
    #expect(try whole.get() == AIAnswer(text: "ok", model: "claude-opus-5-5", truncated: false))
    #expect(chunks.text == "ok")
}

@Test func apiFallbackModelIsTheOneThatAnswered() throws {
    let fallback = sse(
        "content_block_start",
        #"{"type":"content_block_start","index":1,"content_block":{"type":"fallback","from":{"model":"claude-opus-5-5"},"to":{"model":"claude-opus-4-8"}}}"#
    )
    let (result, _) = askAPI(
        "fallback", .init(chunks: [start, apiDelta("a"), fallback, apiDelta("b"), stop("end_turn")]))
    #expect(try result.get() == AIAnswer(text: "ab", model: "claude-opus-4-8", truncated: false))
}

@Test func apiErrorsSayWhatToDo() {
    let err = { (type: String, msg: String) in #"{"type":"error","error":{"type":"\#(type)","message":"\#(msg)"}}"# }
    let long = String(repeating: "x", count: 500)
    let cases: [(String, FakeAPI.Reply, AIError)] = [
        ("401", .init(status: 401, chunks: [err("authentication_error", "invalid x-api-key")]), .apiAuth),
        (
            "404", .init(status: 404, chunks: [err("not_found_error", "model: claude-haiku-5-5")]),
            .badModel("claude-haiku-5-5")
        ),
        ("529", .init(status: 529, chunks: [err("overloaded_error", "Overloaded\\nagain")]), .failed("529 Overloaded")),
        ("html", .init(status: 502, chunks: ["<html>bad gateway</html>"]), .failed("502")),
        (
            "long", .init(status: 400, chunks: [err("invalid_request_error", long)]),
            .failed("400 " + String(long.prefix(200)))
        ),
        (
            "echo", .init(status: 400, chunks: [err("invalid_request_error", "bad key sk-test-echo")]),
            .failed("400 bad key <key>")
        ),
        (
            "midstream",
            .init(chunks: [start, apiDelta("a"), sse("error", err("overloaded_error", "Overloaded")), stop("end_turn")]
            ), .failed("Overloaded")
        ),
    ]
    for (name, reply, want) in cases {
        let (result, _) = askAPI(name, reply)
        #expect(throws: want, "\(name)") { try result.get() }
        #expect(!want.title.isEmpty && !want.hint.isEmpty)
    }
}

@Test func cancellingStopsTheRequest() throws {
    let token = Cancel()
    let key = "sk-test-cancel"
    FakeAPI.replies.withLock { $0[key] = .init(chunks: [start, apiDelta("one")], hold: true) }
    let chunks = Chunks()
    let done = Background { () throws(GitError) in
        Result { () throws(AIError) in
            try askApi(key: key, request, config: fakeSession(), cancel: token, onText: chunks.add)
        }
    }
    var n = 0
    while chunks.text.isEmpty {
        n += 1
        try #require(n < 1000)
        usleep(10_000)
    }
    token.cancel()
    #expect(throws: AIError.cancelled) { try done.wait().get() }
    #expect(FakeAPI.stopped.withLock { $0.contains(key) })
}

@Test func sseFraming() {
    var p = SSE()
    #expect(p.feed(Array("event: a\r\ndata: {\"x\":1}\r\n\r\n".utf8)) == [SSE.Event(name: "a", data: "{\"x\":1}")])
    #expect(p.feed(Array("data:one\ndata: two\n".utf8)).isEmpty)
    #expect(p.feed(Array("\n".utf8)) == [SSE.Event(name: "", data: "one\ntwo")])
    #expect(p.feed(Array(": comment\n\nevent: b\n".utf8)).isEmpty)
    // A letter split between reads.
    let han = Array("data: 한\n\n".utf8)
    #expect(p.feed(han[..<7]).isEmpty)
    #expect(p.feed(han[7...]) == [SSE.Event(name: "b", data: "한")])  // `event: b` from above
    // Unfinished at the end: never delivered.
    #expect(p.feed(Array("data: half".utf8)).isEmpty)
}

// MARK: - Choosing

@Test func choosingABackend() {
    var c = Config()
    #expect(chooseBackend(c, claude: "/bin/claude", apiKey: "k") == .claudeCli(path: "/bin/claude"))
    #expect(chooseBackend(c, claude: nil, apiKey: "k") == .api(key: "k"))
    #expect(chooseBackend(c, claude: nil, apiKey: nil) == nil)
    c.backend = .api
    #expect(chooseBackend(c, claude: "/bin/claude", apiKey: "k") == .api(key: "k"))
    #expect(chooseBackend(c, claude: "/bin/claude", apiKey: nil) == nil)
    c.backend = .claudeCli
    #expect(chooseBackend(c, claude: nil, apiKey: "k") == nil)
    #expect(chooseBackend(c, claude: "/bin/claude", apiKey: nil) == .claudeCli(path: "/bin/claude"))
}
