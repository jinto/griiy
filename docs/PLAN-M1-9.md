# 계획: M1-9 구문 강조 (F-DV-3)

> TASKS M1-9: 첫 페인트 후, 보이는 줄만. ✓ 강조 전후 bench 첫 화면 차이 < 50ms · 12만 줄 스크롤 기준(M1-6) 유지

## 현재 상태
- `DiffController.configure`가 행 뷰를 채울 때 줄마다 `NSAttributedString` 하나를 만든다. 행 뷰는 화면에 보이는 것만 있다(최대 약 40개). diff와 전체 보기는 각자 `DiffController`가 있고(`diff`, `full`), 전체 보기는 파일을 열 때마다 `full.load([f])`로 바꾼다
- 색은 `Palette`(라이트/다크 쌍)에 있다. 의존성은 없다(Foundation + AppKit)

## 설계

### 0. 무엇을 쓰나
- **직접 만든 작은 lexer를 쓴다.** 토큰은 키워드, 문자열, 주석, 숫자 네 가지이고, 언어는 확장자로 정한 표 하나로 다룬다. 이유는 다음과 같다
  - AppKit에는 공개된 구문 강조 API가 없다
  - tree-sitter는 언어마다 C 문법이 따라오는 큰 의존성이다
  - Highlightr는 JavaScriptCore 위에서 highlight.js를 돌린다. 줄마다 JS를 왕복해야 해서 가상 스크롤과 맞지 않는다
  - Splash는 Swift만 지원한다
- 정확도의 한계: 문맥이 필요한 구분(타입 이름, 함수 호출, 정규식 리터럴, heredoc)은 하지 않는다. diff 리뷰에서 필요한 것은 "주석인가, 문자열인가, 코드인가"를 보는 일이고, 네 토큰으로 충분하다

### 1. 코어 `Sources/GriiyCore/Syntax.swift`
```swift
public enum Token: Sendable { case keyword, string, comment, number }

/// A language as the lexer sees it, picked by file name.
public struct Lang: Sendable {
    public static func of(path: String) -> Lang?     // 모르는 확장자면 nil → 강조하지 않는다
}

/// Where a line starts: in code, a block comment, or a multi-line string.
public enum LexState: Equatable, Sendable { case code, comment, string(Quote) }

/// Spans of one line in UTF-16 offsets (NSString's), and the state the next line starts in.
public func lex(_ text: String, _ lang: Lang, from: LexState) -> (spans: [(Range<Int>, Token)], end: LexState)

/// The state each row of `f.rows(from:n:)` starts in, for the whole file.
public func lexStates(_ f: File, _ lang: Lang) -> [LexState]
```
- 바이트를 훑으면서 UTF-16 단위를 함께 센다(R4: lead ≥ 0xF0이면 2, continuation이면 0, 나머지는 1). 그래서 span을 바로 `NSAttributedString`에 쓸 수 있고, 비ASCII 변환도 코어 테스트로 확인된다. `≥ 0x80` 바이트는 식별자 글자로 취급한다
- 앞서 보기(lookahead)는 하지 않는다. 그래서 줄 길이에 선형이다(R1: 닫는 따옴표를 앞서 찾으면 `'\'\'…` 100KB 줄이 2.9s 걸렸다)
- 문자열:
  - `"`는 탐욕적이다. 닫히지 않으면 줄 끝까지 문자열이고, 다음 줄은 `code`로 시작한다
  - `'`는 언어마다 둘 중 하나다
    - Python, Ruby, JS/TS, shell, SQL, Lua, YAML/TOML, PHP, CSS: `"`와 같다
    - C 계열(Rust, Go 포함): 문자 리터럴 규칙을 쓴다. `'` + (`\…` 또는 UTF-8 한 글자) + `'`일 때만 문자열이고, 아니면 `'` 하나를 지나간다. Rust `'a`, `<'a, 'b>`, `'x'`, `'\n'`이 모두 맞다
    - Swift에는 `'`가 없다
  - 이스케이프는 따옴표 종류마다 다르다(R6). `\`는 다음 글자를 건너뛰지만, Go raw backtick, shell `'`에는 이스케이프가 없다. SQL의 `''`는 문자열 두 개가 붙은 것이라 결과 색이 같다
  - 여러 줄 문자열: Python `"""`/`'''`, Swift·Kotlin·Java·Scala `"""`, JS 템플릿과 Go raw 문자열의 backtick. 이것들은 줄을 넘어 상태를 이어간다. `"""`는 이 언어들에만 있다
- 블록 주석(`/* */`, Lua `--[[ ]]`)은 상태를 이어간다. Lua는 `--[[`를 `--`보다 먼저 본다. 중첩은 세지 않는다(`ponytail:` 주석)
- `#` 줄 주석: shell, YAML, TOML, Makefile, Dockerfile에서는 줄 시작이나 공백 뒤에서만 주석이다(R5: `${#a[@]}`, `$#`, URL의 `#frag`). Python, Ruby는 어디서든 주석이다
- 숫자: 식별자 글자 뒤가 아닌 곳의 숫자로 시작해 `[0-9A-Za-z_.]`가 이어지는 동안 숫자다. `e`/`E` 뒤의 `+`/`-`도 포함한다. 대략 맞으면 된다
- 키워드: 식별자 전체가 언어의 키워드 집합에 있을 때. SQL은 대소문자를 무시한다. 자주 보는 언어(Swift, Python, JS/TS, Go, Rust, shell)는 고유 집합을 두고, 나머지 C 계열은 공통 집합 하나를 쓴다(R8)
- 하지 않는 것(정확도 한계): Ruby `%q()`, heredoc, shell backtick, 정규식 리터럴, HTML/XML
- 언어 표: C 계열(c, h, cc, cpp, hpp, m, mm, java, kt, kts, cs, go, rs, swift, js, jsx, mjs, cjs, ts, tsx, scala, dart, php), Python, Ruby, shell(sh, bash, zsh), YAML/TOML(주석·문자열·숫자만), SQL, Lua, CSS(주석·문자열·숫자만), JSON(문자열·숫자·`true false null`), 그리고 파일 이름 `Makefile`, `Dockerfile`. 언어마다 다른 것은 줄 주석 시작, 블록 주석 쌍, 따옴표 종류, 키워드 집합뿐이다

### 2. 줄 사이 상태: hunk 안에서 old/new 두 갈래
- `lexStates`는 `hunks`를 직접 돌며 행 번호를 센다(`rows`로 `Row`를 만들지 않는다). 상태는 두 갈래를 들고 간다
  - 삭제 줄은 old 상태로, 추가 줄과 문맥 줄은 new 상태(head 쪽)로 시작한다
  - 문맥 줄은 두 갈래를 각각 진행한다. 추가 줄이 `/*`를 열었다면 같은 문맥 줄이 old에서는 code로, new에서는 comment로 끝나기 때문이다(R3). `old == new`이면 한 번만 lex한다
  - 상태만 구하는 경로는 span과 키워드 조회를 건너뛴다(R2). 측정해 보니 12만 줄에서 11ms였고, span까지 만들면 31~47ms였다
- hunk마다 `code`로 다시 시작한다. hunk 앞 내용을 모르기 때문이다. 블록 주석 한가운데서 시작하는 hunk는 틀리게 칠해진다(`ponytail:` 주석. 전체 보기는 hunk 하나라서 맞다). 이 한계를 없애려면 양쪽 blob 전체를 lex해야 하는데, git 호출이 더 든다
- 상태 배열은 컨트롤러마다(`diff`, `full`) 파일을 처음 그릴 때 만들어 `[Int: [LexState]]`에 둔다. `load` 때 비운다(R-codex9: `full`은 파일을 바꿔 가며 index 0을 다시 쓴다). 12만 줄 파일도 한 번에 첫 호출 약 28ms(콜드), 이후 약 12ms이고, 앞서 보기가 없으니 MB 단위 한 줄도 선형이다. 그래서 hunk 단위 분할이나 백그라운드 계산은 하지 않는다

### 3. 앱 `DiffView.swift`
- `configure`는 파일 안 행 번호를 받는다(`rowViewForRow`의 `r - start[f]`). `.line`이면 화면에 그릴 문자열(`\r` 제거, `maxChars` 자르기)을 lex하고, 시작 상태는 `lexStates[row]`에서 가져온다. 결과 span은 gutter 13자만큼 밀어서 색만 덧칠한다. 잘린 줄도 span만 쓰고 상태는 쓰지 않으므로 `lexStates`와 어긋나도 해가 없다
- 강조는 보이는 행에서만 일어난다. 행 뷰가 화면에 보이는 것만 있기 때문이다. 그래서 줄 배경(추가/삭제)과 글자 색은 겹치지 않는다
- 색(`Palette`, GitHub의 라이트/다크 값):
  - 키워드 `cf222e`/`ff7b72`
  - 문자열 `0a3069`/`a5d6ff`
  - 주석 `6e7781`/`8b949e`
  - 숫자 `0550ae`/`79c0ff`
- **"첫 페인트 후"는 따로 지연하지 않는다.** PRD 문구는 WebView에서 highlight.js를 늦게 싣는 것을 뜻했다. 여기서는 첫 화면이 줄 40개쯤이라 강조 비용이 마이크로초 단위다. 정말 그런지 ✓(첫 화면 차이 < 50ms)로 확인하고, 넘으면 첫 페인트 뒤에 보이는 행만 다시 그리는 방식으로 바꾼다

### 4. 측정
- `scripts/bench.sh 5 before=<HEAD 빌드> after=.build/release/griiy -- <합성 12만 줄 저장소>`: 첫 화면 중앙값 차이 < 50ms, long-frame ≤ 1%, 행 뷰 < 5,000
- 12만 줄짜리 새 파일 하나로 `lexStates` 시간을 잰다(release)

## 테스트 (먼저) `Tests/GriiyCoreTests/SyntaxTests.swift`
- `Lang.of`: 확장자, 대소문자, `Makefile`, 모르는 확장자는 nil
- 한 줄 lex: 키워드, 식별자 속 키워드(`format`의 `for`)는 아님, 숫자(`x1`의 `1`은 아님), 이스케이프 따옴표, 줄 주석 뒤는 전부 주석, 문자열 속 `//`는 주석이 아님, Rust `'a`(문자열 아님)와 `'x'`(문자열)
- 줄을 넘는 상태: `/*` 다음 줄은 주석, `*/` 뒤는 코드 · Python `"""` 독스트링 안의 `don't` · JS backtick
- `lexStates`: 추가 줄이 연 `/*`는 그 뒤 문맥 줄을 지나도 삭제 줄에 번지지 않는다(old/new 두 갈래, 사이에 문맥 줄을 끼운다) · 새 hunk는 `code`로 시작 · 행 인덱스가 `rows(from:n:)`와 맞다(헤더, hunk 헤더 행 포함)
- 비ASCII: `"한글" // 주석`, 이모지 뒤 키워드의 span이 UTF-16 offset으로 맞다
- 성능 회귀: `'\'` 반복 100KB 줄이 C 계열과 Python 모두 1ms 안에 lex된다
- `#`: shell `${#a}`와 `$#`는 주석이 아니고 ` # x`는 주석 · Go backtick 안의 `\`가 닫는 backtick을 건너뛰지 않는다 · C의 `"""`는 여러 줄 문자열이 아니다
- 수동 확인: Swift·Python 파일이 있는 diff를 라이트/다크에서 창만 캡처

## 계획 리뷰 (fable + codex) 반영
- fable R1 높음: 닫는 따옴표를 앞서 찾는 규칙은 O(n²)이고 Rust `<'a, 'b>`도 못 막는다 → 앞서 보기를 없앴다. `"`는 탐욕적으로, `'`는 언어별(탐욕적 / C 문자 리터럴)로 처리한다
- fable R2 높음: 상태 계산에서 span을 버리는 방식은 비싸다 → 상태 전용 경로를 둔다(12만 줄 11ms). hunk 분할 분기는 지웠다
- fable R3: 문맥 줄은 두 갈래를 각각 진행한다. 테스트에 문맥 줄을 끼운다
- fable R4: lexer가 UTF-16 단위를 직접 센다. gutter만큼 민다(codex 2와 같다)
- fable R5, codex 6: shell·YAML 계열의 `#`은 공백 뒤에서만 주석이다
- fable R6: 이스케이프는 따옴표 종류마다 다르다. `"""`는 해당 언어에만 둔다
- fable R7, R8: `<!-- -->`를 뺐고, Lua 순서를 고쳤고, SQL은 대소문자를 무시한다. `hunks`를 직접 돈다. C 계열은 공통 키워드 집합을 쓴다
- codex 1, 4(첫 페인트·긴 줄 블로킹): 선형 lexer와 상태 전용 경로로 12만 줄 약 11ms라 지연·백그라운드는 두지 않는다. bench ✓로 확인한다
- codex 3: `configure`에 파일 안 행 번호를 넘긴다
- codex 5(SQL `''`): 문자열 두 개가 붙은 것이라 색이 같다. 규칙을 따로 두지 않는다
- codex 7, 8: Ruby `%q`, heredoc, shell backtick은 범위에서 뺀다고 적었다. 숫자는 지수 부호만 더하고 대략 맞으면 된다
- codex 9: 컨트롤러가 둘이라는 현재 상태를 바로잡았다. 캐시는 컨트롤러마다 두고 `load` 때 비운다
- codex 10: UTF-16 변환이 코어로 옮겨져 단위 테스트로 확인된다

## 구현 리뷰 (codex + fable + ponytail) 반영
- codex: PHP `#` 주석 추가 · YAML/TOML의 `'`는 이스케이프가 없다(`rawSingle`)
- codex: 한 grapheme에 결합 문자가 수백만 개 붙으면 `maxChars`(Character 단위)를 넘는다. 이번 변경 전부터 있던 문제라 고치지 않았다
- fable R1: 삭제 줄 갈래가 테스트되지 않았다 → 삭제 줄만으로 블록 주석을 여닫는 테스트를 추가했다
- fable R6: 지수 부호, JS backtick 이스케이프, 탭 뒤 `#`, Dockerfile 대소문자 테스트를 추가했다(각각 mutation이 살아남던 곳)
- fable R7: `skip`에 음수 방어를 넣었다 · R8: 캐시는 없을 때만 만든다
- 남긴 한계: YAML 평문의 `'`(`desc: It's`)는 줄 끝까지 문자열로 칠해진다. "앞이 글자면 따옴표가 아니다" 규칙은 Python `f'…'`를 깨뜨려서 넣지 않았다. TOML `"""`/`'''`는 모른다. 숫자는 `0xfe-1`, `1...5`를 하나로 본다
- ponytail: `Lexer.init`(멤버와이즈와 같음), 한 번만 쓰는 `cFamily`/`scripted` 상수를 지웠다

## 측정 (2026-10-13, release, 5라운드 중앙값, scripts/bench.sh, 합성 Swift 코드 저장소)
| 저장소 | 첫 화면 전 → 후 | long-frame | 행 뷰 최대 |
|---|---|---|---|
| 15만 행, 300파일 | 271 → 267ms | 0/590 | 39 |
| 12만 행, 1파일 | 246 → 274ms (+28ms, `lexStates` 첫 호출) | 0/590 | 39 |
