# 계획: M2-3 메타데이터와 코멘트

> TASKS M2-3. `gh api`로 PR, 리뷰 코멘트, 이슈 코멘트, 연결 이슈. ✓ `gh` 응답 fixture로 파싱 테스트 · `gh` 없음/미로그인 → 안내 화면

등급: 위험 큼(외부 형식 파싱, gh가 받는 인자) → 계획 리뷰 fable + codex, 구현 리뷰 codex + fable + ponytail

## 현재 상태
- `pullBase`가 REST `repos/o/r/pulls/n --jq .base.sha`를 한 번 부르고, `baseSha`로 검사한 sha를 fetch refspec에 넣는다
- gh 실행 파일이 없으면 `.ghMissing`. 그 밖의 gh 실패는 모두 `.fetchFailed(remote: "GitHub", detail: stderr)`
- `Review`에는 PR 정보가 없다. 화면(M2-4)은 아직 없다

## 확인한 사실 (2026-10-13, gh 2.74.2)
- 미로그인(`GH_CONFIG_DIR` 빈 폴더, `GH_TOKEN` 없음): 공개 저장소도 exit 4, stderr `To get started with GitHub CLI, please run:  gh auth login`
- GraphQL 한 번(0.6–0.7s, REST `pulls/n` 한 번과 비슷)으로 제목·본문·작성자·상태·`baseRefOid`·이슈 코멘트·리뷰·리뷰 스레드(+스레드 코멘트)·`closingIssuesReferences`를 다 받는다
- `baseRefOid`는 REST `base.sha`와 같다: cli/cli#11000(닫힘), #14648, #14578, #14519(머지됨) 모두 일치
- 없는 PR: exit 1, stdout `{"data":{"repository":{"pullRequest":null}},"errors":[{"type":"NOT_FOUND",…}]}`, stderr `gh: Could not resolve to a PullRequest with the number of 10500.`
- 스레드: 오래된(outdated) 스레드는 `line`/`startLine`이 null이고 `originalLine`/`originalStartLine`과 코멘트의 `originalCommit.oid`가 남는다. `diffSide`는 `LEFT`/`RIGHT`. `subjectType`은 `LINE`/`FILE`. 탈퇴한 사용자는 `author: null`
- cli/cli#14578: 코멘트 5, 리뷰 8(본문 있는 것 2), 스레드 5, 연결 이슈 1. 응답 41KB

## 설계

### 1. 한 번의 GraphQL로 PR 전체 (`GitHub.swift`)
(리뷰 R1로 바뀜: `pullBase`는 남기고 이 호출은 fetch+diff와 동시에 돈다. 아래 설계는 리뷰 반영 절이 우선한다)
```swift
/// PR `number` as GitHub has it: what the PR panel shows and the base commit to fetch. Blocking.
func pullRequestInfo(_ pr: GitHubRepo, _ number: Int, cancel: Cancel?) throws(GitError) -> PullRequest
```
- `gh api graphql --hostname github.com -f owner=<o> -f name=<r> -F n=<n> -f query=<상수>`. owner·name은 `-f`(문자열 그대로): `-F`는 숫자처럼 생긴 로그인(`123`)을 정수로 바꾸고 `@`로 시작하면 파일을 읽는다. n은 `-F`(정수)
- 쿼리는 상수 하나. 각 연결은 `first: 100`, 스레드의 코멘트도 `first: 100`, 연결 이슈 `first: 20`. `totalCount`를 같이 받아 잘렸는지 안다
- ponytail: 페이지네이션 없음. 100개를 넘는 PR은 `truncated`로 "GitHub에서 더 보기"를 띄운다(M2-4). 필요해지면 연결별 `after:` 커서
- 파싱은 `Decodable` 구조체(GraphQL 응답 모양 그대로, private) → 공개 모델로 변환. `JSONDecoder` 실패는 `.fetchFailed(remote: "GitHub", detail: "unexpected answer from gh")`
- `base`는 `baseRefOid`를 `baseSha`(40/64자 소문자 hex)로 검사한다. refspec 경계는 그대로

### 2. 모델 (`GitHub.swift`, public)
```swift
public struct PullRequest: Equatable, Sendable {
    public var title, body, author, state, url: String   // state: OPEN/CLOSED/MERGED
    public var base: String                              // baseRefOid, checked
    public var comments: [Comment]   // 이슈 코멘트 + 본문 있는 리뷰, 시간순
    public var threads: [Thread]     // 줄 코멘트
    public var issues: [Issue]       // closingIssuesReferences
    public var truncated: Bool       // 어느 연결이든 totalCount > 받은 수
}
public struct Comment { id: Int; author, body, created: String }
public struct Thread {
    public var path: String
    public var side: Side            // 기존 Diff의 Side(.base/.head)를 LEFT/RIGHT에서
    public var lines: Range<Int>?    // 현재 diff 기준 [startLine ?? line, line+1). outdated·파일 코멘트면 nil
    public var original: Range<Int>? // originalStartLine…originalLine, 그때 커밋 기준
    public var resolved, outdated: Bool
    public var comments: [Comment]
}
public struct Issue { number: Int; repo, title, body, state: String }
```
- `author: null` → `"ghost"`(GitHub 웹과 같다). `body`는 Markdown 원문 그대로: 이스케이프·렌더는 M2-4(F-PR-5)
- 숫자 필드는 0 이하나 `startLine > line`이면 범위 nil(외부 값)
- 리뷰 스레드 안 코멘트의 `replyTo`는 버린다: 스레드 안 순서가 이미 답글 순서다

### 3. 에러
- 새 `GitError.ghAuth`: gh exit 4. 제목 "Log in to GitHub CLI", 힌트 `gh auth login`(이미 했다면 `gh auth status`). detail은 비운다
- 실행 파일 없음 `.ghMissing`(그대로), 그 밖은 `.fetchFailed(remote: "GitHub", detail: stderr)`(그대로). 없는 PR·권한 없는 비공개 저장소는 GitHub가 둘 다 NOT_FOUND라 구분하지 않는다

### 4. 연결 (`Review`)
- `Review`에 `public var pr: PullRequest?`. PR 분기에서 `pullBase` 다음에 `Background { pullRequestInfo }`를 띄우고 diff 뒤에 기다린다. 로컬 범위는 nil

## 테스트 (먼저)
`GitHubTests.swift`, fixture는 기존처럼 문자열 리터럴(cli/cli#14578 실제 응답을 줄인 것)
- 정상: 제목·작성자·상태·base, 코멘트(이슈 + 본문 있는 리뷰만, 시간순), 스레드 두 개(현재 줄 범위 하나, outdated로 `lines` nil·`original` 있음 하나), 연결 이슈
- `author: null` → ghost · `LEFT` → `.base` · `subjectType: FILE`(줄 없음) → `lines` nil
- `totalCount`가 받은 수보다 크면 `truncated`
- 거부: `baseRefOid`가 대문자/짧음/`:refs/heads/x` · `pullRequest: null`(+errors) · JSON 아님 · 필드 누락 → 모두 에러
- 에러 매핑은 순수 함수 `ghError(status:stderr:)`로: 4 → `.ghAuth`, 1 → `.fetchFailed`
- `ErrorsTests`의 에러 목록에 `.ghAuth` 추가(제목·힌트 비어 있지 않음)
- 수동: cli/cli clone에서 `griiy https://github.com/cli/cli/pull/14578`이 열린다(패널이 없으니 디버거나 로그로 `pr` 확인), `GH_CONFIG_DIR=<빈 폴더> griiy '#1'` → 로그인 안내 화면

## 하지 않는 것
- PR 패널, Markdown 렌더, 줄 옆 코멘트 표시(M2-4)
- 본문·커밋 메시지에 적힌 `#n` 언급 이슈(닫는 키워드 없는 것): 근거 수집(M3-4)에서 커밋 메시지와 함께 모은다. 지금 받는 `closingIssuesReferences`가 GitHub이 "연결 이슈"라고 부르는 것이다
- 페이지네이션, 캐시, 오프라인 열기
- 코멘트를 diff 줄에 매핑(M2-4. `lines`는 head 또는 base 파일 줄 번호라 M1-4 `span`과 맞다)

## 계획 리뷰 (fable + codex) 반영
fable 실측(cli/cli 120개 PR 스캔, rust-lang/rust 큰 PR)이 설계 둘을 바꿨다.
- R1 (fable 7, 높음): 큰 PR에서 전체 쿼리는 5–8s(rust#137944, 267KB), REST `pulls/n`은 1.3s. 그래서 **`pullBase`는 그대로 두고**, 전체 쿼리 `pullRequestInfo`는 `Background`로 fetch+diff와 동시에 돈다. 대기 시간은 둘 중 긴 쪽
  - ponytail: 두 호출 사이 force-push면 코멘트가 다른 head의 것일 수 있다(codex 3). 창이 1초 안팎이고 GitHub 웹도 같다. headRefOid 대조는 필요해지면
- R2 (fable 1 vs codex 2): 응답에 `errors`가 하나라도 있으면 gh는 exit 1이지만 stdout에 data가 온다(실측). 판정은 stdout으로: `data.repository.pullRequest`가 있으면 성공(`errors` 무시), null이면 `.fetchFailed(detail: errors[0].message)`, JSON이 아니면 stderr. codex의 "errors면 실패"는 받지 않는다: 연결 이슈 하나 때문에 PR이 안 열린다
- R3 (fable 8, codex 5): 만료·폐기 토큰은 exit 1 + `HTTP 401`. exit 4 또는 stderr의 `HTTP 401` → `.ghAuth`. 나머지(네트워크, rate limit, SSO, NOT_FOUND)는 gh의 한 줄 메시지를 detail로 보여준다. 따로 화면을 만들지 않는다
- R4 (fable 2, codex 6): `startDiffSide`, `author`, `line`류, `databaseId`는 모두 optional로 디코딩한다(단일 줄 스레드는 `startDiffSide: null`이 42%). 모르는 `diffSide`는 줄 배치 없음(`lines` nil). 모르는 state 문자열은 그대로 둔다
- R5 (fable 3): 양쪽에 걸친 스레드(`startDiffSide LEFT`, `diffSide RIGHT`)가 실제로 있다. `diffSide`의 `line` 한 줄로 둔다: M1-4 `span`이 바뀐 줄을 변경 블록 전체로 넓히므로 그 블록이 된다
- R6 (fable 4): outdated 스레드도 `line`이 있을 수 있고 그 값은 틀린다. `isOutdated || subjectType != LINE` → `lines` nil. `original` 범위는 쓰는 곳이 없어 뺀다
- R7 (fable 5): 작성 중(PENDING) 리뷰는 본인에게만 보인다. `reviews(states: [APPROVED, CHANGES_REQUESTED, COMMENTED, DISMISSED])`, 스레드 코멘트는 `state == SUBMITTED`만
- R8 (fable 6, codex 9): 코멘트 종류(`issue`/`review(state)`/`reviewComment`)와 `url`을 둔다. url이 인용 ID(F-AI-3)와 클릭 이동을 준다. 정렬은 ISO-8601 UTC 문자열 비교(같은 형식이라 시간순), 같으면 원래 순서(stable). 리뷰는 `submittedAt`
- R9 (codex 7): 범위는 함수 하나 `lineRange(start, end)`: 둘 다 > 0, start ≤ end, 아니면 nil. 0, 음수, 뒤집힘, `Int.max` 테스트
- R10 (fable 9): `pullBase` 주석의 "열린 동안 base 브랜치 끝"은 틀렸다(열린 PR 5개 모두 현재 trunk와 다름). "GitHub가 마지막으로 맞춘 base"로 고친다
- 받지 않음: stdout 크기 상한(codex 1, 관측 최대 267KB, 100개 상한이 응답을 묶는다), raw stderr 비공개(codex 4, M2-2 R7과 같다: gh 에러는 `gh: <message> (HTTP n)` 한 줄이고 토큰을 넣지 않는다), `hasNextPage`(codex 8, `totalCount > 받은 수`와 같은 뜻), 본문·커밋 `#n` 언급(codex 10, M3-4. TASKS M3-4에 적는다)

## 구현 리뷰 (codex + fable + ponytail) 반영
- codex 1·2, fable 1: 스키마에서 `reviews`, `closingIssuesReferences`, 모든 `nodes`는 nullable이다(fable이 introspection으로 확인). 부분 에러가 이 값을 null로 만들면 디코딩 전체가 실패해 R2가 무너진다. 모두 optional로 받고, null 목록이나 null 항목은 `truncated`(받은 실제 항목 수로 센다). 테스트에 넣었고, 셈을 원래대로 돌리면 실패한다(mutation)
- fable 4: 작성 중 코멘트만 든 스레드는 빈 스레드가 됐다. 그런 스레드는 뺀다
- ponytail: 정렬의 offset 동점 처리를 지웠다. Swift `sorted`는 안정 정렬이다
- 받지 않음: 실패한 fetch 뒤 남은 gh 대기/취소(codex 3, `tracked`도 같고 gh는 응답이 오면 끝난다. 창의 cancel은 gh도 죽인다(fable 확인)), 에러 우선순위(codex 4), PR 정보만 실패하면 diff는 열기(fable 2, 지금은 계획대로 열기 실패. GraphQL만 따로 rate limit에 걸리면 생긴다. M2-4에서 필요하면 `pr = nil`과 이유를 둔다), `Background`를 `pullBase`보다 먼저 띄우기(fable 3, 로그인 안 됐을 때 gh를 한 번 더 부른다)
