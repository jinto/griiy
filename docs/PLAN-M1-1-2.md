# 계획: M1-1 인자 파싱 + M1-2 Review 정규화

> TASKS M1-1(F-IN-1, F-IN-2), M1-2(F-IN-3). 하나의 diff로 처리한다. `Review`가 base/head를 받지 않으면 범위 파싱을 끝낼 수 없기 때문이다.

## 현재 상태
- `main.rs`: `args().nth(1)`이 저장소 경로다. `Review::open(dir)`
- `git.rs` `Review`: 정적 `DIFF_HEAD`/`SHOW_HEAD`, 깨끗한 트리면 `git show HEAD`로 폴백(스파이크 의미)
- `resolve(repo, rev)`는 이미 있다 (`rev-parse --verify --end-of-options <rev>^{commit}`, 실패 시 `BadRange`)
- README, `bench.sh`가 `griiy <repo>` 형태로 호출한다

## 설계

### 1. 파싱: `src/args.rs` (새 모듈, M2에서 PR URL/`#n`이 같은 자리에 붙는다)
```rust
pub enum Spec {
    /// `griiy` or `griiy <rev>`: <rev> (default HEAD) vs the working tree, index included.
    WorkTree { base: String },
    /// `a..b` (endpoints) or `a...b` (merge_base = true). Empty side = HEAD, as in git.
    Range { base: String, head: String, merge_base: bool },
}
pub struct Args { pub repo: PathBuf, pub spec: Spec }
pub fn parse(args: impl IntoIterator<Item = String>) -> Result<Args, String>
```
- `-C <dir>`(위치 무관, 한 번만), 위치 인자 최대 1개
- `...`이 먼저: `a...b` → 첫 `...`에서 분리. 아니면 첫 `..`에서 분리
- 빈 쪽은 `HEAD` (`main..` = `main..HEAD`, `..b` = `HEAD..b`). 양쪽 다 비면(`..`, `...`) 사용법 에러
- 단일 rev `griiy main` → `WorkTree { base: "main" }` (= `git diff main`, "git과 같음" 원칙)
- `-`로 시작하는 알 수 없는 인자, 위치 인자 2개 이상, 값 없는 `-C` → `Err(usage)`
- **사용법 에러는 터미널(stderr + exit 2)**, 창을 띄우지 않는다. 범위가 존재하지 않는 경우(`BadRange`)는 F-IN-5대로 창에 표시한다
- `#n`, URL은 M2 몫이다. 지금은 rev로 취급되어 `BadRange` 화면이 뜬다

### 2. 정규화: `git.rs`
```rust
pub enum Head { Sha(String), WorkTree }
pub struct Review { pub repo, pub base: String /* sha */, pub head: Head, pub text, pub files, pub tracked, pub git_ms }
impl Review { pub fn open(dir: &Path, spec: &Spec) -> Result<Review, Error> }
```
- `repo` = `rev-parse --show-toplevel` (지금과 같음)
- WorkTree: `base = resolve(base)`, 커밋이 없는 저장소면 `NoCommits`(기존 매핑 유지)
- Range `..`: `base = resolve(a)`, `head = resolve(b)`
- Range `...`: `base = git merge-base <sha a> <sha b>`, 공통 조상이 없으면 `BadRange { detail: "no common ancestor" }`. `head = resolve(b)`
- diff 인자는 **해석된 sha로만** 만든다: `diff --no-color --no-ext-diff <base> [<head>]`. 사용자 문자열은 `resolve`(`--end-of-options`) 밖으로 나가지 않는다
- `file_diff(id)`도 같은 인자에 `-- path`를 붙인다
- `source: &'static str` 필드는 없애고 `to_json`이 `base`, `head`(sha 또는 `"worktree"`), `label`(사용자가 입력한 스펙, 예: `main...feature`)을 내보낸다. `app.js` 헤더는 `label`을 표시한다
- `store::Source`(ref 이름 기반 키)는 M1-13에서 연결한다. 이번에는 건드리지 않는다

### 3. 결정이 필요한 것 (리뷰 의견 요청)
- **D1 위치 인자 = 범위 (PRD 우선):** `griiy path/to/repo`는 깨진다. 디렉터리인지 보고 추측하는 휴리스틱은 넣지 않는다(`src` 같은 브랜치명과 모호). README와 `bench.sh`는 `-C`로 바꾼다
- **D2 깨끗한 트리 폴백 제거 (PRD 우선):** 인자가 없으면 항상 HEAD와 작업 트리를 비교한다. 변경이 없으면 빈 diff와 "변경 없음 — 예: `griiy HEAD~1..HEAD`" 안내를 보여 준다. `a_clean_tree_shows_the_last_commit` 테스트는 이 의미로 바꾼다. `bench.sh`는 3번째 인자로 범위를 받는다(재현 가능한 측정)
- 추적되지 않은(untracked) 파일은 PRD("`git diff HEAD`")대로 포함하지 않는다

### 범위 밖 (기존 문제, 담당 작업이 따로 있음)
- rename 파일의 `file_diff`: `--name-only`가 새 경로만 주기 때문에 `-- newpath`로 받으면 추가로 보인다 → M1-3/M1-5
- `store::Source::Range`가 `..`와 `...`를 구분하지 않아 같은 키가 된다 → M1-13에서 판단

## 테스트 (먼저 작성)
- `tests/args.rs` 파서 단위 테스트: `[]`, `a..b`, `a...b`, `a..`, `..b`, `..`, `main`, `-C x a..b`, `a..b -C x`, `-C`(값 없음), `-C x -C y`, `a b`, `--foo`, `a....b`(→ `a`, `.b`: 그대로 rev로 넘기고 resolve가 판단)
- `tests/review.rs` 통합 테스트 (`tests/common` 임시 저장소, main과 feature가 갈라진 구조):
  - `main..feature`: base = main tip, head = feature tip, main에만 있는 변경이 diff에 (역방향으로) 보인다
  - `main...feature`: base = merge-base, main에만 있는 변경은 diff에 없다
  - 인자 없음: base = HEAD sha, head = WorkTree, **스테이징한 파일과 안 한 파일이 모두 `files`에 있다** (M1-2 ✓)
  - `griiy main`(feature 체크아웃 상태): base = main tip, head = WorkTree
  - orphan 브랜치와 `...` → `BadRange`
  - 없는 ref → `BadRange` (기존 `bad_range` 유지)
  - 깨끗한 트리 + 인자 없음 → 빈 `files` (D2)
  - `file_diff`가 범위 모드에서도 해당 파일 diff만 준다
- 기존 `tests/errors.rs`, `tests/protocol.rs`는 `Review::open(dir, &Spec::default())` 형태로 갱신

## 완료 조건
TASKS M1-1 ✓, M1-2 ✓ + CONTRIBUTING 검사 전체 통과(fmt, clippy `-D warnings`, test, release 빌드, `unwrap/expect` 0건) + README와 `bench.sh` 갱신 → codex, fable, ponytail 리뷰

## 리뷰 반영 (codex, fable · 2026-10-13)
D1, D2는 두 리뷰 모두 찬성했다. 아래 항목이 위 본문보다 우선한다.
- **R1 `..`, `...`**: 사용법 에러로 막지 않는다. 빈 쪽은 HEAD라는 규칙을 그대로 적용해 `HEAD..HEAD`(빈 diff)로 둔다 (git과 같음)
- **R2 `-`로 시작하는 위치 인자**는 `..`가 들어 있어도(`--output=x..HEAD`) 사용법 에러로 처리한다. 이 검사가 범위 분리보다 먼저다
- **R3 NoCommits**: `resolve`가 실패하면 `rev-parse --verify HEAD`를 확인한다. 이것도 실패하면 `NoCommits`로 바꾼다 (확인은 실패 경로에서만 하므로 시작 비용이 없다)
- **R4 merge-base**: git CLI가 출력하는 하나(`git diff a...b`와 같은 선택)를 쓴다. 공통 조상이 없을 때 git은 exit 1에 stderr가 비어 있다. 그러므로 stderr 내용과 상관없이 실패하면 `BadRange`로 바꾼다. 여러 base를 합성하는 처리는 하지 않는다
- **R5 `Review`는 `spec: Spec`를 보관한다** (M1-13에서 `store::Source`에 ref 이름을 넘기기 위해). `label`은 `to_json`에서 만든다. diff 인자는 `Vec<String>`이다. `Spec::default()`는 `WorkTree { base: "HEAD" }`다
- **R6 빈 diff 안내**: 작업 트리 모드에서 변경이 없으면 `app.js`의 빈 상태 문구를 "No changes. To see the last commit: griiy HEAD~1..HEAD"로 한다
- **R7 hint 문구**: `NotARepo`와 `BadRange`의 hint를 `griiy -C path/to/repo`로 바꾼다
- **테스트 추가**: `to_json` 형태(`base`, `head: "worktree"`, `label`, `source` 없음) · untracked 파일은 `files`에 없음 · `--output=x..HEAD`는 사용법 에러 · `a...b`의 base가 `git merge-base` 출력과 같음 · 빈 저장소의 `no_commits_yet`는 그대로 green
- **미테스트로 둠**: `-C`를 `main.rs`에서 `Review::open`으로 넘기는 배선 (파서 테스트와 `Review::open(dir)` 테스트로 양쪽을 덮는다)
- **이후 메모**: M1-13 `griiy main`과 `griiy`가 `Source::WorkTree` 키로 충돌한다 · M4 `griiy stats` 서브커맨드 검사는 범위 파싱보다 먼저 해야 한다
