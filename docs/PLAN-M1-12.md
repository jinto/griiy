# 계획: M1-12 단축키 (F-DV-8)

> TASKS M1-12: `] [ n p / ⌘P ? v ⌘/`. ✓ 키마다 동작하는지 수동 체크리스트 · 입력창에 포커스가 있을 때는 단축키를 먹지 않는다

## 현재 상태
- `/`, `⌘F`, `⌘P`, Escape(전체 보기 → diff)는 M1-10, M1-11에서 이미 된다. 로컬 키 모니터 하나가 처리하고, 포커스가 텍스트 입력(`NSText`)이면 아무 키도 가로채지 않는다(✓의 두 번째 조건은 이미 성립)
- `?`(질문)는 M3, `v`(봤음)는 M1-13의 기능이다. 이번에는 키를 잡지 않는다. 각 작업이 기능과 함께 키를 붙인다
- M1-10에서 남긴 일: 트리에서 Return으로 전체 보기 열기

## 설계

### 1. 코어: 변경 블록 시작 행 (`Diff.swift`)
```swift
/// Rows (of `rows(from:n:)`) where a change block starts: an added or deleted line right after a
/// hunk header or a context line. `n`/`p` stop here.
public var changes: [Int]
```
- **`n p`는 hunk 헤더가 아니라 변경 블록 시작에 선다.** 이유: 전체 보기는 hunk가 하나뿐이라 hunk 단위로는 움직일 수 없는데, 변경 블록은 diff와 전체 보기 둘 다에서 같은 뜻이다. diff에서는 hunk마다 변경 블록이 하나 이상 있으므로 모든 hunk에 설 수 있고, 헤더 3줄 아래의 실제 변경에 바로 선다. 한 hunk에 블록이 여럿이면 더 잘게 선다
- 결과는 계산해 두지 않는다. 누를 때마다 `files`를 훑는다(12만 줄에서 수 ms, 측정해서 기록)

### 2. 이동 (`DiffController`)
```swift
/// Moves to the next (or previous) file start or change block from the cursor; false at the end.
func jump(files: Bool, forward: Bool, from: Int? = nil)
```
- 커서: `from`, 아니면 화면에 보이는 선택 행 중 마지막, 아니면 화면 맨 위 행. 스크롤만 해서 멀어진 선택은 기준이 아니다. 빈 diff면 아무것도 안 한다
- 목표 = 전역 정지 행 목록(`files`면 `start`, 아니면 `start[f] + changes`)에서 커서보다 뒤(앞)의 첫 행. 없으면 그대로(맨 끝에서 순환하지 않는다)
- 목표 행을 선택한다. 파일은 그 행을 화면 맨 위로(`scrollTo(row:)`), 변경 블록은 위 4행(diff에서는 hunk 헤더까지)을 남기고 맨 위로 둔다. 선택이 커서가 되므로 마지막 파일이 화면 아래에 걸려 스크롤이 막혀도 다음 누름이 앞으로 간다

### 3. 키 (`main.swift`의 로컬 키 모니터)
- `]` `[` `n` `p` `/`는 `asciiKey(e)`로 맞춘다(리뷰 R1). ⌘⌃가 있으면 통과. 포커스가 텍스트 입력이거나 이벤트 창이 본 창이 아니거나 시트가 떠 있으면 통과
- `] [`: 전체 보기 중이면 diff로 돌아가, 그 파일이 diff에 있으면 그 파일 시작을 커서로 움직인다(R5). `n p`: 보이는 쪽(`shown`)에서 움직인다
- 트리에 포커스가 있을 때 Return(36)·키패드 Enter(76): 고른 파일을 전체 보기로 연다(더블클릭과 같음). 폴더면 통과
- 키 모니터가 트리의 타이핑 선택(`n`으로 시작하는 파일로 이동)보다 먼저 받는다. 트리의 타이핑 선택은 `n p [ ]`로 시작하는 이름에서만 잃는다. `⌘P`가 있으니 받아들인다

### 4. `⌘/` 도움말
- Help 메뉴 `Keyboard Shortcuts` ⌘/ → 창에 붙은 시트 `NSAlert`에 키 목록. 새 뷰를 만들지 않는다
- 목록: `] [` 다음/이전 파일 · `n p` 다음/이전 변경 · `/` `⌘F` 찾기(Return 다음, ⇧Return 이전) · `⌘P` 파일로 이동 · Return 전체 보기(트리) · Escape 전체 보기 닫기 · `⌘/` 이 도움말

## 계획 리뷰 (fable) 반영
- R1 높음: `e.characters`는 한글 입력 소스에서 `n`→ㅜ(2벌식)·ᄉ(390), `/`→ᅩ(390)라 안 먹는다. `keyCode`만 보면 독일어·Dvorak이 깨진다 → `TISCopyCurrentASCIICapableKeyboardLayoutInputSource` + `UCKeyTranslate`로 번역(⇧⌥ 반영)
- R2: 재생 훅은 `keyCode`를 채우고 `characters`에 한글을 넣어 R1을 확인한다
- R3: 빈 diff에서 `start[0]` 트랩 → `guard !files.isEmpty`
- R4: 시트가 떠 있으면 모니터가 통과
- R5: 전체 보기에서 `] [`는 그 파일 위치 기준
- R6: 커서는 보이는 선택 중 마지막, 변경 블록 위 4행, 반환값 없음, Return 36/76
- R7: PRD F-DV-8 문구를 "변경 블록"으로 고친다

## 수동 확인 결과 (2026-10-13, 임시 `GRIIY_KEYS` 훅으로 keyCode 이벤트 재생, 커밋 안 함)
`griiy HEAD~2..HEAD`(10개 파일):
- `]`×2 → 파일 1, 2 시작이 맨 위·선택 · `[` → 파일 1
- `ㅜ`(keyCode 45) → 첫 변경, 위에 hunk 헤더 보임(창 스크린샷) · 다시 → 다음 파일의 첫 변경 · `ㅔ`(35) → 되돌아감
- 트리 포커스에서 Return → 전체 보기 · `n` → 파일 안 변경 · `]` → diff의 다음 파일(main.swift)
- `ᅩ`(keyCode 44, 390의 `/`) → 찾기 막대 · 거기서 `n` → 입력됨, 이동 안 함
- `⌘/` → 시트(스크린샷: 고정폭 목록) · 시트 위에서 `]` → 이동 안 함
- 마지막 파일에서 `]`×6 → 그대로(화면은 바닥에 고정, 선택만 마지막 파일)
- `griiy HEAD..HEAD`("No changes")에서 `n ] [ p` Return → 크래시 없음
- 실제 키보드로 남은 확인: 독일어 레이아웃 `⇧7` `⌥5`

## 테스트 (먼저 작성) `Tests/GriiyCoreTests/DiffTests.swift`
- `changes`: 한 hunk에 블록 둘(문맥으로 나뉨) → 두 행 · `-` 다음 `+`는 한 블록 · hunk 헤더 바로 뒤 변경 · 여러 hunk · hunk 없는 파일(바이너리) → 빈 목록 · 전체 보기 `File`에서도 같은 행 · 모든 결과 행이 `rows(from:n:)`에서 `.line`이고 kind가 add/del, 그 앞 행은 hunk 헤더나 context
- 이동 로직은 UI라 수동 체크리스트로 확인한다

## 수동 체크리스트 (창 스크린샷 + 실행 기록)
이 환경에서는 키 입력을 보낼 수 없으므로 임시 env 훅으로 키 순서를 재생해 창을 찍는다(커밋하지 않음)
1. `]` 세 번 → 세 번째 파일 헤더가 맨 위, 선택됨 · `[` → 두 번째
2. 마지막 파일에서 `]` → 그대로
3. `n` → 첫 변경 블록이 문맥 3줄 아래에 선택됨 · `p` → 이전 블록
4. 전체 보기에서 `n` → 파일 안 다음 변경 · `]` → diff로 돌아가 다음 파일
5. `/` 찾기 막대에 `n`, `]` 입력 → 글자가 입력되고 이동하지 않음 · `⌘P` 팔레트에서도 같음
6. 트리에서 Return → 전체 보기 · 폴더에서 Return → 펼침/접힘 그대로
7. `⌘/` → 시트에 키 목록

## 범위 밖
- `?` 질문(M3), `v` 봤음(M1-13), `s` 보기 전환(v0.2)
- 트리 선택을 `] [`에 맞춰 옮기기

## 구현 리뷰 반영
- codex: 폴더에서 Return을 먹던 것 → `openSelected()`가 파일을 열었을 때만 먹는다 · `UniCharCount` 빌드 실패 지적은 재현 안 됨(debug·release `-warnings-as-errors` 통과) · 타입 변경(같은 경로 두 항목)에서 전체 보기 `]`가 두 번째 항목으로 가는 것은 diff에서 `]`가 두 항목을 모두 밟는 것과 같아 그대로 둔다
- ponytail: `asciiKey(e)` 한 번만 부른다
