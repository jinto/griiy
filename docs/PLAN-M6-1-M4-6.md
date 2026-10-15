# 계획: M6-1 Bitbucket PR + M4-6 비교 대상 고르기

> 사용자 요청 (2026-10-15): Finder로 열면 "No changes"에서 멈춘다. 앱 안에서 브랜치나 PR(GitHub, Bitbucket)을 고르고 싶다. Bitbucket까지 한 번에.
> TASKS M6-1(v0.2에서 당겨 옴): ✓ 응답 fixture 테스트, fork 삭제·권한 없음·force-push 처리, 실제 PR 수동 확인
> 새 M4-6: ✓ 앱만으로(터미널 없이) 브랜치 비교, GitHub PR, Bitbucket PR을 열 수 있다

등급: 위험 큼(새 외부 API 응답 파싱, 비밀값을 키체인에 저장, 응답 값이 refspec과 ref 이름이 된다) → 계획 리뷰 codex + fable, 구현 리뷰 codex + fable, 마지막 ponytail-review

## 현재 상태
- `Spec.pullRequest(repo: GitHubRepo?, number:)`. `pullRequest(_:)`가 github.com URL과 `#n`을 읽는다. `prRemote`가 `git remote -v`에서 GitHub remote를 고른다
- GitHub PR은 `gh`로 base sha(REST)와 PR 정보(GraphQL)를 받고, `refs/pull/<n>/head`와 base sha를 `refs/griiy/gh/<owner>/<repo>/<n>/{head,base}`로 fetch한다. diff는 merge-base…head
- ⌘O(새 창)는 griiy를 `-C <폴더>`로 다시 실행하고, 리뷰가 없는 창(오류 화면)은 닫는다. 같은 길로 다른 인자도 넘길 수 있다
- 키체인 코드는 아직 없다(PRD F-PR-3에 규칙만). GriiyCore는 Foundation만 쓴다
- 회사 저장소 예: `git@bitbucket.org:locomotivelabs/lxp_services_ai.git`(SSH)

## 확인한 사실
- Bitbucket Cloud app password는 2025-09-09부터 새로 만들 수 없고 2026-06 이후 끊겼다. 지금 API 인증은 **Atlassian API token**(scope 지정)을 Basic `email:token`으로 보낸다. 토큰은 사람 하나에 하나라 workspace별이 아니다
- Bitbucket Cloud는 `refs/pull/*` 같은 PR ref를 광고하지 않는다. SHA로 fetch(`allowReachableSHA1InWant`)는 Cloud 문서에 없고 커뮤니티에 실패 보고가 있다. 이 셸에서 회사 저장소로 직접 시험은 하지 못했다(ssh 인증은 되지만 이 저장소 권한이 없는 키). → **브랜치 이름으로 fetch**하고, 받은 tip이 API의 commit hash로 시작하는지 본다
- API 응답의 `source.commit.hash`/`destination.commit.hash`는 12자 짧은 hash다
- **Finder에서 띄운 앱의 PATH는 `/usr/bin:/bin:/usr/sbin:/sbin`**이다. git은 Xcode shim으로 찾지만 `/opt/homebrew/bin/gh`는 못 찾는다(지금 `.ghMissing` 안내가 "터미널에서 띄우라"고 한다). 고르기 시트의 사용자가 바로 이 경우다

## 설계

### 1. 호스트를 가진 저장소 (`Args.swift`, `GitHub.swift`)
```swift
public enum Host: String, Sendable { case gitHub = "gh", bitbucket = "bb" }
/// owner/name on a host, lowercased (both hosts ignore case in URLs). Same character rules as now.
public struct HostedRepo: Equatable, Sendable { public let host: Host; public let owner, name: String }
public enum Spec { …; case pullRequest(repo: HostedRepo?, number: Int) }
```
- `GitHubRepo` → `HostedRepo`(이름만 바꾸고 `host` 추가). 글자 검사는 같다: Bitbucket workspace·repo slug는 `[a-z0-9_.-]`라 `owner`에 `_`, `.`를 더 허용(Bitbucket만)
- URL: `https://bitbucket.org/<ws>/<repo>/pull-requests/<n>[/…][?…][#…]`
- remote URL: `bitbucket.org`, `altssh.bitbucket.org`(포트 443)도 GitHub와 같은 파서에 호스트 표만 늘린다
- `#n`: remote 중 PR 호스트가 하나뿐이면 그 호스트. GitHub와 Bitbucket이 다 있으면 지금처럼 upstream → origin 순으로 고르고, 그래도 둘이면 `noRemote(nil)`
- ref: `refs/griiy/<gh|bb>/<owner>/<name>/<n>/{head,base}`. 저장 키: `bb-<ws>-<repo>-<n>`(PRD §7.4, Store에 `bitbucket` case)

### 2. Bitbucket API (`Bitbucket.swift`, 새로)
```swift
public struct BitbucketAuth: Sendable { public var email, token: String }
/// GET https://api.bitbucket.org/2.0/<path>, Basic auth. Blocking; `cancel` cancels the task.
func bitbucketGet(_ path: String, auth: BitbucketAuth?, cancel: Cancel?) throws(GitError) -> Data
```
- `URLSession`(ephemeral, 캐시·쿠키·자격증명 저장 없음, 타임아웃 30초)을 세마포어로 기다린다. 호스트는 `api.bitbucket.org` 고정. 리다이렉트는 따라가지 않는다(Authorization이 다른 호스트로 가지 않게)
- 상태: 401/403 → `.bbAuth`(인증 필요, 새 GitError), 404 → `.noRemote`류 "PR이 없거나 볼 권한 없음", 그 밖 → `.fetchFailed(remote: "Bitbucket", detail: 응답의 error.message)`
- PR: `repositories/<ws>/<repo>/pullrequests/<n>` → title, description(`summary.raw`), author.display_name, state(OPEN/MERGED/DECLINED/SUPERSEDED), links.html.href, source{branch.name, commit.hash, repository.full_name}, destination{같음}. `PullRequest`에 담는다: comments·threads·issues는 비움(M6-2)
- 목록(M4-6): `pullrequests?state=OPEN&pagelen=50&fields=…` 한 페이지
- 모양은 fixture JSON으로 테스트(실제 응답 형식). 순수 함수 `decodeBitbucketPR(status:, body:)`

### 3. fetch (`Bitbucket.swift`)
- 같은 저장소 PR: 찾은 remote에서 `+refs/heads/<src>:<ns>/head`, `+refs/heads/<dst>:<ns>/base`. GitHub와 같은 옵션(`--no-tags --refmap= --no-write-fetch-head …`, `--end-of-options`)
- fork PR(`source.repository.full_name` ≠ 대상): remote URL의 모양(scp형/ssh/https)을 그대로 두고 경로만 fork로 바꾼 URL에서 src를 받는다. dst는 remote에서
- 브랜치 이름은 응답에서 온 값이다: `git check-ref-format --branch`를 통과해야 하고 `-`로 시작하면 거부(→ `.git` 에러)
- force-push: 받은 head가 API의 `source.commit.hash`로 시작하지 않으면 API를 한 번 더 부르고 다시 비교, 그래도 다르면 받은 head를 쓰고 헤더에 "PR이 방금 바뀜"을 띄우지 않는다(GitHub와 같이 받은 것을 보여준다)
- source 브랜치가 지워짐(병합 후 삭제, fork 삭제): fetch가 `couldn't find remote ref`로 실패 → `.fetchFailed`에 "PR의 브랜치가 지워졌다. 병합된 PR은 병합 커밋으로 보라: griiy <merge>^1..<merge>" 안내(응답의 `merge_commit.hash`가 있으면 그 값으로)
- diff는 GitHub와 같이 merge-base(base, head)…head

### 4. 비밀값 (`griiy/Keychain.swift`, 앱 쪽)
- 우선순위 F-PR-3: 환경변수 `BITBUCKET_EMAIL` + `BITBUCKET_API_TOKEN` → 키체인 service `griiy`, account `bitbucket`(PRD는 `bitbucket:<workspace>`였지만 API token은 사람 단위라 하나. PRD를 고친다). 값은 `email\ntoken` 한 항목
- `SecItemAdd/CopyMatching/Update/Delete`, `kSecClassGenericPassword`, `kSecAttrAccessibleAfterFirstUnlock`. Developer ID 서명이라 재빌드 후에도 같은 앱이다(M4-2 R8)
- 키체인 거부 → 이번 실행만 메모리에 두고 그 사실을 표시(F-PR-3)
- 화면: `.bbAuth`이면 오류 화면 대신 입력 카드(시트): 이메일, `NSSecureTextField` 토큰, 토큰 만드는 곳 링크(`https://id.atlassian.com/manage-profile/security/api-tokens`, scope: `read:pullrequest:bitbucket`, `read:repository:bitbucket`), 저장 → 그대로 다시 연다. 로그·화면·프롬프트에 토큰을 넣지 않는다. 바꾸기·지우기는 같은 시트(⌘, 설정 화면은 없으니 메뉴 "Bitbucket Account…")
- 코어는 `BitbucketAuth?`만 받는다: `Review.open(dir, spec, bitbucket:, cancel:)`

### 4½. 실행 파일 찾기 (`Git.swift`의 `spawn`)
- 이름으로 찾을 때 PATH에 없으면 `/opt/homebrew/bin`, `/usr/local/bin`도 본다. gh와 나중의 claude(M3)가 Finder 실행에서도 돈다. `.ghMissing` 안내에서 "터미널에서 띄우라"를 뺀다

### 5. 비교 대상 고르기 (`griiy/Compare.swift`, 새로) — M4-6
- 메뉴 File → "Compare…" ⌘K. 시트 하나, 위에 탭 두 개
  - **Branches**: `git for-each-ref --sort=-committerdate --format=%(refname:short)%00%(committerdate:relative)%00%(subject) refs/heads refs/remotes` (`*/HEAD` 제외). 위에 base 팝업(기본: `origin/HEAD`가 가리키는 것, 없으면 `main`/`master` 중 있는 것), 아래 목록에서 head를 고르면 `base...head`. 입력 칸으로 거르기
  - **Pull Requests**: remote 호스트를 보고 GitHub면 `gh pr list -R <owner/repo> --state open --limit 50 --json number,title,author,headRefName,updatedAt`, Bitbucket이면 API 목록. 줄: `#n 제목 — 작성자 · 브랜치`. 인증이 없으면 탭 안에 §4 입력 카드를 띄울 버튼
- 고르면 ⌘O와 같이 새 griiy를 `-C <repo> <인자>`로 띄운다(`base...head`, PR URL). 지금 창에 리뷰가 없거나 바뀐 파일이 0이면 그 창은 닫는다
- 처음 열었을 때 바뀐 파일이 0이고 **터미널에서 띄운 것이 아니면**(`isatty(0)`가 거짓: Finder, 자기가 띄운 자식) 이 시트를 자동으로 띄운다(`GRIIY_MARK`일 때도 빼고). 터미널에서 깨끗한 작업 트리를 연 사람에게는 지금 안내를 그대로. "No changes" 안내 글에서 터미널 명령 대신 ⌘K를 말한다
- 목록 읽기는 스레드에서(git, gh, HTTP 모두 블로킹), 시트는 "Loading…"을 먼저 보인다

## 테스트 (먼저)
- `ArgsTests`: Bitbucket PR URL(뒤 경로·쿼리), 잘못된 모양(`/pull-requests/x`, 조각 수), 대소문자. GitHub 테스트는 `HostedRepo`로
- remote 대조: bitbucket scp형·ssh·https·altssh:443, GitHub+Bitbucket 섞인 remote에서 `#n`, 호스트 하나만일 때
- `decodeBitbucketPR`: 정상(fixture), fork, 401, 404, 이상한 브랜치 이름(`-x`, `a..b`), 필드 빠짐
- fetch: 로컬 bare 저장소를 "remote"로 써서 같은 저장소 PR·fork PR·지워진 브랜치·force-push(받은 tip ≠ API hash). API는 주입한 응답
- `Store` 키 `bb-…`
- 브랜치 목록 파싱(`*/HEAD` 제외, 기본 base 고르기)
- 키체인·시트·네트워크 실제 호출은 수동: lxp_services_ai의 실제 PR 열기, 토큰 틀림 → 입력 카드, 고르기 시트에서 브랜치·GitHub PR(griiy)·Bitbucket PR

## 하지 않는 것
- Bitbucket 코멘트·인라인 코멘트·인용 ID(M6-2)
- Bitbucket Server/DC, OAuth 앱 등록
- 같은 창에서 리뷰 바꾸기(새 창으로 연다)
- PR 목록 페이지 넘기기(열린 PR 50개까지)
- Atlassian 계정 여러 개: Mac 사용자당 하나. PRD F-PR-3의 `bitbucket:<workspace>`를 `bitbucket`으로 같은 커밋에서 고친다

## 순서
커밋 둘: **M4-6 먼저**(브랜치 탭 + GitHub PR 탭 + PATH, 이 저장소로 지금 확인할 수 있다), 그다음 **M6-1**(Bitbucket API·키체인·fetch, PR 탭에 Bitbucket). 스크린샷의 막다른 화면이 Bitbucket을 기다리지 않는다

## 리뷰에 묻는 점
1. Bitbucket fetch를 브랜치 이름으로 하는 것(SHA fetch를 시도하지 않음)과 force-push 처리
2. 토큰을 키체인 항목 하나(`bitbucket`)로 두는 것, 입력 카드를 오류 화면 대신 띄우는 흐름
3. 고르기에서 새 프로세스를 띄우는 것 vs 같은 창 다시 쓰기
4. `GitHubRepo` → `HostedRepo` 일반화의 범위

## 계획 리뷰 (codex + opus) 반영
fable은 사용 한도에 걸려 같은 요청을 opus가 맡았다. 위 설계보다 이 절이 우선한다.
- R1 (opus 1, 2, 3; Q1): **브랜치 이름으로 fetch하고 base·head를 API hash로 고정한다.** 대상 브랜치 tip을 base로 쓰면 병합된 PR은 head가 이미 base 안이라 "No changes"가 된다. fetch 뒤 API의 `destination.commit.hash`(12자)를 `rev-parse --verify --end-of-options <hash>^{commit}`로 풀어 base로, 열리지 않은 PR(MERGED/DECLINED/SUPERSEDED)은 `source.commit.hash`도 풀어 head로(브랜치가 재사용됐을 수 있다). 안 풀리면 받은 tip. SHA fetch는 12자로는 할 수 없고(want는 전체 hash) 브랜치 fetch로 충분해서 시도하지 않는다 → 사용자 탐침이 필요 없다. force-push 재조회(§3)는 뺀다
- R2 (opus 4, codex 1): 브랜치 이름 검사는 `git check-ref-format refs/heads/<name>` + `-` 거부. 로컬 ref 이름은 지금 `prRefs`의 인코더를 두 호스트가 같이 쓴다(`refs/griiy/<gh|bb>/…`). fork의 `source.repository.full_name`도 `HostedRepo`로 검사
- R3 (codex 6): fork는 remote URL을 문자열로 고치지 않는다. 같은 remote의 모양(scp/ssh/https)으로 `HostedRepo`에서 새로 만든다: `git@bitbucket.org:<ws>/<repo>.git` 또는 `https://bitbucket.org/<ws>/<repo>.git`. 사용자 정보·포트는 옮기지 않는다
- R4 (opus 5, codex 7): 응답 모델에서 `source.repository`, `source.commit`, `author`, `merge_commit`은 없을 수 있다. 저장소가 없으면 "브랜치/fork가 지워졌다" 오류, 작성자 없으면 "ghost". 병합 커밋은 안내 글에만
- R5 (opus 6): 인증 카드는 저장된 자격이 없을 때의 401/403/404, 또는 401일 때만. 자격이 있는데 403/404면 오류 화면("토큰 scope가 모자라거나 저장소 권한이 없다")으로, 카드가 되풀이되지 않게
- R6 (opus 7, codex 2): HTTP는 `AI.swift`의 `askApi` 모양을 따른다(리다이렉트 거부, `cancel.onCancel { task.cancel() }`, 분리된 스레드에서 세마포어, 주입한 `URLSessionConfiguration`으로 URLProtocol 테스트, `hidden()`으로 오류 글에서 토큰 지우기). `.ephemeral`, `urlCredentialStorage = nil`. 쿼리는 `URLComponents`로
- R7 (opus 8, codex 4): `spawn`이 자식 환경에서 `BITBUCKET_API_TOKEN`, `BITBUCKET_EMAIL`을 지운다. 토큰은 argv에 넣지 않는다(curl 없음). API 오류 글은 자르고 토큰을 지운다
- R8 (opus 9): PATH는 시작할 때 한 번 `…:/opt/homebrew/bin:/usr/local/bin`을 **뒤에** 붙인다(§4½ 대신). git이 부르는 ssh·credential helper에도 닿고, git을 찾는 순서는 그대로
- R9 (opus 10): 브랜치 목록은 `%(refname)`으로 받아 `refs/remotes/*/HEAD`를 Swift에서 거른 뒤 줄인다(`%(refname:short)`는 `origin/HEAD`를 `origin`으로 찍는다, opus 실측)
- R10 (opus 11): `isatty` 대신 자동 띄우기 규칙: 바뀐 파일 0, 인자 없는 작업 트리, `markPath == nil`. 터미널 사용자는 Esc로 닫는다(⌘O의 자식이 tty를 물려받아 `isatty`가 틀린다)
- R11 (opus 12, codex 6, 8): `#n`에서 GitHub와 Bitbucket 저장소가 둘 다 후보면 `noRemote(nil)`(URL을 넘기라는 안내). `noRemote`·`fetchFailed`·`permissionDenied`의 제목·안내를 호스트별로. `Store.Source`에 `bitbucket`, `Review.key`가 호스트로 갈린다(같은 번호라도 키가 다르다). `gh pr list -R github.com/<owner>/<repo>`
- R12 (opus 13): "Bitbucket Account…" 메뉴는 뺀다(401이 카드를 띄워 바꿀 수 있다. 지우기는 요청이 오면). 키체인 거부 시 메모리 보관은 F-PR-3이라 작게 둔다. ad hoc 개발 빌드는 재빌드마다 키체인이 다시 묻는다(Developer ID 배포본은 아니다)
- R13 (Q3 둘 다 아님/opus): 고르기는 새 프로세스. 같은 창 다시 쓰기(codex 9)는 받지 않는다: review·doc·seen·panel·threads·cancel을 다 되돌려야 하고 `openRepository`의 길이 이미 있다
- 받지 않음: 시도마다 임시 ref 이름공간(codex 3: GitHub와 같은 `+` 강제 갱신이고, 실패한 fetch의 낡은 ref는 R1의 API hash 고정이 쓰지 않는다. 지금 `ponytail:` 주석과 같은 한계), API hash와 받은 hash를 화면에 같이 표시(codex 5: R1로 API hash를 그대로 보여준다)

## 구현 (M4-6 앞부분: 브랜치, GitHub PR)
§5의 시트·탭·base 팝업 대신 ⌘P의 목록을 일반화한 `FuzzyList` 하나(Go 메뉴 "Compare…" ⌘K): 열린 PR 줄, "Branches, compared with <base>:" 줄, 브랜치 줄. 퍼지 검색으로 거른다. base는 고를 수 없다(기본 브랜치만, 다른 base는 CLI). 날짜·제목 열도 없다. 자동으로 띄우는 것은 첫 페인트 뒤(`tick`의 `.empty`)
- 시험 중 찾은 것: 편집 중인 `NSTextField`의 `placeholderString`을 바꾸면 편집이 끝나 목록이 닫힌다 → "Loading…"은 행으로 보인다

## 구현 리뷰 (codex + opus) 반영
- opus 1: 브랜치는 바로, PR은 네트워크를 기다린 뒤 두 번 그린다(PR 줄 "Loading pull requests…")
- opus 3: 다른 브랜치가 없으면 "No other branches"
- opus 5: PR 오류 줄은 제목만(gh 없음·로그인 안 됨이 해결책을 말한다)
- opus 6: 줄마다 "vs main"을 붙이면 "main"으로 거를 때 전부 걸린다 → 머리 줄 하나로
- opus 7: `repo.string`이 UTF-8 아닌 경로에서 손실 → `ponytail:` 주석
- codex 1: ⌘K를 열 때 전의 `onPick`을 비운다
- codex 5, opus 9: 다시 띄우는 인자(`base...head`, `#n`)가 `parseArgs`에서 그 spec이 되는지, upstream의 HEAD도 빠지는지 테스트
- 받지 않음: 요청 세대 번호(codex 1·2, opus 4: 창 하나가 저장소 하나라 늦게 온 목록도 같은 저장소의 같은 내용), `isatty`(codex 3: 계획 리뷰 R10), `-`·`#`로 시작하는 base(codex 4: 브랜치 이름은 `-`로 시작할 수 없고 base는 기본 브랜치뿐)

## ponytail-review 반영
- 줄일 곳 없음
