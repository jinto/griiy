# 계획: M3-2 근거 ① 코드 (F-AI-2)

> TASKS M3-2. ✓ unified에서 고른 선택과 같은 범위를 파일 전체 보기에서 고른 선택이 같은 근거를 만든다

등급: 보통(사용자 코드가 프롬프트로 간다, 외부 입력은 git이 준 파일 내용뿐) → 계획 리뷰 codex + fable, 구현 리뷰 codex + fable, 마지막 ponytail-review

## 현재 상태
- `File.span(side, lines)`(M1-4)가 한쪽 선택을 base·head 양쪽 줄 범위(반열린)로 바꾼다. diff 파일과 `whole`(M1-10) 파일이 같은 범위를 준다는 테스트가 이미 있다(`WholeTests`, "M3-2 relies on it")
- `Review.whole(path)`가 head 파일 바이트를 읽는다: 커밋이면 `git cat-file blob <head>:<path>`, 작업 트리면 디스크(저장소 밖 symlink 폴더 거부, symlink는 대상 경로 글자). base 쪽을 읽는 함수는 없다
- PRD F-AI-2 ①: "선택 diff와 base/head 양쪽 주변 ±40줄". F-AI-3 인용 ID: `[code:<path>:L<a>-<b>@<base|head>]`
- 근거 모양, 프롬프트 문구, 토큰 셈은 없다(M3-5, M3-6)

## 설계

### 1. 모양 (`GriiyCore/Evidence.swift`, 새 파일. M3-3·M3-4가 같은 파일에 더한다)
```swift
/// One item sent with a question (F-AI-2), under the ID answers cite it by (F-AI-3), without brackets.
public struct Evidence: Equatable, Sendable {
    public var id: String     // "code:src/a.swift:L10-90@head"
    public var text: String   // 줄마다 "<번호>\t<글자>\n"
}

extension Review {
    /// Evidence ① for `lines` of `side` chosen in `f`, a diff file or a `whole` one: the diff lines
    /// the span covers, and base and head ±40 lines around it. Blocking (git).
    public func code(_ f: File, _ side: Side, _ lines: Range<Int>, cancel: Cancel? = nil) throws(GitError)
        -> (diff: [Line], items: [Evidence])
}
```
- `diff`: `f`의 줄 중 `oldNo ∈ span.base` 또는 `newNo ∈ span.head`. 질문 대상이라 뺄 수 없고 인용 ID도 없다(PRD에 diff용 ID가 없다). 글자로 만드는 것은 M3-5
- `items`: base 발췌, head 발췌. 각 쪽의 span을 앞뒤 40줄 넓혀 `1...줄 수`로 자른다. 빈 범위 `k..<k`(그쪽에 줄이 없는 선택)도 `k-40..<k+40`. ID의 `L<a>-<b>`는 **발췌 범위**(1부터, 닫힌). 발췌 안의 일부 줄을 인용해도 맞는 인용으로 볼지는 M3-5가 정한다
- 경로: base는 `oldPath ?? path`(rename), head는 `path`
- 쪽 빼기: 추가된 파일은 base 없음, 삭제된 파일은 head 없음, `unchanged`는 두 쪽이 같아 head만. 빈 파일, NUL이 앞 8000바이트에 있는 쪽(바이너리, `whole`과 같은 판정)도 뺀다
- 디코딩은 `Line.text`와 같이 UTF-8 lossy, `\r` 유지

### 2. 파일 읽기
- `Review.whole`의 바이트 읽기를 `func text(_ side: Side, _ path: String, cancel:) throws(GitError) -> [UInt8]`로 뽑아 둘이 같이 쓴다. base는 언제나 `git cat-file blob <base>:<path>`, head는 지금 `whole`의 코드 그대로
- diff의 blob id(`oldBlob`/`newBlob`)를 쓰지 않는 이유: 작업 트리 쪽 blob은 디스크와 다를 수 있고, unchanged 파일에는 없다. 경로 하나로 두 보기가 같은 바이트를 얻는다
- ✓가 성립하는 이유: 두 보기 모두 `span`이 같은 범위를 주고(기존 테스트), 발췌는 범위와 git이 준 바이트로만 정해진다. `diff`는 `whole`이 hunk 줄을 그대로 넣으므로 같다

## 테스트 (먼저) `EvidenceTests.swift`
- fixture: 120줄 파일 두 곳 수정(20줄 부근, 100줄 부근), 추가·삭제·rename(수정 포함)·unchanged 파일
- **✓**: 여러 선택(문맥 줄, 바뀐 블록, 삭제만, 추가만, 두 hunk를 넘는 범위, 양쪽 각각)에서 `code(diffFile, …) == code(review.whole(path), …)`
- 내용: 20줄 부근 선택 → head 발췌 `L1-…`(앞에서 잘림), 100줄 부근 → 끝에서 잘림, 줄 번호와 글자가 실제 파일과 맞는다. `diff`가 선택한 블록의 -/+ 줄
- 삭제만 고르면 head 쪽은 빈 범위 주변 발췌가 나온다
- 추가 파일 → head만, 삭제 파일 → base만, rename → base ID가 옛 경로, unchanged → head 하나
- 작업 트리: 디스크의 바뀐 글자가 head 발췌에 나온다

## 하지 않는 것
- 프롬프트 글자 만들기, 인용 ID 검증(M3-5), 토큰 셈·자르기(M3-6), UI(M3-7)
- 줄 길이·발췌 크기 상한: 미니파이된 파일이면 40줄도 클 수 있지만 M3-6이 항목별 토큰을 보여주고 뺄 수 있다
- 경로에 `:`·`]`·공백이 있을 때 ID 파싱(M3-5)

## 리뷰에 묻는 점
1. 선택 diff를 인용할 수 없는 별도 값으로 두는 것 vs 근거 항목 하나로 넣는 것
2. ID 범위를 발췌 범위로 하는 것 vs 선택 범위로 하는 것
3. unchanged 파일에서 base를 빼는 것

## 계획 리뷰 (codex + fable) 반영
위 설계보다 이 절이 우선한다.
- R1 (fable 1): **발췌를 `whole(path)`의 줄에서 만든다.** `whole`은 base의 모든 줄(사이 문맥 + hunk의 문맥·삭제 줄, 모두 `oldNo`)과 head의 모든 줄을 이미 갖는다. base 읽기, `text(side, path)` 뽑기, 바이트 쪼개기·바이너리·빈 파일 검사가 없어진다. 공개 API는 `Review.code(path, side, lines)`(= `whole(path)` + 순수 함수 `File.code(side, lines)`): 보기의 File은 경로만 넘기므로 ✓가 구조로 성립하고, 남는 조건은 두 보기의 `span`이 같다는 것(테스트). 한계: 작업 트리가 diff 뒤에 바뀌었거나 `core.autocrlf`면 base 문맥이 디스크에서 온다. 전체 보기(F-DV-5)가 이미 그렇게 보여준다
- R2 (fable 2): `diff`는 **span 안의 추가·삭제 줄만**. 문맥은 발췌에 있다. 계획대로면 사이 문맥 줄이 전체 보기에서만 들어가 두 보기가 달랐다
- R3 (fable 6): `diff`도 글자로 돌려준다(`-`/`+` 접두). M3-6이 토큰을 센다
- R4 (fable 4, codex 3): 발췌 범위 = `max(1, lo-40) ..< min(n+1, hi+40)`(반열린, `lo..<hi`는 span). ID는 닫힌 `L<lo'>-<hi'-1>`. 빈 span `k..<k`이면 `k-40 ... k+39`
- R5 (fable 3): 발췌가 비면 항목을 뺀다(파일 끝을 넘은 span에서 `L<n+1>-<n>`이 나오지 않게). 추가 파일의 base, 삭제 파일의 head, 바이너리도 이 규칙으로 빠진다
- R6 (fable 5, Q3): base 발췌의 줄 글자가 head와 같으면 base를 뺀다. `unchanged` 검사를 대신하고, hunk에서 먼 문맥 선택·순수 rename에도 맞는다
- R7 (fable 7): submodule은 `whole`처럼 throw한다(gitlink를 cat-file할 수 없다). 그대로 둔다
- R8 (Q1 둘 다): 선택 diff는 근거 항목이 아니라 질문의 일부(뺄 수 없고 인용 ID 없음). Q2 둘 다: ID는 발췌 범위. M3-5/M3-7은 ID를 오른쪽부터(`@side`, `:L`) 읽는다(codex 5)
- 받지 않음: 작업 트리 스냅샷(codex 1: R1로 두 보기가 같은 `whole`을 읽는다. 질문 사이에 디스크가 바뀌는 것은 전체 보기와 같은 한계), 순수 rename처럼 unified에 줄이 없는 경우(codex 2: 비교할 unified 선택이 없을 뿐 근거는 정상), `noNewline` 표시(codex 4: 인용 확인은 줄 번호·글자로 한다), 발췌 크기 상한(codex 6: M3-6이 항목별 토큰을 보여주고 뺄 수 있다. 상한이 필요하면 그때), 같은 문맥이 두 발췌에 겹치는 토큰(fable 8: 예산이 모자라면 M3-6에서 창 하나로)

## 구현 리뷰 (codex + fable) 반영
둘 다 정확성 문제는 없다고 했다.
- fable 2: 양쪽 줄 번호가 다른 경우가 테스트에 없었다(ID에 반대쪽 번호를 써도 통과). 삭제 뒤의 선택(head 110 = base 111 → `L71-120@base`, `L70-120@head`)을 넣었다. R6의 결과로, 위쪽에 삽입이 있고 먼 곳을 고르면 번호만 밀린 같은 글자라 head만 남는다: M3-5의 인용 검사는 이것을 전제로 한다
- fable 3: 바이너리 파일 → 항목도 diff도 없다(테스트)
- 받지 않음: 질문마다 파일 전체를 다시 읽는 비용(codex 1: 12만 줄 파일에서 `code` 33ms(release), 모델 응답에 비하면 작다), ✓ 테스트의 span 비교가 `WholeTests`와 겹침(fable 1: ✓ 그 자체이고, 삭제만·두 hunk를 넘는 모양은 `WholeTests` fixture에 없다), copy 테스트(fable 3: rename과 같은 `oldPath ?? path` 길이고 fixture를 억지로 만들어야 한다)

## ponytail-review 반영
- 한 번 쓰는 테스트 도우미 `diffFile`을 풀었다. `Evidence.swift`는 그대로
