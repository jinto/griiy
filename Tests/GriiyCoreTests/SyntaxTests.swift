// M1-9 (F-DV-3): the syntax lexer, line by line and across a file's rows.
import Foundation
import Testing

@testable import GriiyCore

/// The colored pieces of `text` as (substring, token), plus the state the next line starts in.
private func lexed(_ text: String, _ path: String, from: LexState = .code) -> ([String], [Token], LexState) {
    guard let lang = Lang.of(path: path) else { return ([], [], from) }
    let r = lex(text, lang, from: from)
    let ns = text as NSString
    return (r.spans.map { ns.substring(with: NSRange($0.0)) }, r.spans.map(\.1), r.end)
}

private func pieces(_ text: String, _ path: String, from: LexState = .code) -> [String] {
    lexed(text, path, from: from).0
}

@Test func langByFileName() {
    #expect(Lang.of(path: "a/b.swift") != nil)
    #expect(Lang.of(path: "X.PY") != nil)
    #expect(Lang.of(path: "src/Makefile") != nil && Lang.of(path: "Dockerfile") != nil)
    #expect(Lang.of(path: "notes.txt") == nil && Lang.of(path: "README") == nil && Lang.of(path: "a.") == nil)
}

@Test func lexOneLine() {
    let (p, t, end) = lexed("let x = format(\"a\\\"b\", 42) // done", "a.swift")
    #expect(p == ["let", "\"a\\\"b\"", "42", "// done"])
    #expect(t == [.keyword, .string, .number, .comment])
    #expect(end == .code)
    // Keywords and numbers only as whole words.
    #expect(pieces("format x1 forx _if 0x1F 1.5e+9", "a.go") == ["0x1F", "1.5e+9"])
    #expect(pieces("x := 1+2", "a.go") == ["1", "2"])
    #expect(pieces("FROM ubuntu AS base", "Dockerfile") == ["FROM", "AS"])
    #expect(pieces("s = \"// no\" # yes", "a.py") == ["\"// no\"", "# yes"])
}

@Test func unclosedDoubleQuoteRunsToLineEnd() {
    let (p, _, end) = lexed("x = \"abc", "a.c")
    #expect(p == ["\"abc"] && end == .code)
}

@Test func singleQuotesPerLanguage() {
    // C family: char literals only, so Rust lifetimes stay code.
    #expect(pieces("fn f<'a, 'b>(x: &'a str) -> char { 'x' }", "a.rs") == ["fn", "'x'"])
    #expect(pieces("c = '\\n'; d = '한'", "a.c") == ["'\\n'", "'한'"])
    // Script languages: strings like ".
    #expect(pieces("x = 'it is' + 'b'", "a.py") == ["'it is'", "'b'"])
    #expect(pieces("SELECT 'it''s'", "a.sql") == ["SELECT", "'it'", "'s'"])
    // Shell single quotes have no escapes.
    #expect(pieces("echo 'a\\' b", "a.sh") == ["echo", "'a\\'"])
    #expect(pieces("s = 'a\\' # c", "a.toml") == ["'a\\'", "# c"])
    // Swift has no single-quote strings.
    #expect(pieces("let c = 'x'", "a.swift") == ["let"])
}

@Test func hashCommentsNeedASpaceInShellAndYaml() {
    #expect(pieces("echo ${#a[@]} $# # real", "a.sh") == ["echo", "# real"])
    #expect(pieces("# top", "a.sh") == ["# top"])
    #expect(pieces("x=1\t# c", "a.sh") == ["1", "# c"])
    #expect(pieces("url: http://x/#frag # note", "a.yml") == ["# note"])
    #expect(pieces("x = a#b", "a.rb") == ["#b"])
    #expect(pieces("$x = 1; # c", "a.php") == ["1", "# c"])
}

@Test func blockCommentsCarryAcrossLines() {
    let (p1, _, s1) = lexed("int x; /* open", "a.c")
    #expect(p1 == ["int", "/* open"] && s1 == .comment)
    let (p2, _, s2) = lexed("still if */ return 1;", "a.c", from: s1)
    #expect(p2 == ["still if */", "return", "1"] && s2 == .code)
    let (_, _, lua) = lexed("--[[ long", "a.lua")
    #expect(lua == .comment)
    #expect(lexed("-- line", "a.lua").2 == .code)
}

@Test func multiLineStrings() {
    let (p1, _, s1) = lexed("def f():  \"\"\"Doc", "a.py")
    #expect(p1 == ["def", "\"\"\"Doc"] && s1 != .code)
    let (p2, _, s2) = lexed("don't if \"\"\" + 1", "a.py", from: s1)
    #expect(p2 == ["don't if \"\"\"", "1"] && s2 == .code)
    let (_, _, js) = lexed("const s = `a ${b}", "a.ts")
    #expect(js != .code)
    #expect(pieces("x` + 1", "a.ts", from: js) == ["x`", "1"])
    #expect(pieces("s = `a\\`b` + 1", "a.js") == ["`a\\`b`", "1"])
    // Go raw strings have no escapes: the backslash doesn't eat the closing backtick.
    #expect(pieces("p := `C:\\` + 1", "a.go") == ["`C:\\`", "1"])
    // """ is no multi-line string in C: "" then an unclosed ".
    #expect(lexed("s = \"\"\"x", "a.c").2 == .code)
}

@Test func sqlKeywordsIgnoreCase() {
    #expect(pieces("select * From t", "a.sql") == ["select", "From"])
}

@Test func spansAreUtf16Offsets() {
    let (p, t, _) = lexed("s = \"한글\" // 주석 🎉 return", "a.swift")
    #expect(p == ["\"한글\"", "// 주석 🎉 return"] && t == [.string, .comment])
    #expect(pieces("x = \"🎉\"; return 1", "a.js") == ["\"🎉\"", "return", "1"])
}

@Test func linearOnPathologicalLines() {
    let line = String(repeating: "'\\", count: 50_000)
    for path in ["a.rs", "a.py", "a.sh"] {
        let t0 = Date()
        _ = lex(line, Lang.of(path: path)!, from: .code)
        #expect(Date().timeIntervalSince(t0) < 0.2, "\(path)")
    }
}

private func line(_ kind: Kind, _ text: String) -> Line { Line(kind: kind, oldNo: nil, newNo: nil, text: text) }

@Test func statesFollowRowsAndBothSides() {
    var f = File(path: "a.c", status: .modified)
    f.hunks = [
        Hunk(
            oldStart: 1, oldLen: 3, newStart: 1, newLen: 3, section: "",
            lines: [
                line(.add, "/* opened in head"),
                line(.context, "middle"),
                line(.del, "base code"),
                line(.add, "head comment */"),
                line(.context, "after"),
            ]),
        Hunk(oldStart: 9, oldLen: 1, newStart: 9, newLen: 1, section: "", lines: [line(.add, "x")]),
    ]
    let s = lexStates(f, Lang.of(path: f.path)!)
    #expect(s.count == f.rowCount)
    // Rows: header, hunk, add, context, del, add, context, hunk, add.
    #expect(s == [.code, .code, .code, .comment, .code, .comment, .code, .code, .code])
}

@Test func deletedLinesCarryTheBaseState() {
    var f = File(path: "a.c", status: .modified)
    f.hunks = [
        Hunk(
            oldStart: 1, oldLen: 3, newStart: 1, newLen: 0, section: "",
            lines: [line(.del, "/* a"), line(.del, "b"), line(.del, "*/ c")])
    ]
    #expect(lexStates(f, Lang.of(path: f.path)!) == [.code, .code, .code, .comment, .comment])
}

@Test func statesResetPerHunk() {
    var f = File(path: "a.c", status: .modified)
    f.hunks = [
        Hunk(oldStart: 1, oldLen: 1, newStart: 1, newLen: 1, section: "", lines: [line(.context, "/* open")]),
        Hunk(oldStart: 9, oldLen: 1, newStart: 9, newLen: 1, section: "", lines: [line(.context, "x")]),
    ]
    #expect(lexStates(f, Lang.of(path: f.path)!) == [.code, .code, .code, .code, .code])
}
