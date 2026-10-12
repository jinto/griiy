# 계획: M1-3 diff 파서 (F-DV-10)

> TASKS M1-3: 파일/hunk/줄 구조와 메타데이터. ✓ 실제 git 출력 fixture: rename, copy, binary, 모드 변경, 삭제, 새 파일, 개행 없음, CRLF, 공백·비ASCII·따옴표 파일명(`core.quotePath`)

## 현재 상태
- 프론트 `app.js parse()`가 diff 텍스트를 직접 자른다. 파일명은 `diff --git` 줄의 `' b/'` 뒤를 쓰므로 공백, 따옴표, rename이 깨진다
- `Review.files`는 `git diff --name-only -z`를 한 번 더 호출해 얻는다. rename이면 새 경로만 있으므로 `file_diff(id)`가 `-- 새경로`로 좁히면 rename 대신 "새 파일"이 된다 (M1-1/2 리뷰에서 나온 기존 문제)
- `api/diff?id=`는 텍스트를 돌려준다. 프론트는 아직 이 API를 쓰지 않는다 (M1-5에서 쓸 예정)

## 실제 출력에서 확인한 사실 (`-c core.quotePath=true`, git 2.x)
- 공백이 든 이름은 `---`/`+++` 줄 끝에 **TAB**이 붙는다 (`--- a/a b.txt\t`)
- 비ASCII, `"`, `\`, 제어문자가 든 이름은 C 따옴표 + 8진 이스케이프다 (`"b/new \303\251.txt"`)
- 100% rename/copy, 모드만 바뀐 경우, binary는 `---`/`+++` 줄이 없다. 이름은 `rename from`/`copy from` 줄(접두사 없음, 필요하면 따옴표)이나 `diff --git` 줄에서만 얻는다
- binary: `Binary files a/x and b/y differ`
- `\ No newline at end of file`는 바로 앞 줄에 붙는다
- CRLF: 줄 끝 `\r`이 내용에 그대로 남는다

## 설계

### 1. `src/diff.rs` (새 모듈): 순수 함수, git을 호출하지 않는다
```rust
pub struct File {
    pub old_path: Option<String>,   // None = 새 파일
    pub new_path: Option<String>,   // None = 삭제
    pub status: Status,             // Added | Deleted | Modified | Renamed | Copied
    pub similarity: Option<u8>,     // rename/copy
    pub old_mode: Option<String>, pub new_mode: Option<String>,
    pub binary: bool,
    pub hunks: Vec<Hunk>,
}
pub struct Hunk { pub old_start: u32, pub old_len: u32, pub new_start: u32, pub new_len: u32, pub section: String, pub lines: Vec<Line> }
pub struct Line { pub kind: Kind /* Context | Add | Del */, pub old_no: Option<u32>, pub new_no: Option<u32>, pub text: String, pub no_newline: bool }
pub fn parse(text: &str) -> Vec<File>
impl File { pub fn path(&self) -> &str /* new, 없으면 old */; pub fn stats(&self) -> (u32, u32) }
```
- **이름은 신뢰할 수 있는 줄부터 쓴다:** `rename/copy from|to` → `---`/`+++`(끝 TAB 제거, `/dev/null`은 None) → `diff --git`. `diff --git` 줄은 rename/copy가 아닐 때만 쓰고, 이때는 양쪽 이름이 같다. 따옴표가 없으면 `a/P b/P` 길이로 반을 가르고(`P = (len-5)/2`, 양쪽이 같은지 확인), 따옴표가 있으면 C 따옴표를 푼다
- **C 따옴표 풀기:** `\"` `\\` `\t` `\n` `\a` `\b` `\f` `\r` `\v` `\ooo`(8진 바이트). 바이트를 모은 뒤 `String::from_utf8_lossy`
- **hunk 끝은 헤더의 줄 수로 판단한다.** 그래서 내용 줄이 `diff --git`처럼 보여도 헤더로 오인하지 않는다. `diff.suppressBlankEmpty` 같은 설정으로 빈 줄이 오면 context로 본다
- **줄 번호:** context는 양쪽, Add는 new, Del은 old만 증가한다. 개수가 생략되면(`@@ -1 +1 @@`) 1이다
- **패닉 없음:** 알 수 없는 헤더 줄은 무시하고, 숫자가 깨진 hunk 헤더는 그 파일의 hunk 파싱을 멈춘다(best-effort). 테스트 밖 `unwrap` 0건 규칙을 지킨다
- `\r`은 `text`에 그대로 둔다. 표시와 줄 매핑(M1-4)이 원본 바이트와 맞도록 하기 위해서다

### 2. git 호출을 결정적으로 만든다 (`git.rs diff()`)
사용자 설정이 출력 형태를 바꾸지 못하게 옵션을 고정한다:
`-c core.quotePath=true diff --no-color --no-ext-diff --no-textconv --src-prefix=a/ --dst-prefix=b/ --no-relative --submodule=short -M -C`
- `--no-textconv`: 줄 번호가 실제 blob과 맞아야 한다 (M1-4, F-DV-5)
- `-M -C`: rename과 copy 탐지를 사용자 설정과 무관하게 켠다 (TASKS fixture에 copy가 있다). `--find-copies-harder`는 쓰지 않는다(비용)

### 3. `Review`
- `files: Vec<String>` 대신 `files: Vec<diff::File>`을 쓰고 `parse(text)`로 채운다. 그래서 `--name-only` git 호출이 하나 줄고, 파일 ID와 diff 순서가 항상 일치한다
- `file_diff(id)`는 `-- <old> <new>` 두 경로로 좁혀 rename/copy 탐지를 유지하고, 파싱 결과에서 `new_path`(삭제면 `old_path`)가 같은 항목을 돌려준다
- `api/diff?id=`는 텍스트 대신 구조(`File` JSON)를 돌려준다. 아직 이 API를 쓰는 소비자는 없다
- 프론트 표시(`app.js parse()`)는 이번에 바꾸지 않는다. 시작 시 텍스트 주입과 JS 파싱은 M1-5(지연 로딩)에서 `api/diff`로 바뀌면서 사라진다. 단 트리의 파일 목록은 지금처럼 텍스트에서 만든다

### 범위 밖
- blob id(`index` 줄, `--full-index`): F-DV-9 봤음 체크(M1-13)에서 추가한다
- 대용량 파일 접기(F-DV-10의 1MB): 표시 쪽 일이라 M1-5/M1-6에서 한다
- 단어 단위 diff: M5-2

## 테스트 (먼저 작성)
- `tests/diff.rs`
  - **실제 git 출력 fixture:** `tests/common`으로 임시 저장소를 만들고 `Review::open`(고정 옵션)이 낸 텍스트를 파싱한다. 케이스: rename(100%와 내용 변경), copy, binary(수정·추가), 모드 변경만, 삭제, 새 파일, 개행 없음(한쪽·양쪽), CRLF, 공백 이름(TAB 꼬리), 비ASCII 이름, `"`·`\`·TAB이 든 이름
  - 각 케이스에서 old/new 경로, status, mode, binary, hunk 수·범위, 줄 번호, `no_newline`, `\r` 보존을 단언한다
  - **사용자 설정 내성:** `diff.noprefix=true`, `diff.mnemonicPrefix=true`, `diff.renames=false`, `core.quotePath=false`, `diff.suppressBlankEmpty=true`, `diff.external`을 저장소 config에 넣어도 결과가 같다
  - **손으로 만든 입력:** 빈 입력, 깨진 hunk 헤더, 헤더만 있고 hunk가 없는 경우, 내용이 `diff --git`으로 시작하는 줄(`+diff --git ...`) → 패닉 없이 기대한 구조
  - 8진 이스케이프 풀기 단위 테스트 (멀티바이트, `\\`, `\"`, 깨진 이스케이프)
- `tests/review.rs`: rename된 파일의 `file_diff`가 rename으로 나온다 (기존 문제 회귀)
- `tests/protocol.rs`: `api/diff` 응답이 구조 JSON(`path`, `hunks`)이다

## 완료 조건
TASKS M1-3 ✓ + CONTRIBUTING 검사 전체 + bench 첫 화면이 이전 수준(같은 저장소에서 ±50ms) → codex, fable, ponytail 리뷰

## 리뷰 반영 (codex, fable · 2026-10-13). 아래가 본문보다 우선한다
- **R1 `file_diff(id)`는 git을 다시 돌리지 않는다.** 시작할 때 파싱한 `files[id]`를 그대로 돌려준다. 그래서 다음 문제가 모두 사라진다: 경로로 좁혀 다시 돌릴 때의 rename/copy 함정, 타입 변경(같은 경로에 블록 2개), UTF-8이 아닌 경로를 되돌리지 못하는 문제, 작업 트리 스냅샷 불일치, 메인 스레드 git 호출. `diff()`는 `open`에서만 쓴다
- **R2 경로는 표시용 문자열이다** (`from_utf8_lossy`). 파일의 정체는 ID와 blob id다. M1-10 파일 전체 보기는 경로가 아니라 blob id로 읽는다
- **R3 `diff --git` 이름:** `"`로 시작하면 C 토큰 두 개를 읽는다. 아니면 반으로 가른다. `---`/`+++`는 **TAB 꼬리를 먼저 지우고** 따옴표를 푼다
- **R4 `index <a>..<b>[ <mode>]` 줄을 파싱하고 `--full-index`를 켠다.** 그래서 blob id(M1-13, M1-10)와 모드(대부분의 파일은 이 줄에만 있고, 서브모듈은 `160000`)를 얻는다. 0으로만 된 id는 None이다. 이 줄이 없는 경우(모드만 변경, 100% rename/copy, 더티 서브모듈)도 있다
- **R5 git 옵션 추가:** `-U3`(`diff.context`), `--ignore-submodules=none`. `run()`에서 `GIT_DIFF_OPTS` 환경변수를 지운다(실측: `-U3`보다 우선한다). `GIT binary patch`가 오면 binary로 처리하고 페이로드는 무시한다. `dissimilarity index`는 무시한다. renameLimit은 git 기본값을 따른다(한도를 넘으면 git이 경고만 내고 탐지를 끈다. 파서와는 무관하다)
- **R6 copy는 `-C`(같은 diff에서 수정된 파일이 원본인 경우)만 탐지한다.** 원본이 바뀌지 않은 copy는 "새 파일"로 보인다. `--find-copies-harder`는 저장소 전체를 후보로 삼아 큰 저장소에서 비싸므로 쓰지 않는다. fixture도 이 의미에 맞춘다
- **R7 `\ No newline` 문구는 번역 대상이므로 `\` 접두사만 본다**
- **R8 타입을 줄인다:** `similarity`는 소비자가 없어 뺀다. 경로는 `path: String`(새 경로, 삭제면 옛 경로) + `old_path: Option<String>`(rename/copy일 때만)이다. JSON은 `json!`으로 직접 쓴다(새 의존성 없음)
- **R9 fixture 추가:** 빈 파일만 추가(`new file mode`+`index`만 있음), 타입 변경(파일→심링크, 블록 2개), 따옴표 이름 binary, hunk **중간**의 `\ No newline`, 작업 트리 모드, 커밋된 `.diff` 파일(내용 줄이 `+diff --git`으로 시작한다). 설정 내성 테스트는 설정 목록을 도는 루프 하나로 쓴다. 깨진 이스케이프는 패닉하지 않는 것만 확인한다
- combined diff(`@@@`)는 2점 diff에서 나오지 않으므로 지원하지 않는다

## 구현 후 메모 (코드 리뷰 반영 뒤)
- `core.quotePath` 고정은 뺐다. 파서가 따옴표 붙은 이름과 원래 이름을 모두 읽고, 설정 내성 테스트가 이 고정 없이도 통과한다. prefix 고정은 이 테스트가 잡아낸다(빼면 실패하는 것을 확인했다)
- `-M`은 뺐다. `-C`가 rename 탐지를 포함한다
- **M1-10/M1-13 주의:** 100% rename, mode만 변경, 더티 서브모듈은 `index` 줄이 없어 blob id가 None이다. 100% rename은 mode도 None이다. blob id가 필요하면 `--raw`를 함께 받거나 `ls-tree`로 보충한다
- `api/diff` 응답에서 `id`를 뺐다. id는 요청 URL에 이미 있다
- 테스트하지 않은 것: `GIT_DIFF_OPTS` 제거(환경변수가 프로세스 전역이라 in-process 테스트 불가), 서브모듈 fixture(fable이 수동으로 확인함)
- M1-5 전까지 `Review`가 `text`와 `files`를 둘 다 들고 있다. M1-5에서 `text`를 지운다. 그때까지 프론트 트리는 공백이 든 `" b/"` 경로를 잘못 보여 줄 수 있다
