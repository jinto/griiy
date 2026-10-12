// PRD §6.6: config.toml. Bad values fall back to their default with a warning; never fatal.
import Foundation
import System
import Testing

@testable import GriiyCore

private func with(_ text: String) -> (Config, [String]) {
    let t = TempDir("config")
    write(t.path, "config.toml", text)
    return loadConfig(FilePath(t.path + "/config.toml"))
}

@Test func missingOrEmptyFileIsDefaults() {
    let t = TempDir("config-missing")
    for (c, w) in [loadConfig(FilePath(t.path + "/nope.toml")), with(""), with("# only a comment\n")] {
        #expect(c == Config() && w.isEmpty, "\(w)")
    }
}

@Test func validValuesAreUsed() {
    let (c, w) = with(
        "context_lines = 10\ntoken_limit = 50000\nlarge_file_bytes = 2048\n[ai]\nbackend = \"api\"\nmodel = \"claude-sonnet-5-5\"\n"
    )
    #expect(w.isEmpty, "\(w)")
    var want = Config()
    (want.backend, want.model, want.contextLines, want.tokenLimit, want.largeFileBytes) =
        (.api, "claude-sonnet-5-5", 10, 50_000, 2048)
    #expect(c == want)
}

@Test func badValuesFallBackWithAWarningEach() {
    var (c, w) = with(
        "context_lines = \"forty\"\ntoken_limit = 5\nlarge_file_bytes = -1\ncolour = true\n[ai]\nbackend = \"gpt\"\nmodel = 3\nextra = 1\n"
    )
    #expect(c == Config())
    #expect(w.count == 7, "\(w)")
    for key in ["context_lines", "token_limit", "large_file_bytes", "colour", "ai.backend", "ai.model", "ai.extra"] {
        #expect(w.contains { $0.contains(key) }, "no warning for \(key): \(w)")
    }
    // One bad value doesn't spoil its neighbours.
    (c, w) = with("context_lines = 1.5\ntoken_limit = 2000\nai = \"claude\"\n")
    #expect(c.contextLines == 40 && c.tokenLimit == 2000 && w.count == 2, "\(w)")
}

@Test func crlfAndLiteralStringsAreFine() {
    let (c, w) = with("context_lines = 10\r\ntoken_limit = 50000 \r\n[ai]\r\nmodel = 'claude-sonnet-5-5'\r\n")
    #expect(w.isEmpty, "\(w)")
    #expect(c.contextLines == 10 && c.tokenLimit == 50_000 && c.model == "claude-sonnet-5-5")
}

@Test(arguments: ["context_lines = \n[[[", "a = 1\na = 2\n", "x = [1, 2]\n", "ai.model = \"x\"\n", "k = \"open\n"])
func syntaxErrorIsDefaultsWithAWarning(text: String) {
    let (c, w) = with(text)
    #expect(c == Config() && w.count == 1, "\(w)")
}
