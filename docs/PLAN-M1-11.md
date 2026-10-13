# 계획: M1-11 검색 (F-DV-7)

> TASKS M1-11: `⌘P` 파일 퍼지 검색, `/` diff 검색(코어). ✓ 1만 파일에서 `⌘P` 응답 < 50ms · 12만 줄 diff 검색이 아직 로드 안 된 파일의 결과도 찾는다

## 현재 상태
- `Review.files`는 diff 전체를 파싱한 구조체다. "로드 안 됨"은 행 뷰가 아직 없다는 뜻일 뿐이고, 줄 텍스트는 처음부터 다 메모리에 있다. 그래서 diff 검색은 `[File]`만 훑으면 화면과 무관하게 전부 찾는다
- 트리(`TreeController.fill`)가 이미 `tracked ∪ 변경 경로` 전체 목록을 만든다. 고른 파일을 보여주는 흐름(변경 파일 → diff 스크롤, 그 외 → 전체 보기)도 트리 선택에 이미 있다
- 단축키는 `App`의 로컬 키 모니터 하나(Escape)뿐이다. 이 모니터는 텍스트 입력 중에도 Escape를 먹는다

## 설계

### 1. 코어 `Sources/GriiyCore/Search.swift` (순수 함수, 테스트 가능)
```swift
/// paths 중 query가 부분열로 들어 있는 것의 인덱스, 점수순, 최대 limit개. 동점은 원래 순서.
public func fuzzy(_ query: String, in paths: [String], limit: Int = 50) -> [Int]

public struct Hit: Equatable, Sendable { public var file: Int; public var row: Int }
/// query가 든 줄의 위치. row는 File.rows(from:n:)의 인덱스. 소문자만 쓰면 대소문자 무시(smart case).
public func search(_ files: [File], for query: String) -> [Hit]
```
- **퍼지는 PRD상 "프론트에서"였지만 코어에 둔다.** 그 문구는 WebView(JS)와 Rust 사이 왕복을 피하려던 것이고, Swift 전환으로 경계가 사라졌다. 코어에 두면 50ms 기준을 테스트로 잴 수 있다
- 퍼지 점수: 바이트(ASCII 소문자화) 부분열 매칭. 글자마다 +1, 경계(`/ _ - .` 공백 뒤, 맨 앞, 소문자→대문자) 보너스, 연속 매칭 보너스, 틈 길이만큼 감점, 매칭이 모두 basename 안이면 보너스. 매칭은 오른쪽부터 탐욕적으로 해서 basename 쪽 정렬을 선호한다. 최적 정렬(DP)은 하지 않는다
  - `ponytail:` 탐욕 매칭이라 드물게 더 좋은 정렬을 놓친다. 순위 불만이 나오면 fzf v2식 DP로
- 빈 query는 앞에서부터 limit개(원래 순서). UI는 변경 파일을 앞에 둔 목록을 넘겨서, 빈 입력이면 변경 파일이 먼저 보인다
- diff 검색은 줄 텍스트만 본다(파일 헤더·hunk 헤더 제외: 파일 이름은 `⌘P`가 맡는다). 대소문자 무시는 `range(of:options:.caseInsensitive)`. 12만 줄에서 시간을 재 보고 메인 스레드에서 입력마다 돌릴지, Enter에만 돌릴지 정한다

### 2. `⌘P` 팔레트 (`Sources/griiy/Search.swift`)
- 창 위쪽 가운데에 뜨는 오버레이 뷰: `NSTextField` + 결과 `NSTableView`(최대 50행)
- 입력이 바뀔 때마다 `fuzzy` → 표 갱신. ↑↓는 결과 이동, Enter·더블클릭은 선택, Escape·포커스 이탈은 닫기 (`control(_:textView:doCommandBy:)`)
- 선택하면 `tree.reveal(path)`: 조상 폴더를 펼치고 그 행을 선택한다. 그러면 기존 `outlineViewSelectionDidChange`가 diff 스크롤이나 전체 보기를 한다. 새 표시 경로를 만들지 않는다
  - 이를 위해 `Node`에 `parent`를 두고 `fill`에서 `path → Node` 사전을 만든다
- 메뉴 `Go to File…` ⌘P (메뉴 막대에서 발견할 수 있게)

### 3. `/` 찾기 막대
- 오른쪽 패널 위 오른쪽에 뜨는 `NSSearchField` + "3/120" 레이블. 보이는 쪽(diff 또는 전체 보기)의 `DiffController`를 검색한다
- `DiffController.find(_ query) -> Int`(개수), `step(forward:) -> Int?`(현재 번호). Hit → 전역 행(`start[file] + row`) → 그 행을 선택하고 화면 가운데로 스크롤
- Enter 다음, ⇧Enter 이전, Escape 닫고 표로 포커스. 메뉴 `Find…` ⌘F도 같은 막대를 연다
- 일치한 글자 강조는 하지 않는다. 행 선택으로 위치를 보여준다 (나중에 F-DV-6 단어 강조와 같이)

### 4. 키 처리
- 로컬 키 모니터: 포커스가 텍스트 입력(`firstResponder is NSText`)이면 아무 키도 가로채지 않는다. 그래서 검색 입력 중 Escape는 입력창이 받는다 (기존 버그도 같이 고친다)
- `/`(수정키 없음) → 찾기 막대. 나머지 단축키는 M1-12

## 테스트 (먼저 작성) `Tests/GriiyCoreTests/SearchTests.swift`
- fuzzy: 부분열 아닌 경로 제외 · basename 정확 일치가 1등 · basename 접두가 중간 일치보다 앞 · 경계 매칭(`dv` → `DiffView.swift`)이 흩어진 매칭보다 앞 · 대소문자 무시 · 빈 query는 원래 순서 limit개 · limit
- fuzzy 시간: 1만 경로(실제 저장소 모양의 깊은 경로), 1~5글자 query 각각 < 50ms (release 측정도 기록)
- search: 결과 `Hit`마다 `files[h.file].rows(from: h.row, n: 1)`의 줄이 query를 포함 · 여러 hunk·여러 파일에서 순서대로 · smart case · 빈 query는 결과 없음 · 전체 보기 `File`에서도 같은 규칙
- search 규모: 12만 줄 diff에서 마지막 파일의 줄도 찾는다(뷰 없이 코어만으로), 시간 기록
- UI는 수동 확인 + 창 스크린샷(팔레트, 찾기 막대)

## 범위 밖
- 일치 글자 강조, 정규식, 단어 단위 검색
- 파일 내용 전체 검색(diff 밖 파일): PRD 범위 아님
- 나머지 단축키(`] [ n p ? v ⌘/`)와 Return으로 열기: M1-12
