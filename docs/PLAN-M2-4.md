# 계획: M2-4 PR 패널과 안전 Markdown

> TASKS M2-4 (F-PR-4, F-PR-5). ✓ 악성 Markdown fixture(`<script>`, `<img onerror>`, `javascript:` 링크, 외부 이미지, iframe)에서 스크립트 실행·HTML 해석·외부 요청이 없다 · 줄 코멘트가 해당 줄 옆에 보인다

등급: 위험 큼(신뢰 경계: 남이 쓴 Markdown을 화면에 그린다) → 계획 리뷰 fable + codex, 구현 리뷰 codex + fable + ponytail

## 현재 상태
- `Review.pr: PullRequest?`가 제목·본문·작성자·상태, 코멘트(시간순), 스레드(`path`, `side`, `lines`), 연결 이슈, `truncated`를 갖는다(M2-3). 화면에는 아직 아무것도 안 나온다
- UI는 AppKit만 쓴다. WebView는 없고 F-EX-3이 Explain 탭에만 허락한다
- diff는 고정 18pt 행의 `NSTableView`이고 행 수·위치는 Core의 `File.rows`가 정한다(검색, `jump`, `span`, seen, 복사, bench가 이 셈에 기댄다)

## 확인한 사실 (2026-10-13, macOS 26, `AttributedString(markdown:, interpretedSyntax: .full)`)
- 원본 HTML은 해석하지 않고 글자 그대로 둔다: 인라인 `<script>`, `<img src=x onerror=…>`, `<b>`는 `inlinePresentationIntent` 256(inlineHTML), 블록 `<iframe>…`, `<div>`는 512(blockHTML)가 붙은 텍스트 run이다
- 링크는 scheme을 가리지 않는다: `javascript:`, `file:`, `data:`, 상대경로 `/foo` 모두 `.link`가 된다. `www.bare.com`은 `http://www.bare.com`, `<https://x>`는 https 링크
- 이미지는 alt 텍스트에 `imageURL` 속성만 붙는다. 무엇도 불러오지 않는다
- 블록 구조는 `presentationIntent`(header, paragraph, listItem, unorderedList, codeBlock, blockQuote)로만 오고, 블록 사이 줄바꿈 글자는 없다. 그대로 그리면 문단이 한 줄로 붙는다

## 설계

### 1. 렌더러 (`GriiyCore/Markdown.swift`, Foundation만)
```swift
/// Someone else's Markdown as text we control (F-PR-5): raw HTML stays literal characters, links
/// only https/mailto, images only a placeholder. The app maps it to fonts and colors.
public func markdown(_ source: String) -> AttributedString
```
- `AttributedString(markdown:, options: .init(interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible))`. 파싱이 실패하면 원문 그대로(속성 없음)
- 결과는 새로 만든 `AttributedString`에 run을 하나씩 옮겨 담는다. 옮기는 속성은 허용 목록이다: `inlinePresentationIntent`(강조·코드·취소선), 걸러낸 `link`, 이미지 자리의 `imageURL`. 원본의 나머지 속성은 따라오지 않는다
- 블록: `presentationIntent`의 블록 id가 바뀌면 줄바꿈을 넣는다(문단 사이 빈 줄 하나). 목록 항목은 `• `/`1. `, 인용은 `▎ `, 제목은 `inlinePresentationIntent.stronglyEmphasized`, 코드 블록은 줄마다 `.code`. 들여쓰기는 깊이 × 2칸
- 링크 허용 목록: `URL.scheme?.lowercased()`가 정확히 `https` 또는 `mailto`일 때만 `.link`. 나머지(`http`, `javascript`, `JAVASCRIPT`, `vbscript`, `data`, `file`, 상대경로, scheme 없는 `//host`)는 링크를 떼고 글자만 남긴다. http를 https로 올리지 않는다: PRD가 https만 허용하고, 올리면 다른 주소가 된다
- 이미지: alt 텍스트 대신 `[image: <alt>]` 글자 하나. https면 그 run에 `imageURL`을 남기고(앱이 "show image" 링크로 바꾼다), 아니면 글자만
- 원본 HTML run(256/512)은 글자 그대로 두고 `.code`로 표시한다. 이스케이프는 따로 할 필요가 없다: 결과는 HTML로 해석되는 일이 없다

### 2. 앱의 표시 (`griiy/PRPanel.swift`)
- `NSTextView` 하나(편집 불가, 선택 가능, `NSScrollView` 안). Core 결과를 `NSAttributedString`으로 바꿀 때 폰트·색만 입힌다
- 하드닝(Core 테스트로 못 잡는 것이라 여기 적는다):
  - `isAutomaticLinkDetectionEnabled = false`, `isAutomaticDataDetectionEnabled = false`: AppKit이 Core가 뗀 링크를 다시 만들지 않게
  - `textView(_:clickedOnLink:at:)`는 언제나 `true`를 돌려준다(기본 처리는 어떤 scheme이든 `NSWorkspace`로 연다). https/mailto를 다시 확인한 뒤에만 `NSWorkspace.shared.open`
  - 링크마다 `.toolTip` = 실제 URL: `[https://good](https://evil)` 같은 글자 위장
  - `NSAttributedString(html:)`, `.documentType: .html`, WKWebView를 쓰지 않는다. CI의 크래시 호출 grep 옆에 `html:|documentType|WKWebView`가 `Sources/`에 없음을 확인하는 줄을 더한다(F-EX-3이 Explain 탭을 만들 때 그 파일만 뺀다)
- 내용(위에서 아래로): 제목(크게), `#n · author · STATE`, 본문, 연결 이슈(`owner/repo#n 제목`, 링크), 코멘트(작성자·종류·날짜 머리줄 + 본문), 줄 코멘트 스레드(`path:line` 머리줄 + 코멘트들. 줄 위치가 있으면 머리줄 클릭으로 diff의 그 줄로 간다. 해결됨·outdated 표시), `truncated`면 끝에 "More on GitHub"(PR url 링크)
- 내부 동작 링크(줄로 가기, 이미지 보기)는 `.link`에 URL이 아닌 앱 내부 값(`enum PanelLink`)을 넣는다. `clickedOnLink`에서 먼저 그것을 처리한다
- 위치: 기존 `NSSplitView`의 세 번째(오른쪽) 칸, 너비 360. PR이면 처음부터 보이고 로컬 범위면 없다. `⌘I`와 Go 메뉴 "PR Info"로 숨기고 보인다. 단축키 목록에도 넣는다
- 헤더 줄에 PR 제목을 더한다: `owner/repo   #n 제목 · 12 changed …`

### 3. 이미지 보기 (F-PR-5 "이미지 보기")
- 클릭 전에는 아무 요청도 없다. 클릭하면 그 이미지 하나만:
  - `URLSession(configuration: .ephemeral)`: 쿠키·캐시 없음. timeout 15s
  - delegate `willPerformHTTPRedirection`에서 https가 아니면 멈춘다
  - 응답 10MB 상한(`Content-Length`와 받은 바이트 둘 다), `NSImage(data:)`가 실패하면 "can't show image"
  - 크기는 패널 너비에 맞춰 줄인 `NSTextAttachment`로 placeholder 자리를 바꾼다
  - URL을 로그에 남기지 않는다(비공개 저장소 첨부 URL은 토큰을 담는다)
- ponytail: 이미지 디코딩은 ImageIO가 한다(앱 프로세스 안). 샌드박스 프로세스 분리는 하지 않는다

### 4. 줄 옆 코멘트 (✓ 둘째)
- `File.rows`에 행을 넣지 않는다. Core의 행 셈을 건드리지 않고 UI가 붙인다
- Core에 순수 함수 하나:
  ```swift
  /// Threads that have a place in `file`, by row index in `file.rows`: each at its last line, the
  /// row GitHub shows it under. Others (outdated, file comments, lines not in the diff) aren't in it.
  public func threadRows(_ threads: [ReviewThread], in file: File) -> [Int: [ReviewThread]]
  ```
  `.head`는 `newNo`, `.base`는 `oldNo`가 `lines.upperBound - 1`인 줄. 짝 줄이 diff에 없으면(문맥 밖) 빠진다
- `DiffController`가 파일별로 처음 그릴 때 계산해 둔다(구문 강조 `lexed`처럼). 그 행은 오른쪽 끝(기존 `stats` 자리)에 `💬 author: 첫 줄…`(최대 60자, muted)을 그리고 왼쪽 거터 배경을 강조색으로 칠한다
- 클릭: 그 행을 클릭하면 `NSPopover`(너비 420, 최대 높이 400, 스크롤)가 행 옆에 스레드 전체를 같은 렌더러로 보여준다. 키보드: `c`가 커서 행의 스레드를 연다. Escape로 닫힌다
- 전체 파일 보기(`full`)에도 같은 경로로 붙는다(같은 `DiffController`)

## 테스트 (먼저)
`MarkdownTests.swift`, fixture는 문자열 리터럴
- 악성 fixture 하나(`<script>alert(1)</script>`, `<img src=x onerror=alert(1)>`, `<iframe src="https://evil">`, `[js](javascript:alert(1))`, `[J](JAVASCRIPT:alert(1))`, `[v](vbscript:x)`, `[d](data:text/html,x)`, `[f](file:///etc/passwd)`, `[r](/relative)`, `[p](//evil.com)`, `[h](http://x.com)`, `<javascript:alert(1)>`, 참조형 `[x][1]` + `[1]: javascript:alert(1)`, `www.bare.com`, `![t](https://evil.com/t.png)`, `![t](http://evil.com/t.png)`):
  - 모든 `.link`의 scheme이 `https`/`mailto` · 모든 `imageURL`의 scheme이 `https`
  - 결과 글자에 `<script>alert(1)</script>`, `onerror=alert(1)`, `<iframe` 가 그대로 있다(지워지지도 해석되지도 않음)
  - 결과의 run이 갖는 속성 키가 허용 목록 안이다
- 정상: 문단 사이 줄바꿈, 목록 `• `, 번호 목록, 코드 블록 줄마다 `.code`, 제목 강조, `[ok](https://a.com)`와 `mailto:` 유지
- `threadRows`: head 줄, base 줄(삭제 줄), 문맥 줄, 범위의 끝 줄에 붙음, `lines` nil 빠짐, diff 밖 줄 빠짐, 다른 path 빠짐
- mutation: scheme 확인을 지우면, `imageURL` 확인을 지우면 테스트가 실패한다
- 수동(진짜 ✓): 내 저장소에 악성 fixture를 본문과 코멘트에 넣은 PR을 만든다. griiy로 열어 링크 클릭이 아무것도 안 하고, `nettop -p <pid>`로 이미지 호스트 연결이 "show image" 클릭 전에는 없고 클릭 후에만 있는지 본다. 줄 코멘트가 그 줄 옆에 보이고 클릭하면 스레드가 뜬다
- 측정: rust#137944(코멘트 100개 안팎)에서 패널 만드는 시간(ms)을 결과에 적는다

## 하지 않는 것
- 표(GFM table), 체크박스, 각주: Foundation 파서가 표를 문단 글자로 둔다. 읽을 수는 있다
- bidi 제어 문자(Trojan Source) 표시, 이모지 shortcode(`:+1:`), `@mention`·`#n` 자동 링크
- 코멘트 쓰기·답글·해결(읽기 전용, F-PR-4)
- 이미지 캐시, 페이지네이션(M2-3 `truncated` 그대로)
- 코멘트 행을 diff 행 사이에 끼우기(GitHub 방식). 필요해지면 `File.rows`에 `.thread` 행을 더하는 일이라 검색·jump·span·seen의 셈을 같이 고쳐야 한다

## 계획 리뷰 (fable + codex) 반영
fable이 스크립트로 확인한 결과 경계(허용 목록 복사 + 정확한 scheme 비교 + 언제나 `true`인 delegate)는 맞다. 엔티티(`jav&#x61;script:`), 참조형, `<javascript:…>`, `[x](<javascript:…>)`, 대문자 scheme 모두 `.link`로 와서 비교에 걸린다. delegate가 `true`면 마우스 클릭과 문맥 메뉴 "Open Link" 모두 막힌다. 64K 중첩·4MB 입력도 파싱 300ms 이하(GitHub 본문 상한 65,536자)라 크기 제한은 두지 않는다(codex 6은 받지 않음, 측정은 한다).
- R1 (fable 5, codex 1·2): 이미지 디코딩은 `CGImageSourceCreateThumbnailAtIndex`(`ThumbnailMaxPixelSize` = 패널 너비×2, `FromImageAlways`)로. 픽셀 폭탄·PDF·SVG가 막힌다. 받기는 `URLSession.bytes(for:delegate:)`를 10MB에서 끊는 루프(`Content-Length`를 믿지 않는다)
- R2 (codex 4): `.ephemeral`에 `httpShouldSetCookies = false`, `urlCredentialStorage = nil`, `httpCookieStorage = nil`. redirect마다 같은 URL 검사를 다시 한다
- R3 (codex 3): 호스트 제한은 하지 않는다. 사용자가 누른 https 이미지 하나라 링크를 브라우저로 여는 것과 같은 급이다. README §8에 이미 적혀 있다
- R4 (codex 5, fable 7): URL 검사는 Core 함수 하나 `safeLink(_ url: URL) -> Bool`: `https`면 host가 비어 있지 않고 user/password가 없을 것, 또는 `mailto`. Markdown 링크, 이미지, 클릭, redirect가 모두 이것을 부른다
- R5 (fable 4, codex 12): 앱 내부 링크는 `enum`이 아니라 `griiy://goto?…`, `griiy://image?n=…` URL(F-EX-3과 같은 scheme). 사용자 글에서는 `safeLink`를 통과한 https/mailto만 남으므로 `griiy:`가 생길 수 없다(테스트). delegate는 `link as? URL`이 아니면 무시하고 언제나 `true`
- R6 (fable 3): Core 결과를 `NSAttributedString(AttributedString)`로 잇지 않는다(`NSImageURL`, `NSPresentationIntent`가 따라온다). run마다 글자·폰트·색·link만으로 새로 만든다
- R7 (fable 1): 표도 파싱된다. 같은 행의 칸 사이 ` | `, 행 사이 줄바꿈. 표 칸 안 js 링크를 fixture에 넣는다
- R8 (fable 2): 블록 HTML(512)·코드 블록 run은 끝 `\n`을 스스로 갖고, 블록 HTML은 `presentationIntent`가 nil이다. nil도 블록 하나로 치고 끝 `\n` 하나를 떼고 간격을 넣는다. `<!-- … -->`뿐인 블록 HTML은 뺀다(GitHub도 숨긴다, PR 템플릿)
- R9 (fable 6): 줄 오른쪽 60자 미리보기는 코드 위에 겹친다. 거터 색과 `💬` 표시만, 내용은 popover
- R10 (fable 9·10·8): 제목 강조는 기존 intent에 합친다. CRLF·각주를 fixture에 넣는다
- R11 (codex 7·8): 이름 바뀐 파일은 GitHub `path`가 새 이름이다. `file.path`로 맞추고 양쪽 side 모두 rename 테스트. 전체 파일 보기도 테스트 하나
- R12 (codex 10): 분할은 트리 + 가운데(diff·full·message·find 겹침) + PR 패널. `show(_:)`는 가운데만 바꾼다
- R13 (codex 11, fable 12): CI grep은 `NSAttributedString\(html:|documentType|loadHTMLString`. WKWebView는 F-EX-3이 쓸 것이라 넣지 않는다
- 뺌 (fable): 링크 `.toolTip`(NSTextView가 기본으로 URL을 보여준다), 자동 링크·데이터 감지 끄기(편집 불가 뷰에서는 돌지 않는다)
- codex 9·fable 11: popover는 자기 창이라 키 모니터의 `e.window === window`에 걸리지 않는다. Escape는 popover가 먼저 닫는다

## 구현 리뷰 (codex + fable + ponytail) 반영
- codex 1: `![](mailto:…)`가 `safeLink`를 통과해 "show image"가 됐다. 이미지는 `safeImage`(https만)를 Core·앱·fetch·redirect가 모두 쓴다(테스트, mutation)
- codex 2·3, fable 1·5: popover가 `TextPane` 하나를 다시 쓰므로 늦게 온 이미지가 다른 스레드의 `n=0` 자리에 들어갈 수 있었고, 두 번 누르면 두 번 받았다. 클릭하면 바로 링크 없는 "loading…"(내부 속성 표시)으로 바꾸고, `show`가 올리는 세대 번호가 다르면 버린다. 동시 받기 상한(codex 2)은 두지 않는다: 받기는 사용자 클릭마다 하나다
- fable 2: 문단 안 줄바꿈(`softBreak`)이 공백이 됐다. GitHub은 PR 글의 줄바꿈을 줄바꿈으로 보인다(테스트, mutation)
- fable 3: 주석으로 시작하고 끝나는 HTML 블록이 통째로 빠졌다. 주석만 지우고 남는 것이 공백이면 뺀다
- fable 4: `threads`를 `load` 뒤에 넣어 이미 그린 행에 💬가 빠질 수 있었다. `didSet`이 다시 그린다
- fable 6·7·10: `timeoutIntervalForResource = 60`, host에 `%`가 있으면 거부, 빈 alt의 U+FFFC 제거
- ponytail: `showThreads`의 쓰지 않는 Bool 반환 삭제
- 측정: rust#137944 응답(240KB)으로 패널 만들기 103–109ms. `loaded`에서 첫 페인트를 늦추므로 트리처럼 첫 페인트 뒤(`fillTree`)로 옮겼다
- 받지 않음: GIF/WebP 픽셀 수 사전 검사(fable 8, 썸네일 API가 PNG 20k×20k를 RSS 46MB로 막는 것을 확인. 다른 형식도 같은 경로), 링크 안 이미지(배지)가 링크 글자만 남는 것(fable 9, Foundation 파서가 이미지를 버린다), 목록 안 코드 블록 들여쓰기(fable 10, 모양만), force-click 미리보기(fable 11, https 링크뿐이라 클릭과 같다)
