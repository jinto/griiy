# 계획: M2-1 URL과 `#n` 해석, remote 대조 (F-PR-1)

> TASKS M2-1. ✓ 단위 테스트: https/ssh remote, 여러 remote, 일치 없음(에러 화면), fork PR

등급: 위험 큼(외부 형식 파싱, 값이 M2-2에서 refspec과 ref 이름이 된다) → 계획 리뷰 fable + codex, 구현 리뷰 codex + fable + ponytail

## 현재 상태
- `parseArgs`는 범위 하나와 `-C`만 안다. `-`로 시작하는 인자는 거부한다
- `Source.gitHub(owner, repo, number)`와 키 `gh-<owner>-<repo>-<n>`(소문자)는 M0-6에 이미 있다
- `fetch(repo, remote:, refspec:)`는 M2-2용으로 있다
- `git remote -v`는 `url.*.insteadOf`를 적용한 URL을 보여주고, fetch URL은 `(fetch)` 줄 하나다(확인). `git config remote.*.url`은 원문이라 쓰지 않는다

## 설계

### 1. 인자 (`Args.swift`)
```swift
public enum Spec {
    ...
    /// `griiy <PR URL>` or `griiy '#n'`. `repo` is nil for `#n`: the remotes decide (M2-1).
    case pullRequest(repo: GitHubRepo?, number: Int)
}
public struct GitHubRepo: Equatable, Sendable { public var owner, name: String }
```
- 받는 URL: `http(s)://[www.]github.com/<owner>/<repo>/pull/<n>` 뒤에 `/files`, `/commits/<sha>`, `/`, 쿼리, 프래그먼트가 붙어도 된다. 호스트 대소문자 무시. 스킴 없는 `github.com/...`는 범위(rev)로 해석된다 → git이 거부 → 에러 화면. 받지 않는다
- `#<n>`: 숫자만, 1 이상, Int 범위. `#`, `#0`, `#12a`, `#-1`은 사용법 에러
- owner: `[A-Za-z0-9-]+`, repo: `[A-Za-z0-9._-]+`이고 `.`/`..`가 아니며 `.git`으로 끝나면 떼어낸다. 이 검사가 M2-2 ref 이름(`refs/griiy/gh/<owner>/<repo>/<n>/…`)의 안전 경계다. 어긋나면 사용법 에러
- 판별은 `-` 거부 다음, 범위 분리 전: `http://`·`https://`로 시작하면 URL로만 해석하고 실패하면 사용법 에러(범위로 넘기지 않는다). `#`로 시작해도 같다
- `label`: `owner/repo#n`, `#n`
- bash는 `#`를 주석으로 읽으므로 `griiy '#42'`로 따옴표가 필요하다(README에 이미 그렇게 적혀 있다). 맨 숫자 `42`는 sha 접두어와 겹쳐 받지 않는다

### 2. remote 대조 (`Git.swift` 또는 새 `GitHub.swift`)
```swift
/// The remote to fetch PR `want` from: one whose fetch URL is github.com/<owner>/<repo>.
/// `want == nil` (`#n`): the repo of the only GitHub remote, else `upstream`'s, else `origin`'s.
func prRemote(_ remotes: String, _ want: GitHubRepo?) -> Result<(remote: String, repo: GitHubRepo), GitError>
/// owner/repo of a GitHub remote URL, nil for any other host.
func gitHubRepo(remoteURL: String) -> GitHubRepo?
```
- 입력은 `git remote -v` 출력(순수 함수라 fixture로 테스트). 줄 형식 `name\turl (fetch)`, `(push)` 줄은 무시. remote 이름에는 공백·탭이 없다(refname 규칙)
- URL 형식: `https://[user@]github.com[:port]/o/r[.git][/]`, `http://`, `ssh://[git@]github.com[:22]/o/r.git`, `ssh://git@ssh.github.com:443/o/r.git`, `git://github.com/o/r`, `git+ssh://`, scp형 `[git@]github.com:o/r.git`(첫 `/` 앞에 `:`). 경로는 정확히 두 조각. 호스트 대소문자 무시
- owner·repo 비교는 대소문자 무시(GitHub 규칙, 키도 소문자). 결과 repo는 URL에서 온 표기를 쓴다(`#n`이면 remote의 표기)
- 여러 remote가 일치하면 `git remote -v` 순서의 첫 것(같은 저장소라 어느 것으로 받아도 같다)
- `#n`: GitHub remote들의 서로 다른 저장소가 하나면 그것. 여럿이면 `upstream` → `origin` 순. 둘 다 없으면 에러
- fork PR: PR은 base 저장소의 `refs/pull/<n>/head`에 있으므로 URL의 owner/repo(base 저장소)와 맞는 remote를 찾으면 된다. fork를 clone해 `origin`=fork, `upstream`=원본이면 `upstream`이 골라진다. `origin`=fork뿐이면 일치 없음
- ponytail: github.com만 안다. GitHub Enterprise 호스트와 ssh config 별칭(`github-work:o/r`)은 일치 없음이 된다. 요청이 오면 호스트를 GitHubRepo에 넣는다

### 3. 에러 (`GitError`)
- `case noRemote(want: String)`: 제목 `No remote for github.com/o/r`, 힌트 `git remote add upstream https://github.com/o/r.git, or clone it: gh repo clone o/r` · `#n`이면 `want` 대신 별도 문구: 제목 `No GitHub remote to look up #n in`, 힌트 `Pass the PR URL instead: griiy https://github.com/o/r/pull/n` (GitHub remote가 여럿인데 upstream·origin이 없을 때도 같은 화면, detail에 후보 목록)
- 두 경우를 `noRemote(want: GitHubRepo?, number: Int, detail: String)` 한 case로 둔다

### 4. 연결 (`Review.open`, `Review.key`)
- `.pullRequest`: `git remote -v` → `prRemote` → (M2-2 전까지) `.git(detail: "fetching PRs comes in M2-2")`를 던진다. 즉 이번 작업에서 PR은 에러 화면까지만 간다
- `key`: PR은 이번에 `Review`까지 가지 않으므로 키를 쓰는 곳이 없다. M2-2가 `Review`에 정해진 `pr: (GitHubRepo, Int)`를 넣고 키를 그것으로 만든다(`#n`과 URL이 같은 키). 이번 `key`의 `.pullRequest` 분기는 `repo`가 있으면 `.gitHub` 키, 없으면 작업 트리 키 — 열린 질문: M2-2까지 이 분기를 어떻게 둘지

## 테스트 (먼저)
`ArgsTests.swift`
- URL 형식들(뒤 경로·쿼리·프래그먼트·`www.`·`http`·대문자 호스트) → `.pullRequest(GitHubRepo(o, r), n)` · `r.git` → `r`
- 사용법 에러: `https://github.com/o/r/pull/`, `/pull/0`, `/pull/x`, `/issues/3`, `https://gitlab.com/o/r/pull/1`, owner·repo에 `..`·`%2e`·공백·`/`, `#`, `#0`, `#1a`, Int 넘침
- `#42` → `.pullRequest(nil, 42)` · `-C x '#3'` 조합

`GitHubTests.swift`
- `gitHubRepo`: 위 URL 형식 각각, `.git`·끝 `/` 있음/없음, 경로 세 조각·한 조각 → nil, gitlab·로컬 경로 → nil
- `prRemote`: 하나 일치 · 대소문자만 다름 · https와 ssh 두 remote가 일치 → 첫 것 · 일치 없음(에러 문구에 owner/repo) · fork(origin=fork, upstream=원본) · fork만 있음 → 에러 · `#n`: GitHub remote 하나 · origin과 upstream이 다른 저장소 → upstream · 다른 저장소 둘인데 upstream·origin 없음 → 에러 · GitHub remote 없음 → 에러 · push 줄만 다른 URL은 무시
- 통합 하나: 임시 저장소에 `git remote add` + `insteadOf` → `Review.open`이 `noRemote`/M2-2 대기 에러 중 맞는 것을 던진다(네트워크 없음)

## 하지 않는 것
- fetch, merge-base, `gh` 호출(M2-2, M2-3)
- Enterprise 호스트, ssh 별칭, 스킴 없는 URL

## 계획 리뷰 (fable + codex) 반영
- R1 (fable·codex 높음): 정규식은 ref 이름 안전 경계가 아니다(`.github`, `a..b`, `x.lock`은 refname으로 BAD). 파싱은 GitHub 이름 검사(사용법)로만 두고 `.github`는 받는다. ref 이름 안전은 M2-2가 `enc`처럼 `[a-z0-9_]` 밖을 `%XX`로 인코딩해서 지킨다
- R2 (둘 다): 검사는 `GitHubRepo.init?(owner:name:)` 한 곳. URL 인자와 remote URL이 모두 통과한다. owner·name은 ASCII 소문자로 정규화(키와 같고, APFS에서 `Foo/Bar`와 `foo/bar` loose ref가 합쳐지는 것 방지). 비교는 `==`. `%`는 문자 집합 밖이라 디코딩하지 않고 거부된다
- R3 (fable): `git remote -v`는 알파벳 순이다. URL 일치가 여럿이어도, `#n`이어도 같은 선호 `upstream → origin → 알파벳 첫 것`. `#n`은 GitHub remote 중에서만 고른다(codex: upstream이 GitLab이면 건너뜀). `#n`에서 서로 다른 저장소가 여럿이고 upstream·origin이 없으면 에러
- R4 (fable): `Review.open`이 `#n`을 해결된 `.pullRequest(repo:, number:)`로 바꿔 `Review.spec`에 넣는다(M2-2). `pr` 필드는 따로 두지 않는다. `preconditionFailure`는 M0-7 규칙상 못 쓰므로 `key`의 nil 분기는 빈 owner/repo 키(도달하지 않음, 주석)
- R5 (codex 높음): 에러 detail에 remote URL 원문을 넣지 않는다(`https://token@github.com/...`). `name → github.com/o/r` 또는 이름만
- R6: `remote -v` 줄은 첫 탭에서 자르고 끝이 ` (fetch)`가 아니면 버린다(pushurl만 있는 remote는 `name\t` 한 줄). remote 이름은 `-`로 시작할 수 있어 M2-2 git 호출에 `--end-of-options`(이미 `fetch`가 그렇다)
- R7: 임시 에러는 `.fetchFailed(remote: 고른 remote, detail: "fetching PRs comes in M2-2")`. 통합 테스트가 고른 remote를 단언할 수 있다
- R8: URL 파서는 스킴 열거 대신 `scheme://` 떼기 → userinfo 떼기 → host[:port] → 경로(scp형은 `:` 뒤). host는 전체 일치 `github.com`, `www.github.com`, `ssh.github.com`. PR URL도 `www.` 허용(codex R7)
- R10: `prRemote`는 `throws(GitError)`
- 받지 않음: 포트 검사(codex R4). 잘못된 포트의 remote를 고르면 fetch가 실패해 에러 화면이 뜰 뿐 안전 문제가 아니다. `o/r#n` 입력(`#`는 refname 문자라 범위와 모호)
- M2-3 메모(fable R9): `gh api`는 `{owner}/{repo}` 플레이스홀더 대신 명시적 `repos/<o>/<r>/pulls/<n>`. gh의 `gh-resolved`는 나중

## 구현 리뷰 (codex + fable + ponytail) 반영
- codex 중간: `scheme://`를 아무거나 받았다 → `https http ssh git git+ssh ssh+git`만(`ftp://`, remote helper는 GitHub 아님)
- codex 중간: `https://user:tok@github.com:443/…`에서 포트를 못 뗐다(비밀번호의 `:`) → userinfo를 먼저 떼고 포트
- codex·fable 낮음: PR URL의 `r.git`을 안 뗐다 → `.git` 떼기를 `GitHubRepo.init?` 한 곳으로
- codex 낮음: 번호 뒤 경로는 일부러 아무거나 받는다(GitHub PR 탭은 바뀐다). 테스트로 고정
- fable 낮음: `everyErrorExplainsItself` 목록에 `noRemote` 추가
- ponytail: 한 줄 줄임
- 받지 않음: `upstream`이 이미 다른 저장소일 때 힌트 문구(detail에 remote 목록이 같이 뜬다)
- M2-2 메모(fable): `fetch`에 `cancel:` 추가(창 닫기로 끊기). base 브랜치 이름은 `gh api`만 주므로 M2-2가 `gh api repos/o/r/pulls/n`의 `.base.ref`를 먼저 부르거나 M2-3과 순서를 맞춘다. 그 전까지 PR은 `fetchFailed` 임시 에러 화면에서 멈춘다(힌트가 네트워크를 말하지만 detail이 M2-2라고 한다)
