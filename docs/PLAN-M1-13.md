# 계획: M1-13 봤음 체크 (F-DV-9)

> TASKS M1-13. ✓ 로컬 범위에서 체크 → 재실행 → 유지 · 새 커밋으로 head 변경 → blob이 같은 파일만 유지

## 현재 상태
- `Store`(M0-6)는 리뷰 키와 원자적 저장이 있고, 문서는 `[String: Any]`다. StoreTests가 이미 `{"version":1,"seen":{...}}` 모양을 쓴다
- `Review.spec`은 "store key (M1-13)용"으로 남겨 두었다
- `--full-index` diff의 `index` 줄은 작업 트리 파일도 실제 blob 해시를 준다(확인). 모드만 바뀐 파일과 100% rename은 `index` 줄이 없어 blob이 nil이다

## 설계

### 1. 코어 (`Review.swift`)
```swift
extension File {
    /// The change a seen mark is for (F-DV-9): blobs and modes on both sides.
    public var version: String   // "status oldPath old..new oldMode..newMode", nil은 빈 문자열
}
extension Review {
    public var key: String       // spec + repo → Source → reviewKey. mergeBase와 작업 트리 base는 키에 없다(PRD §7.4)
    /// Indices of files whose stored mark is for the change shown now.
    public func seen(in doc: [String: Any]) -> Set<Int>
    /// `doc` with file `f`'s mark set or removed. Other paths' marks stay (R7).
    public func marking(_ f: Int, _ on: Bool, in doc: [String: Any]) -> [String: Any]
}
```
- 문서: `"seen": { path: version }`. 다른 최상위 키(M3 질문 등)는 그대로 둔다
- **blob 하나가 아니라 양쪽 blob(+모드)을 비교한다.** 이유: head가 같아도 base가 바뀌면(대상 브랜치 이동) 보여주는 변경이 다르다. head만 새 커밋으로 바뀐 경우는 그 파일의 양쪽 blob이 그대로면 유지되므로 ✓와 같다. blob이 없는 모드 변경·순수 rename도 모드/경로로 같은 변경이면 유지된다
- PRD §7.4 "항목마다 base/head sha 저장"은 봤음에서는 blob 쌍이 그 역할을 한다. 커밋 sha는 저장하지 않는다
- ponytail: 경로가 키라 type change(같은 경로의 삭제+추가 두 `File`)는 체크 하나만 기억한다

### 2. 앱 (`main.swift`, `TreeView.swift`, `DiffView.swift`)
- 리뷰를 여는 스레드에서 `Store(root: appDir()/reviews).load(key)`까지 한다. HOME이 없거나 읽기 실패면 문서 없이(nil) 진행하고 stderr에 한 줄. 문서가 없으면 `v`는 화면에만 남고 저장하지 않는다(R3: 못 읽은 파일을 덮어쓰지 않는다)
- `v`: diff에서는 커서(`jump`과 같은 규칙: 화면 안 마지막 선택 행, 없으면 맨 위 행)의 파일, 전체 보기에서는 그 파일이 diff에 있을 때만. 트리에서 파일을 고르면 그 파일 헤더 행을 선택한다(R2: 끝 쪽 파일은 스크롤이 막혀 맨 위 행이 앞 파일일 수 있다). 토글 후 즉시 `marking` → `save`(메인 스레드, 작은 파일). 저장 실패는 stderr
- 상태는 App이 `Set<Int>`로 들고, 트리와 diff에는 `isSeen: (Int) -> Bool`을 넘긴다
- 표시: 트리 잎과 diff 파일 헤더의 +/- 앞에 `✓`. 헤더에 `· k viewed`. 바뀐 행만 다시 그린다
- `⌘/` 목록에 `v` 추가
- 하지 않는 것: 체크 시 다음 파일로 자동 이동, 본 파일 접기(GitHub) — 요청 시

## 테스트 (먼저) `Tests/GriiyCoreTests/StoreTests.swift`
- 실제 저장소 `main..feature`: 파일 체크 → 저장 → `Review.open` 다시 → 모두 유지
- feature에 한 파일만 바꾸는 커밋 → 다시 열기 → 바꾸지 않은 파일만 유지
- main에 한 파일을 바꾸는 커밋(base 쪽 변경) → 그 파일만 해제 (R1)
- `a..b`와 `a...b`는 같은 키 (R9)
- 모드만 바뀐 파일, 순수 rename: 체크 → 다시 열기 → 유지
- 작업 트리: 파일 수정 후 체크 → 같은 내용이면 유지, 더 고치면 해제
- 문서의 다른 키와 다른 경로의 체크는 `marking` 후에도 남는다 · `seen`이 잘못된 타입이면 체크 없음, `marking`은 새로 만든다

## 계획 리뷰 (fable) 반영
- R1: 양쪽 blob+모드 비교 유지(head만 보면 worktree 키가 base를 무시해 `griiy`와 `griiy HEAD~2`가 체크를 공유하고, 대상 브랜치가 그 파일을 고쳐도 남는다). base 쪽 변경 테스트 추가, PRD 문구 수정
- R2 높음: 트리에서 고른 파일의 헤더 행을 선택(`scrollTo(file:)`)
- R3: 읽기 실패면 저장하지 않는다
- R4: 테스트의 모드 변경은 `chmod` 후 커밋(`commit -a`가 `update-index --chmod`를 되돌린다)
- R5: version에 status와 oldPath를 넣어 blob 없는 순수 rename·더티 서브모듈끼리 섞이지 않게
- R6/R7: 저장은 토글한 경로만 바꾼다. 오래된 항목은 남지만 무해하고(같은 변경이 돌아오면 다시 맞는다), 키를 공유하는 `a..b`/`a...b`·작업 트리 base끼리 서로의 체크를 지우지 않는다. type change는 경로 하나에 체크 하나
- R8: 상태 주인은 App, 이름 흐리게는 빼고 ✓만

## 구현 리뷰 (codex + ponytail) 반영
- codex 중간: 전체 보기 열기가 실패해 에러 메시지가 diff를 가리면 `v`가 보이지 않는 커서 파일을 체크했다 → diff도 전체 보기도 안 보이면 아무것도 안 한다
- codex 중간·낮음: 경로가 키라 같은 문자열로 디코딩되는 비UTF-8 이름 둘, type change가 체크를 공유한다 → 트리도 경로 기준이라 받아들이고 `ponytail:` 주석에 적었다
- ponytail: 줄일 것 없음
- 부수 효과: 트리에서 파일을 고르면 헤더 행이 선택되므로, 이어서 ⌘C를 누르면 그 경로가 복사된다(전에는 아무것도 복사되지 않았다)

## 수동 확인 (2026-10-13, 임시 `GRIIY_KEYS` 훅, HOME을 scratchpad로, 커밋 안 함)
- `main..feature`(3개 파일)에서 `v`, `]`, `]`, `v` → a.txt와 d/c.txt에 ✓(트리·헤더), 창 머리 `· 2 seen`, 저장 파일에 두 항목
- feature에 a.txt만 바꾸는 커밋 → 다시 실행 → d/c.txt만 ✓, `· 1 seen`
- 확인 못 함: 전체 보기에서 누르는 `v`(코드 경로는 작고 `marking`은 테스트가 덮는다)
