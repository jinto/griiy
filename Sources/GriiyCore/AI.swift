// AI backends (F-AI-5): the claude CLI with every tool off, or the Messages API. Both stream,
// both block the calling thread (run them on a Thread), both stop on `Cancel`.
import Foundation
import Synchronization
import System

public enum AIBackend: Equatable, Sendable, CustomStringConvertible {
    /// The claude executable.
    case claudeCli(path: String)
    case api(key: String)

    /// Never the key: this ends up in logs and test failures.
    public var description: String {
        switch self {
        case .claudeCli(let path): "claude CLI at \(path)"
        case .api: "Anthropic API"
        }
    }
}

public struct AIRequest: Sendable {
    public var model: String
    public var system: String
    /// Everything the model gets besides `system`: evidence and question (M3-5).
    public var prompt: String

    public init(model: String, system: String, prompt: String) {
        self.model = model
        self.system = system
        self.prompt = prompt
    }
}

public struct AIAnswer: Equatable, Sendable {
    public var text: String
    /// The model that answered: a server-side fallback can differ from the one asked for.
    public var model: String
    /// Cut off at the output limit; `text` is what came.
    public var truncated: Bool
}

public enum AIError: Error, Equatable, Sendable {
    case cliMissing
    case cliTooOld(version: String)
    case cliAuth
    /// The CLI did not show that its tools are off, so nothing it said is used.
    case toolsNotOff
    case apiAuth
    case badModel(String)
    case refused
    case failed(String)
    case cancelled

    public var title: String {
        switch self {
        case .cliMissing: "The claude CLI is not installed"
        case .cliTooOld(let v): "claude \(v) is too old"
        case .cliAuth: "Log in to the claude CLI"
        case .toolsNotOff: "claude did not turn its tools off"
        case .apiAuth: "The Anthropic API key was not accepted"
        case .badModel(let m): "Unknown model: \(m)"
        case .refused: "Claude declined to answer"
        case .failed: "The question failed"
        case .cancelled: "Cancelled"
        }
    }

    public var hint: String {
        switch self {
        case .cliMissing:
            "Install Claude Code (https://claude.com/claude-code), or set ai.backend = \"api\" in config.toml and use an API key."
        case .cliTooOld:
            "griiy needs claude \(shown(minimumCli)) or newer: claude update."
        case .cliAuth: "Run claude once in a terminal and log in, then ask again."
        case .toolsNotOff:
            "griiy only sends questions to a claude that has no tools, so it can't read your files. Update claude (claude update) or use the API backend."
        case .apiAuth: "Check the key at console.anthropic.com and enter it again."
        case .badModel: "Set ai.model in config.toml to a model you can use, such as claude-opus-5-5."
        case .refused: "Rephrase the question, or leave out the part of the evidence it may have objected to."
        case .failed: "Ask again in a moment. If it keeps failing, the message above says why."
        case .cancelled: "The question was cancelled."
        }
    }
}

/// Asks once. `onText` gets each piece of the answer as it streams, in order, on one thread at a
/// time, never after `ask` returns. A piece already on its way when the request is cancelled from
/// another thread can still arrive, so the UI checks again on the main queue. It must not block:
/// hop to the main queue to touch the UI.
public func ask(_ b: AIBackend, _ r: AIRequest, cancel: Cancel, onText: @escaping @Sendable (String) -> Void)
    throws(AIError) -> AIAnswer
{
    switch b {
    case .claudeCli(let path): try askCli(path, r, cancel: cancel, onText: onText)
    case .api(let key): try askApi(key: key, r, config: .ephemeral, cancel: cancel, onText: onText)
    }
}

/// PRD §6: `auto` prefers the CLI, then an API key; nil means ask for a key.
public func chooseBackend(_ c: Config, claude: String?, apiKey: String?) -> AIBackend? {
    let cli = claude.map(AIBackend.claudeCli)
    let api = apiKey.map(AIBackend.api)
    switch c.backend {
    case .auto: return cli ?? api
    case .claudeCli: return cli
    case .api: return api
    }
}

/// claude on PATH, else where its installer puts it (an app opened from Finder has a short PATH).
public func findClaude() -> String? {
    let env = ProcessInfo.processInfo.environment
    let dirs = (env["PATH"] ?? "").split(separator: ":").map(String.init) + [(env["HOME"] ?? "") + "/.local/bin"]
    return dirs.map { $0 + "/claude" }.first { access($0, X_OK) == 0 }
}

// MARK: - claude CLI

/// The oldest claude seen to honour every flag below (2026-10-13).
let minimumCli = [2, 1, 218]

/// `2.1.296 (Claude Code)` → [2, 1, 296].
func cliVersion(_ s: String) -> [Int]? {
    let parts = s.split(whereSeparator: \.isWhitespace).first?.split(separator: ".").map { Int($0) }
    guard let parts, !parts.isEmpty, !parts.contains(nil) else { return nil }
    return parts.compactMap { $0 }
}

/// One line of `claude -p --output-format stream-json`; only what griiy reads.
private struct CliLine: Decodable {
    struct Ignored: Decodable {}
    var type: String
    var subtype: String?
    var tools: [String]?
    var mcpServers: [Ignored]?
    var model: String?
    var event: ApiEvent?
    var error: String?
    var isError: Bool?
    var result: String?
    var stopReason: String?
}

private let snakeCase = {
    let d = JSONDecoder()
    d.keyDecodingStrategy = .convertFromSnakeCase
    return d
}()

func askCli(_ path: String, _ r: AIRequest, cancel: Cancel, onText: @escaping @Sendable (String) -> Void)
    throws(AIError) -> AIAnswer
{
    let version: String
    do {
        let (_, out, _) = try spawn(path, repo: nil, ["--version"], cancel: cancel)
        version = String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    } catch {
        throw error == .gitMissing ? .cliMissing : error == .cancelled ? .cancelled : .failed(error.detail)
    }
    let number = cliVersion(version)
    if let number, number.lexicographicallyPrecedes(minimumCli) { throw .cliTooOld(version: shown(number)) }

    // Away from the repository: nothing the CLI looks for in its folder (AGENTS.md, memory) is
    // the user's.
    let cwd = FilePath(NSTemporaryDirectory()).appending("griiy-ask")
    do {
        try FileManager.default.createDirectory(atPath: cwd.string, withIntermediateDirectories: true)
    } catch {
        throw .failed("Can't create \(cwd.string): \(error.localizedDescription)")
    }
    let args = [
        "-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
        // No tools, no MCP servers, no settings (hooks, CLAUDE.md, skills), no slash commands,
        // nothing kept on disk.
        "--tools", "", "--strict-mcp-config", "--setting-sources", "", "--disable-slash-commands",
        "--no-session-persistence", "--system-prompt", r.system, "--model", r.model,
    ]
    // Our own token: a CLI that won't show its tools off is stopped without cancelling the caller's.
    let stop = Cancel()
    cancel.onCancel { stop.cancel() }
    final class State: @unchecked Sendable {  // touched only on the reading thread
        var line: [UInt8] = []
        var model: String?
        var unsafe = false
        var code: String?
        var result: CliLine?
    }
    let s = State()
    func take(_ bytes: [UInt8]) {
        guard let l = try? snakeCase.decode(CliLine.self, from: Data(bytes)) else { return }  // a cut-off last line
        if s.model == nil {
            if l.type == "system" && l.subtype == "init", l.tools?.isEmpty == true, l.mcpServers?.isEmpty == true {
                s.model = l.model ?? r.model
            } else {
                s.unsafe = true
                stop.cancel()
            }
            return
        }
        switch l.type {
        case "stream_event":
            if case .text(let t)? = l.event?.parsed, !stop.isCancelled { onText(t) }
        case "assistant": s.code = l.error ?? s.code
        case "result": s.result = l
        default: break
        }
    }
    let status: Int32
    let stderr: [UInt8]
    do {
        (status, _, stderr) = try spawn(
            path, repo: nil, args, cancel: stop, stdin: Array(r.prompt.utf8), cwd: cwd
        ) { chunk in
            guard !s.unsafe else { return }
            var rest = chunk[...]
            while let nl = rest.firstIndex(of: UInt8(ascii: "\n")) {
                take(s.line + rest[..<nl])
                s.line = []
                rest = rest[(nl + 1)...]
            }
            s.line += rest
        }
    } catch {
        if s.unsafe { throw .toolsNotOff }
        throw error == .gitMissing ? .cliMissing : error == .cancelled ? .cancelled : .failed(error.detail)
    }
    if cancel.isCancelled { throw .cancelled }
    if s.line.count > 0 && !s.unsafe { take(s.line) }
    let err = String(decoding: stderr, as: UTF8.self)
    if s.model == nil {
        if err.contains("unknown option") { throw .cliTooOld(version: number.map(shown) ?? version) }
        throw s.unsafe || status == 0 ? .toolsNotOff : .failed(oneLine(err, or: "claude exited with status \(status)"))
    }
    guard let result = s.result else { throw .failed("claude stopped before answering") }
    let text = result.result ?? ""
    if result.isError != false {
        switch s.code {
        case "authentication_failed": throw .cliAuth
        case "model_not_found": throw .badModel(r.model)
        default: throw .failed(oneLine(text, or: "claude failed"))
        }
    }
    return AIAnswer(text: text, model: s.model ?? r.model, truncated: result.stopReason == "max_tokens")
}

private func shown(_ v: [Int]) -> String { v.map(String.init).joined(separator: ".") }

/// The first line of a message, at most 200 characters.
private func oneLine(_ s: String, or fallback: String) -> String {
    let line = s.split(whereSeparator: \.isNewline).first.map { String($0.prefix(200)) } ?? ""
    return line.isEmpty ? fallback : line
}

// MARK: - Messages API

/// A Messages API stream event (also what the CLI wraps in `stream_event`).
struct ApiEvent: Decodable {
    struct Model: Decodable { var model: String? }
    struct Delta: Decodable {
        var type: String?
        var text: String?
        var stopReason: String?
    }
    struct Block: Decodable {
        var type: String
        var to: Model?
    }
    struct Failure: Decodable {
        var type: String?
        var message: String?
    }
    var type: String
    var message: Model?
    var delta: Delta?
    var contentBlock: Block?
    var error: Failure?

    enum Parsed {
        case start(model: String?)
        case text(String)
        /// A server-side fallback: another model answers from here on.
        case model(String)
        case stop(reason: String?)
        case end
        case error(String)
    }

    var parsed: Parsed? {
        switch type {
        case "message_start": .start(model: message?.model)
        case "content_block_delta": delta?.type == "text_delta" ? delta?.text.map(Parsed.text) : nil
        case "content_block_start": contentBlock?.type == "fallback" ? contentBlock?.to?.model.map(Parsed.model) : nil
        case "message_delta": .stop(reason: delta?.stopReason)
        case "message_stop": .end
        case "error": .error(error?.message ?? error?.type ?? "error")
        default: nil
        }
    }
}

/// Server-sent events: `field: value` lines, an empty line ends an event.
struct SSE {
    struct Event: Equatable {
        var name: String
        var data: String
    }
    private var line: [UInt8] = []
    private var name = ""
    private var data: [String] = []

    mutating func feed(_ bytes: some Collection<UInt8>) -> [Event] {
        var events: [Event] = []
        for b in bytes {
            guard b == UInt8(ascii: "\n") else {
                line.append(b)
                continue
            }
            if line.last == UInt8(ascii: "\r") { line.removeLast() }
            let l = String(decoding: line, as: UTF8.self)
            line = []
            if l.isEmpty {
                if !data.isEmpty { events.append(Event(name: name, data: data.joined(separator: "\n"))) }
                name = ""
                data = []
                continue
            }
            if l.hasPrefix(":") { continue }
            let (field, value) = l.firstIndex(of: ":").map { (l[..<$0], l[l.index(after: $0)...]) } ?? (l[...], "")
            let v = String(value.hasPrefix(" ") ? value.dropFirst() : value)
            if field == "event" { name = v } else if field == "data" { data.append(v) }
        }
        return events
    }
}

private let messagesURL = URL(string: "https://api.anthropic.com/v1/messages")

/// `config` is where tests put their URLProtocol.
func askApi(
    key: String, _ r: AIRequest, config: URLSessionConfiguration, cancel: Cancel,
    onText: @escaping @Sendable (String) -> Void
) throws(AIError) -> AIAnswer {
    guard let url = messagesURL else { throw .failed("bad API URL") }
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue(key, forHTTPHeaderField: "x-api-key")
    req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    // `fallbacks: "default"`: a refusal by a safety classifier (security diffs can trip one)
    // is answered by another model instead (beta, 2026-10-13).
    req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
    req.setValue("application/json", forHTTPHeaderField: "content-type")
    let body: [String: Any] = [
        "model": r.model, "max_tokens": 64_000, "system": r.system, "stream": true, "fallbacks": "default",
        "messages": [["role": "user", "content": r.prompt]],
    ]
    req.httpBody = try? JSONSerialization.data(withJSONObject: body)

    config.httpCookieStorage = nil
    config.urlCache = nil
    config.timeoutIntervalForRequest = 120  // silence between bytes, not the whole answer
    let stream = APIStream(key: key, model: r.model, cancel: cancel, onText: onText)
    let session = URLSession(configuration: config, delegate: stream, delegateQueue: nil)
    let task = session.dataTask(with: req)
    cancel.onCancel { task.cancel() }
    task.resume()
    stream.done.wait()
    session.finishTasksAndInvalidate()
    return try stream.answer()
}

/// The delegate of one request. Its callbacks come one at a time on the session's serial queue;
/// `answer()` reads the state only after `done`.
private final class APIStream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let done = DispatchSemaphore(value: 0)
    private let key: String
    private let cancel: Cancel
    private let onText: @Sendable (String) -> Void
    private var status = 0
    private var errorBody: [UInt8] = []
    private var sse = SSE()
    private var text = ""
    private var model: String
    private var started = false
    private var ended = false
    private var stopReason: String?
    private var failure: AIError?

    init(key: String, model: String, cancel: Cancel, onText: @escaping @Sendable (String) -> Void) {
        self.key = key
        self.model = model
        self.cancel = cancel
        self.onText = onText
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)  // the key goes to api.anthropic.com and nowhere else
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        status = (response as? HTTPURLResponse)?.statusCode ?? 0
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard status == 200 else {
            if errorBody.count < 1 << 16 { errorBody += data }
            return
        }
        for e in sse.feed(data) where failure == nil && !ended {
            guard let event = try? snakeCase.decode(ApiEvent.self, from: Data(e.data.utf8)) else { continue }
            switch event.parsed {
            case .start(let m)?:
                started = true
                model = m ?? model
            case .text(let t)?:
                text += t
                if !cancel.isCancelled { onText(t) }
            case .model(let m)?: model = m
            case .stop(let reason)?: stopReason = reason ?? stopReason
            case .end?: ended = true
            case .error(let message)?: failure = .failed(hidden(oneLine(message, or: "error")))
            case nil: break
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        // A dropped connection after the whole answer came loses nothing.
        if let error, failure == nil, !ended {
            failure = .failed(oneLine(error.localizedDescription, or: "network error"))
        }
        done.signal()
    }

    /// Server text shown to the user never carries the key, even if a server echoes it.
    private func hidden(_ s: String) -> String { s.replacingOccurrences(of: key, with: "<key>") }

    func answer() throws(AIError) -> AIAnswer {
        if cancel.isCancelled { throw .cancelled }
        if status != 200 && status != 0 {
            let e = (try? snakeCase.decode(ApiEvent.self, from: Data(errorBody)))?.error  // {"type":"error",…}
            if status == 401 { throw .apiAuth }
            if status == 404 && e?.type == "not_found_error" { throw .badModel(model) }
            throw .failed(e?.message.map { "\(status) \(hidden(oneLine($0, or: "")))" } ?? "\(status)")
        }
        if let failure { throw failure }
        guard started && ended else { throw .failed("The answer stopped early") }
        if stopReason == "refusal" { throw .refused }
        return AIAnswer(text: text, model: model, truncated: stopReason == "max_tokens")
    }
}
