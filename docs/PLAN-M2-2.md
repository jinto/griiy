# 계획: M2-2 fetch

> TASKS M2-2. ✓ 실행 전후 `git for-each-ref refs/heads refs/remotes refs/tags` 동일 · 재fetch(force-push)도 정상 · 공개 저장소 PR 하나로 수동 확인

등급: 위험 큼(사용자 저장소에 ref를 쓴다, 외부 값이 refspec이 된다, 네트워크) → 계획 리뷰 fable + codex, 구현 리뷰 codex + fable + ponytail

## 현재 상태
- M2-1이 `prRemote`로 remote와 소문자 `GitHubRepo`를 고르고 `.fetchFailed(remote, "…comes in M2-2")`에서 멈춘다
- `fetch(repo, remote:, refspec:)`가 있다(`--no-tags --quiet --end-of-options`). 취소를 받지 않는다
- `spawn`은 항상 `-C <repo>`를 붙이고, ENOENT를 `.gitMissing`으로 바꾼다(gh에는 틀린 말)

## 확인한 사실 (2026-10-13)
- 닫힌 PR에는 `refs/pull/<n>/merge`가 없다(cli/cli#11000). 열린 PR에만 있다. 그래서 base는 merge ref로 알 수 없고 `gh api repos/o/r/pulls/n`의 `base.sha`가 필요하다
- GitHub는 sha로 fetch를 받는다(`git fetch https://github.com/cli/cli <sha>:refs/…` 성공). 로컬 경로 remote도 된다(테스트에 쓸 수 있다)
- 명시 refspec + `--refmap=`이면 `remote.origin.fetch = +refs/pull/*/head:refs/remotes/origin/pr/*` 같은 흔한 설정이 있어도 remote-tracking ref를 건드리지 않는다. `--no-write-fetch-head`면 `FETCH_HEAD`도 안 생긴다
- `git check-ref-format 'refs/griiy/gh/%2Egithub/x%2Elock/1/head'` 통과

## 설계

### 1. base sha (`GitHub.swift`)
```swift
/// The PR's base commit as GitHub has it: the base branch tip while open, frozen once closed or merged.
func pullBase(_ pr: GitHubRepo, _ number: Int, cancel: Cancel?) throws(GitError) -> String
```
- `gh api --hostname github.com repos/<o>/<r>/pulls/<n> --jq .base.sha`. o/r는 `GitHubRepo` 검사를 통과한 값이라 경로에 그대로 넣어도 된다
- 출력은 신뢰 경계: 40자(또는 sha256 64자) 소문자 hex가 아니면 `.git(detail:)`. 이 값이 refspec의 왼쪽이 된다
- 환경: `GH_PROMPT_DISABLED=1`, `NO_COLOR=1`, `GH_HOST` 무시(`--hostname`). 토큰은 gh가 알아서 읽는다(F-PR-1 "gh 인증 재사용")
- head sha는 API 값을 쓰지 않고 fetch한 `refs/pull/<n>/head`를 쓴다(둘 사이 push 경쟁에서 실제로 받은 것이 기준)
- gh를 M2-3보다 먼저 부르게 된다. 이번에는 최소한만: 실행 파일 없음 → 새 `GitError.ghMissing`(제목 "GitHub CLI (gh) is not installed", 힌트 `brew install gh, then gh auth login`), 그 밖의 실패 → `.fetchFailed(remote: "GitHub", detail: gh stderr)`. 미로그인 전용 화면은 M2-3

### 2. spawn 일반화 (`Git.swift`)
- `run(_ program:, repo: FilePath?, …)`: `repo`가 nil이면 `-C`를 붙이지 않는다(gh는 `-C`를 모른다). ENOENT는 program이 `git`일 때만 `.gitMissing`, `gh`면 `.ghMissing`
- ponytail: 프로그램 이름으로 분기. 세 번째 도구(claude, M3)가 오면 그때 에러를 인자로 받는다

### 3. fetch (`GitHub.swift`)
```swift
/// Fetches PR `number` and its base into `refs/griiy/gh/<o>/<r>/<n>/{head,base}`; returns their shas.
func fetchPullRequest(_ repo: FilePath, remote: String, _ pr: GitHubRepo, _ number: Int, base: String, cancel: Cancel?)
    throws(GitError) -> (base: String, head: String)
```
- 한 번의 fetch에 refspec 둘: `+refs/pull/<n>/head:<ns>/head`, `+<base sha>:<ns>/base`. `+`라 force-push 뒤 재fetch도 된다
- 옵션: `--no-tags --quiet --refmap= --no-write-fetch-head --no-recurse-submodules --no-auto-maintenance --end-of-options`. F-PR-6(`refs/griiy/*` 외에는 쓰지 않음)을 지키는 옵션들이다. 객체 쓰기는 피할 수 없다
- `<ns>` = `refs/griiy/gh/<ref(o)>/<ref(r)>/<n>`. `ref()`는 `[a-z0-9_-]` 밖 바이트를 `%XX`로(이름은 이미 소문자). `.github` → `%2Egithub`, `a..b`, `x.lock`도 안전. Store의 `enc`와 달리 `.`도 인코딩한다(선행 `.`, `..`, `.lock` 금지 때문)
- 끝나고 `rev-parse --verify <ns>/head^{commit}`, `<ns>/base^{commit}`로 sha를 읽는다
- 기존 `fetch(repo, remote:, refspec:)`는 이 함수로 대체하고 지운다(다른 호출자 없음). `cancel`을 받는다

### 4. 연결 (`Review.open`)
```
case .pullRequest(let want, let number):
    let (remote, pr) = try prRemote(git(repo, ["remote", "-v"]), want, number: number)
    let shas = try fetchPullRequest(repo, remote: remote, pr, number, base: pullBase(pr, number), cancel:)
    base = merge-base(shas.base, shas.head)   // GitHub "Files changed"와 같은 three-dot
    head = .sha(shas.head)
    spec = .pullRequest(repo: pr, number: number)   // `#n`도 해결된 저장소로: 키와 라벨이 같아진다
```
- merge-base 실패(공통 조상 없음, 얕은 clone) → `.badRange(spec: label, detail: "no common ancestor")`. 기존 `...` 분기와 같은 코드라 작은 함수로 뽑는다
- `Review.spec`이 해결된 값이 되므로 `key`의 `r?.owner ?? ""` 주석은 그대로 참이 된다
- 창 머리 라벨은 `o/r#n`. "fetching…" 진행 표시는 하지 않는다(기존 `…` 헤더가 기다리는 동안 보인다)

## 테스트 (먼저)
`GitHubTests.swift`
- `refName`: `o`, `.github` → `%2Egithub`, `a..b`, `x.lock`, `-x` → 결과마다 `git check-ref-format` 통과(실제 git으로)
- `fetchPullRequest` 통합(네트워크 없음): bare "remote"(로컬 경로)에 `refs/pull/1/head`를 만들고, 사용자 저장소에 그 remote + `remote.origin.fetch +refs/pull/*/head:refs/remotes/origin/pr/*` 설정
  - 전후 `for-each-ref refs/heads refs/remotes refs/tags` 동일, `FETCH_HEAD` 없음, `refs/griiy/gh/o/r/1/{head,base}`가 기대 sha
  - force-push: remote의 `refs/pull/1/head`를 관련 없는 커밋으로 바꾸고 다시 → 새 sha
  - 없는 PR 번호 → `.fetchFailed(remote:)`
  - mutation: `--refmap=`, `--no-write-fetch-head`를 빼면 위 테스트가 실패하는지 확인
- `pullBase` 출력 검사: 정상 sha, 빈 값, 공백 섞임, `:refs/heads/x`, 대문자 → 순수 함수 `baseSha(_ out:)`로 테스트
- `Review.open` 흐름은 gh를 부르므로 단위 테스트 대신 `openPicksTheRemote`의 임시 에러 기대를 바꾼다: gh를 PATH에서 못 찾게 한 환경은 만들기 번거로우니, `Review.open`의 PR 분기를 `openPullRequest(repo, remote, pr, n, baseSha)`로 나눠 gh 다음 부분을 통합 테스트(merge-base, spec 해결, key가 URL과 `#n`에서 같음)
- 수동: 공개 저장소 PR 하나(`griiy https://github.com/cli/cli/pull/11000` in a cli/cli clone)로 열리고, 전후 `for-each-ref` 동일

## 하지 않는 것
- PR 메타데이터, 코멘트, `gh` 미로그인 안내 화면(M2-3)
- `refs/griiy` 정리(오래된 PR ref 삭제). 쌓여도 해가 없다. 요청이 오면 `griiy gc`
- fetch 진행 표시, 오프라인일 때 이전에 받은 ref로 열기

## 계획 리뷰 (fable + codex) 반영
fable이 계획한 fetch 명령을 git 2.54로 실측했다: `remote.origin.fetch` pr 매핑, `fetch.prune`, `fetch.pruneTags`, 오래된 태그·remote-tracking ref가 있어도 세 네임스페이스가 그대로이고, 두 mutation(`--refmap=`, `--no-write-fetch-head` 제거)이 예상대로 실패한다. 닫힌 PR에서도 base 선택(API `base.sha` + 로컬 merge-base)이 GitHub "Files changed"와 같다.
- R1 (둘 다 높음): `run`의 stderr 분류가 fetch·gh에 틀린 화면을 띄운다. ssh의 `Permission denied (publickey)`가 사용자 저장소 권한 에러가 된다. `fetchPullRequest`와 `pullBase`는 `.cancelled` 외 모든 `GitError`를 `.fetchFailed(remote:, detail:)`로 바꾼다(gh는 remote `GitHub`). ENOENT만 `.ghMissing`
- R2 (둘 다): `fetch.writeCommitGraph=true`면 `--no-auto-maintenance`로도 commit-graph를 쓴다(fable 실측). `-c fetch.writeCommitGraph=false`를 붙이고 mutation 테스트를 한다. 받아들이는 쓰기: 객체·팩, `logAllRefUpdates=always`일 때 `logs/refs/griiy`
- R3 (fable): `GH_FORCE_TTY`가 있으면 출력이 pager를 거친다(실측). gh 환경은 `GH_PAGER=""`, `GH_FORCE_TTY` 제거, `NO_COLOR=1`, `GH_PROMPT_DISABLED=1`
- R4 (둘 다): 얕은 clone은 fetch는 성공하고 merge-base가 실패한다. 실패 시 `rev-parse --is-shallow-repository`가 true면 detail에 shallow clone, 힌트에 `git fetch --unshallow`
- R5 (fable): gh 인증 ≠ git 인증. https fetch는 git credential helper를 쓴다. `.fetchFailed` 힌트에 `gh auth setup-git`을 넣는다. gh 404/401 별도 힌트는 M2-3
- R6 (fable): Finder 실행은 PATH에 Homebrew가 없어 `.ghMissing`이 거짓일 수 있다. 힌트에 "or not on PATH (launch griiy from a terminal)"
- R7 (codex): 에러 detail의 URL 토큰(F-PR-3). git이 이미 메시지에서 userinfo를 지운다(테스트: `https://me:secret@…` remote 실패 detail에 `secret` 없음, 직접 지우는 코드를 빼도 통과해서 지웠다). gh 에러는 api URL만 인용한다
- R8 (fable): 테스트의 `spawn`은 개발자 전역 git 설정으로 돈다. 테스트 시작에 `setenv("GIT_CONFIG_GLOBAL", "/dev/null")`, `GIT_CONFIG_NOSYSTEM=1`
- R9 (codex): 전후 비교는 세 네임스페이스만이 아니라 `refs/griiy/` 밖 모든 ref, `FETCH_HEAD`, commit-graph 경로
- R10: sha 검사는 정확히 40 또는 64자 소문자 hex, 끝 개행 하나만 허용. 404면 stdout에 JSON 본문이 오므로 이 검사가 경계다
- R11: 두 sha는 `rev-parse` 한 번으로 읽는다. 최소 git 2.29(`--refmap=` 등)를 README에 적는다
- 받지 않음: per-request 임시 ref 네임스페이스(codex 4). 같은 PR을 동시에 열면서 그 사이 force-push가 있어야 어긋나고, 그래도 둘 다 실제 PR의 커밋이다. `ponytail:` 주석으로 남긴다. `--no-prune` 류(fable이 명시 refspec에서 영향 없음 실측). 저장소 object format 대조(틀리면 fetch가 실패해 에러 화면). 부분 clone 테스트(diff가 지연 fetch를 하는 것은 기존 로컬 범위도 같다)

## 구현 리뷰 (codex + fable + ponytail) 반영
- fable·codex: PR 흐름의 gh 다음 절반을 `Review.pullRequest(repo, remote:, pr, n, base:)`로 나눠 통합 테스트(해결된 spec, 라벨 `o/r#1`, three-dot base, 키가 URL 키와 같음)
- fable: 테스트의 `setenv`는 `TempDir` 첫 생성 때 한 번만(병렬 테스트 중 `environ` 재할당 방지). 원격 PR 커밋에 태그를 달아 `--no-tags` mutation도 잡는다. `--quiet` 실패의 빈 detail에 종료 코드
- codex: 얕은 clone 문구를 "no common ancestor in this shallow clone"으로(진짜 무관한 커밋일 수도 있다)
- 테스트가 버린 remote TempDir가 먼저 지워져 "없는 PR" 경우가 사실은 "없는 저장소"를 시험하고 있었다. 고치자 fetch가 멈췄다: git이 죽으며 upload-pack에 SIGTERM을 보내고 기다리는데, 테스트 스레드에서 막혀 있던 SIGTERM이 posix_spawn으로 상속됐다. `POSIX_SPAWN_SETSIGMASK`(빈 mask)로 고쳤고 이 플래그를 빼면 테스트가 멈춘다(확인). `SETSIGDEF`도 같이 둔다(SIG_IGN도 exec로 상속)
- 받지 않음: rev-parse 실패도 `fetchFailed`로(codex 1, fetch 직후 ref가 사라지는 경우뿐), 가짜 gh를 PATH에 두는 테스트(전역 PATH 경쟁)
- ponytail: 줄일 곳 없음
