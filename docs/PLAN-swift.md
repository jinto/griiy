# 계획: Rust → Swift 전환

> 결정 (2026-10-13, 사용자): UI는 AppKit, 코어도 Swift로 간다. Rust는 쓰지 않는다. 기준 명세는 커밋 `a97e3b8`의 Rust 코드와 테스트 59개다. Swift 버전이 같은 테스트를 통과하면 Rust 파일을 지운다.
> 배경: docs/SPIKE-native-ui.md (스파이크 B가 가장 깔끔했다). UI 출발점: `spike/b-appkit-swift/Sources/*.swift` (FFI를 빼고 코어를 직접 부르게 바꾼다).

## 목표와 범위
- 지금 Rust 버전이 하는 일을 그대로 Swift로 옮긴다. 범위: M1-1~M1-6, M0-6 store, M0-7 에러 화면, M0-8 설정, bench
- 기능은 늘리지 않는다. 화면은 W(WebKit 버전)의 M1-5/6 화면과 같다
- 성능 기준은 W 기준값(SPIKE 문서)과 PRD §8: big120k 첫 화면 ≤ 0.47s, 스크롤 50ms 초과 프레임 ≤ 1%, footprint 합 ≤ W

## 구조 (SwiftPM, 저장소 루트)
```
Package.swift            swift-tools 6.x, platforms: macOS 14
Sources/GriiyCore/       UI 없는 코어 (Foundation만)
  Args.swift             griiy [<rev>|a..b|a...b] [-C <repo>]
  Git.swift              Error(F-IN-5), run(취소·프로세스 그룹), resolve, fetch, Review
  Diff.swift             파서 (UTF-8 바이트 기반), File/Hunk/Line, rows(from:n:), rowCount, summary
  Store.swift            리뷰 키, 원자적 저장, 손상 파일 백업
  Config.swift           config.toml 로드 (필요한 부분만 파싱하는 작은 파서)
Sources/griiy/           AppKit 앱 (실행 파일)
  main.swift  Diff/Tree/Markdown 뷰 (스파이크 B에서 가져온다)
Tests/GriiyCoreTests/    Swift Testing. Rust tests/*.rs를 1:1로 옮긴다 (+ Support: 임시 git 저장소)
scripts/bundle.sh        .app 번들 + CLI 심링크 (M0-3/M4-2 기반)
```
- 의존성은 없다(Foundation, AppKit만). 새 의존성은 이유가 있어야 한다는 규칙은 그대로다
- Swift 6 언어 모드를 쓴다. 코어 타입은 값 타입 + `Sendable`, UI는 `@MainActor`다

## Rust 구성 요소 → Swift
| Rust | Swift | 비고 |
|---|---|---|
| `args.rs` | `Args.swift` | `-C` 경로는 바이트 그대로 둔다(`CommandLine.arguments`는 String이므로, 실패하면 사용법 에러) |
| `git.rs::run` | `Git.run` | `Process`는 프로세스 그룹을 지원하지 않는다. `posix_spawn` + `POSIX_SPAWN_SETPGROUP`으로 래퍼를 직접 만든다. `LC_ALL=C`, `GIT_TERMINAL_PROMPT=0`, `GIT_LITERAL_PATHSPECS=1`, `GIT_DIFF_OPTS` 제거, stdout/stderr 동시 drain, 취소 시 그룹 kill |
| `git.rs::Review` | `Review.open(dir:spec:)` | ls-files를 diff와 병렬로 돌린다(`async let` 또는 스레드). 고정 diff 옵션은 그대로 |
| `diff.rs` | `Diff.swift` | **UTF-8 바이트(`[UInt8]` / `Span`)로 파싱한다.** Swift `String`의 문자 단위 순회는 15만 줄에서 느리다. 이름 C 따옴표 풀기, TAB 꼬리, hunk 수 기반 종료, overflow 거부는 그대로 |
| `store.rs` | `Store.swift` | JSON은 `JSONSerialization`. 원자적 저장은 `Data.write(options: .atomic)`가 임시 파일 + rename을 해 준다 |
| `config.rs` | `Config.swift` | TOML 의존성 대신, 지금 쓰는 부분(`key = value`, `[ai]` 테이블, 문자열·정수)만 읽는 작은 파서다. 알 수 없는 키와 잘못된 타입은 경고 |
| `protocol.rs`, `events.rs`, `src/app/*` | 없음 | WebView 경계가 사라진다. 백그라운드 → 메인은 `MainActor`로 넘기고, 취소는 `Task` 취소 + `Git.run` 취소다 |
| `main.rs` | `Sources/griiy/main.swift` | 리뷰는 창 생성과 병렬로 연다(W와 같다). bench mark 2줄 규약은 그대로(`GRIIY_MARK`) |

## 규칙 (CONTRIBUTING을 이렇게 바꾼다)
- `swift build -c release`, `swift test`, `swift format lint --strict --recursive Sources Tests`
- 테스트 밖에서 크래시 금지: `!` 강제 언래핑, `try!`, `as!`, `fatalError`, `precondition` 0건. `grep`으로 검사한다(Rust의 unwrap/expect 규칙에 해당)
- 파일은 ID로만 다룬다는 규칙은 UI 내부 모델에 그대로 둔다(경로를 다시 git에 넘기지 않는다)

## 진행 순서 (각 단계는 테스트를 먼저 옮기고 통과시킨다)
1. **골격:** Package.swift, CI(`.github/workflows/ci.yml`: macOS 러너, swift build/test/format, release 크기 출력), 테스트 지원(임시 저장소, git 래퍼)
2. **Args + Git.run + Error** (args 3, errors 7)
3. **Diff 파서** (diff 15) + 성능 확인: big120k 파싱 시간을 Rust와 비교한다(Rust ≤ 150ms 근처). 2배 넘게 느리면 그 자리에서 바이트 처리를 다듬는다
4. **Review** (review 14)
5. **Store, Config** (store 4, config 4)
6. **UI:** 스파이크 B 소스에서 FFI를 걷어 낸다. 트리 마무리, 에러 화면, 빈 diff, 헤더, bench mark, 활성화(P-FOCUS)
7. **측정:** `spike/bench.sh`로 W 기준값과 같은 4개 저장소, 5라운드. 창만 찍은 스크린샷으로 화면 확인
8. **정리:** Rust 파일(`src/`, `tests/`, `Cargo.*`, `rustfmt.toml`, `bench.sh`의 Rust 경로)을 지운다. `spike/`를 지운다(bench는 `scripts/bench.sh`로 옮긴다). README, CONTRIBUTING, PRD, TASKS를 고친다

옮기는 테스트는 47개다(protocol 5, events 7은 WebView 전용이라 옮기지 않는다). 옮기지 않는 테스트가 지키던 성질 중 남는 것은 따로 테스트한다: 창을 닫으면 git 작업이 중단된다(events의 취소 테스트에 해당).

## 문서 변경
- **PRD:**
  - §11 스택: Rust + wry → Swift + AppKit
  - §7.1 구조도, §7.3 통신: `griiy://`와 이벤트 채널을 빼고 MainActor로 바꾼다
  - F-IN-4: `.app` + CLI 심링크로 확정
  - §8 메모리: 측정을 RSS 합에서 footprint 합으로 바꾼다
  - F-EX-2/3: Explain 탭만 WKWebView. 탭을 열 때 생성하고 `griiy://goto`는 navigation delegate로 받는다
  - M4-3 배포: `cargo install`을 빼고 GitHub Releases `.app` + Homebrew cask
- **TASKS:**
  - M0-4(`griiy://`), M0-5(이벤트 채널)는 "Swift 전환으로 해당 없음"으로 표시한다
  - M0-2 CI는 Swift로 바꾼다
  - M0-3는 `.app` 기준으로 다시 정의한다
  - M1-1~M1-6은 "Swift 이전 완료" 조건을 붙여 다시 연다
- **README:** 설치(`.app`/소스 빌드 `swift build`), 사용법은 그대로

## 결정이 필요한 것 (리뷰 의견 요청)
- **D1 최소 macOS:** 14 (Sonoma). `NSView.displayLink`와 Swift 6 동시성 런타임을 쓰기 위해서다. PRD에는 버전이 없다
- **D2 설정 형식:** TOML 부분 파서(약 60줄)로 갈지, `config.json`이나 plist로 바꿀지. 기본안은 TOML 유지다(README에 이미 공개했다)
- **D3 diff 파서 입력:** `[UInt8]` 전체 버퍼 + 인덱스로 할지, Swift 6.2의 `Span`/`UTF8Span`으로 할지. 기본안은 `[UInt8]`이다(단순하고 OS 제약이 없다)
- **D4 테스트 프레임워크:** Swift Testing(`import Testing`)이다. XCTest보다 표현이 Rust 테스트에 가깝고, 툴체인에 들어 있다

## 리뷰 반영 (codex, fable · 2026-10-13). 위 본문보다 우선한다

### 결정 (근거가 있는 것은 확정)
- **D1 macOS 15.** PRD §4가 이미 "macOS 15 이상"이다(14로 하면 문서가 갈라진다)
- **D2 TOML 부분 파서 유지.** 테스트가 요구하는 것만 읽는다: float 거부, bool, `[[[` 문법 오류 경고 1건, `ai = "x"`. dotted key와 inline table은 "문법 오류 경고"로 처리한다
- **D3 `[UInt8]`.** `Span`은 macOS 26 전용이다(fable 확인: `-target macos15`에서 에러). 측정(fable): 145k줄 5.7MB diff 파싱은 Rust 5ms, Swift `[UInt8]` 12~18ms, Swift `String` 110~300ms
- **D4 Swift Testing.** `swift test`로 동작한다. 기본이 병렬이므로 임시 저장소 이름에 pid와 카운터를 쓴다. 설정 루프 테스트는 `arguments:`로 쓴다

### 동작 보존 (Rust와 같게)
- **정수 트랩:** Swift는 overflow에서 크래시한다(Rust release는 감싼다). 줄 번호 카운터는 `Int`로 쓰고, hunk 헤더 값으로 `reserveCapacity`하지 않는다. 회귀 테스트로 `@@ -4294967290,1 +1,100 @@` + context 100줄을 넣는다
- **`-C` 경로는 바이트 그대로 둔다.** `CommandLine.unsafeArgv`의 바이트를 posix_spawn에 C 문자열로 넘긴다(`repo_flag` 테스트 유지). 범위 인자는 UTF-8이어야 한다
- **`Git.run`:**
  - `posix_spawnp` + `POSIX_SPAWN_SETPGROUP` + `POSIX_SPAWN_CLOEXEC_DEFAULT`로 띄운다. env는 `environ`을 상속하고 고정 값을 덮어쓴다
  - stdout/stderr를 두 스레드에서 drain하고, 종료는 blocking `waitpid`로 기다린다. 취소는 `kill(-pgid, SIGKILL)`이다
  - 자기 그룹에 있으므로 앱이 종료돼도 git은 죽지 않는다. 창 닫힘과 `applicationShouldTerminate`에서 명시적으로 kill한다
- **`Review.open` 취소:** 취소 토큰(`OSAllocatedUnfairLock<pid_t?>` + 취소 플래그)을 받는다. 매 spawn 전에 확인하고, 취소되면 현재 그룹을 죽인다(rev-parse → resolve → merge-base → diff가 순차라서)
- **스토어 키는 바이트 단위로 동일하다:** GitHub 소문자화, `%XX`, FNV-1a, 200바이트 절단. 저장소 경로는 `realpath(3)`로 정규화한다(`URL.resolvingSymlinksInPath()`는 `/private`를 떼어 해시가 달라진다, fable 확인). golden 테스트는 `tests/store.rs::keys`를 그대로 옮긴다
- **저장:** Rust와 같은 순서로 쓴다. 임시 파일을 `O_CREAT|O_EXCL`로 만들고 → write → fsync → rename → 디렉터리 fsync. `Data.write(.atomic)`에는 fsync가 없다. 읽기는 딕셔너리가 아니거나 `version`이 다르면 백업하고 새로 시작한다(`[1,2]` 같은 배열도 손상으로 본다)

### 동시성
- `Review.open`은 blocking이므로 cooperative pool(`Task`)에서 돌리지 않는다. `Thread`에서 열고 `MainActor`로 넘긴다
- UI 타깃은 swift-tools 6.2의 `.defaultIsolation(MainActor.self)`를 쓴다. 스파이크의 전역 `let`(NSFont, paragraph style)은 Swift 6에서 바로 에러가 나므로 고친다

### 크래시 금지 검사
- swift-format 규칙 `NeverForceUnwrap`, `NeverUseForceTry`, `NeverUseImplicitlyUnwrappedOptionals`를 켠다(`as!`까지 잡는다). 테스트는 `Tests/.swift-format`에서 끈다
- grep으로는 `fatalError|precondition|unsafelyUnwrapped`만 검사한다(`!`는 `!=` 때문에 grep할 수 없다)
- 빌드는 `-Xswiftc -warnings-as-errors`로 한다(clippy `-D warnings`에 해당)
- 스파이크 코드의 `contentView!`·`try!`·`fatalError()` 27건을 정리하고, `init?(coder:)`는 `nil`을 돌려준다

### 테스트
- 옮기는 수는 47개다. 단 WebView 경계용 JSON 테스트 6개(review.rs의 `json_*`, `first_paint_*` 4개, diff.rs `row_count_matches_rows`의 JSON 비교)는 **네이티브 행 모델로 의미를 바꿔** 옮긴다. `<100KB` 조건은 버린다(주입 경계가 없다). 행 창 정확성(`rows(from:n:)` = 전체의 조각)과 행 수 일치는 유지한다
- events에서 남길 성질은 "요청 취소"와 "창 닫힘 시 전체 취소"다. 손자 프로세스가 파이프를 쥐고 있는 경우까지 포함하며, 2단계로 앞당긴다. ready 큐와 JS 이스케이프 테스트는 버린다
- 실제 AppKit 종료 타이밍은 smoke 테스트 하나로 확인한다: 앱을 실행하고 창을 닫았을 때 git 손자가 남지 않는지

### 행 모델
- UI는 JSON 청크 캐시 대신 구조체에서 직접 행을 만든다. 파일과 hunk의 누적 행 수로 `row(r)`를 이진 탐색한다
- 성능 예상(fable 실측): NSTableView 15만 고정 행에서 실행 → 첫 displayLink 틱이 225~360ms다. `reloadData`는 1ms, 행 뷰는 40개다. git + 파싱은 창 생성과 병렬이므로 첫 화면 250~400ms(< 466ms)로 예상한다. 파싱 모델의 RSS는 +20MB다
- 3단계의 "성능 확인"은 답이 나왔으므로 뺀다. 7단계 측정은 그대로 둔다

### CI와 번들
- CI는 `macos-latest`(macOS 26, Xcode 26.x, Swift 6.2 이상)다. 로컬 Swift 6.4 전용 기능은 쓰지 않는다. 첫 단계에서 `swift --version`을 출력한다. swift-format은 툴체인 내장을 쓴다
- `scripts/bundle.sh`: `griiy.app/Contents/MacOS/griiy` + Info.plist(`LSMinimumSystemVersion` 15.0, `NSHighResolutionCapable`) + `codesign -s -`(ad-hoc). 설치는 `/usr/local/bin/griiy`를 `.app/Contents/MacOS/griiy`로 가리키는 심링크다. Developer ID 서명·공증·universal은 M4-2에 남긴다

### 순서 (수정)
1. 골격 + CI + 테스트 지원
2. **Git.run과 취소(손자 포함) + 스토어 키 golden** + Args + Error
3. Diff 파서 (+ 정수 트랩 회귀)
4. Review (+ 취소 토큰)
5. Store, Config
6. UI
7. 측정
8. 정리와 문서

## 결과 (2026-10-13)
- 코어·UI를 모두 Swift로 옮겼다. Rust 파일은 지웠다(커밋 `a97e3b8`에 있다). 테스트 52개(Rust에서 옮긴 것 + 정수 트랩, 다중 git 취소, 행 창 경계, CRLF·리터럴 문자열 설정), swift-format lint, `-warnings-as-errors` release 빌드가 통과한다
- `scripts/smoke-quit.sh`: git이 리뷰를 여는 중에 앱을 끝내면 git과 그 자식이 남지 않는다(통과)
- `.app` 568KB, 실행 파일 571KB

### 측정 (`scripts/bench.sh` 5라운드, 20회 모두 정상. 중앙값, 괄호는 WebKit 버전 W)
| 저장소 | 첫 화면 | footprint 합 | >50ms 프레임 | 최대 프레임 | 행 뷰 |
|---|---|---|---|---|---|
| 작은 diff (926행) | 182ms (465) | 54MB (106) | 0/590 | 17ms | 39 |
| big120k (15만 행, 300파일) | 299ms (466) | 92MB (159) | 0/590 | 17ms | 39 |
| one120k (12만 행, 1파일) | 232ms (483) | 83MB (140) | 0/590 | 17ms | 39 |
| bigtree (1만 파일) | 182ms (485) | 54MB (103) | 0/590 | 17~46ms | 39 |

### 구현 리뷰에서 고친 것
- codex: 취소 토큰이 병렬 git(ls-files, diff) 중 하나만 기억하던 문제 → 그룹 집합. 음수 `rows(from:)`에서 overflow 트랩 → 창을 잘라 낸다
- fable: 실제 git 출력 127개에서 Rust 파서와 100% 일치, 퍼징 5,000건 크래시 0, 취소 150회·실행 1,000회에서 fd 누수·좀비 0, 저장 키 바이트 동일을 확인했다. 고친 것은 CRLF 설정 파일과 작은따옴표 문자열을 못 읽던 문제, `parse` 이름 충돌(`parseDiff`/`parseArgs`), `Drain`과 `Background` 통합, errno 읽는 순서
- ponytail: 직접 만든 도우미 2개를 표준 함수로 바꿨고, 테스트 전용 이니셜라이저와 상태 글자 사전을 지웠다
- Rust와 달랐던 점: 시작 시 `config.toml` 경고를 출력하지 않았다 → 고쳤다
