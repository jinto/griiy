# griiy TASKS

> PRD.md의 마일스톤을 작업으로 나눈 목록. 모든 작업에 **완료 조건(✓)** 을 적는다.
> 표기: `[ ]` 할 일 · `[x]` 완료 · (F-xx) PRD 요구사항 · ⟵ 선행 작업

## 완료 (스파이크, 2026-10-12)
- [x] Rust + wry 창에 `git diff HEAD` 표시 (깨끗하면 `git show HEAD`)
- [x] 파일 트리 초안: 전체 추적 파일, 변경 표시, 자동 펼침, 폴더 합치기
- [x] `bench.sh`: 실행→첫 페인트, 단계별 시간, RSS
- [x] tinyjs와 비교 후 Rust 채택 (docs/SPIKE-rust-vs-tinyjs.md)

---

# v0.1

> **2026-10-13 Swift 전환:** 스택을 Rust + wry에서 Swift + AppKit으로 바꿨다 (docs/PLAN-swift.md). 끝난 작업은 Swift로 옮겨 같은 테스트를 통과했다. WebView 경계에만 필요했던 M0-4, M0-5는 해당 없음으로 바꿨다. Rust 버전은 커밋 `a97e3b8`에 있다.

## M0 기반
- [x] **M0-1 오픈소스 기본 파일:** LICENSE-MIT, LICENSE-APACHE, README(설치, 사용법, 데이터 저장 위치, 외부 전송 범위), CONTRIBUTING
  - ✓ 두 라이선스 파일이 저장소 루트에 있다 · README에 PRD §7.4 저장 위치와 §8 외부 요청 목록이 있다
- [ ] **M0-2 CI:** GitHub Actions macOS 러너에서 `swift format lint`, release 빌드(`-warnings-as-errors`), `swift test`, 크래시 호출 grep, `.app` 번들, 바이너리 크기 출력
  - ✓ PR마다 돌고, 하나라도 실패하면 머지 차단
  - 진행: Swift workflow 작성 완료, 로컬에서 같은 명령 통과 (2026-10-13). 남은 일: GitHub 저장소를 만든 뒤 `main` 브랜치 보호에서 `check` 필수로 지정 (CONTRIBUTING)
- [ ] **M0-3 POC: 창 포커스와 키체인 (F-IN-4, F-PR-3)**
  - 배포 형태는 `.app` + CLI 심링크로 정했다 (Swift 전환, `scripts/bundle.sh --install`). 앱은 시작 시 `NSApp.activate()`로 앞에 나온다
  - 남은 확인: ① 심링크로 터미널에서 실행했을 때 창이 앞에 오고 키를 받는가 ② 재빌드·재서명 후 키체인 항목을 다시 묻지 않고 읽는가
  - ✓ 결과를 `docs/POC-focus-keychain.md`에 기록한다 · 포커스 smoke test(실행 → 단축키 하나 입력 → 반응 확인)를 스크립트로 만든다
- [x] ~~**M0-4 `griiy://` 프로토콜 (§7.3):**~~ Swift 전환으로 해당 없음 (WebView 경계가 없다). `app/<asset>`은 내장 자산, `api/<route>`는 JSON. 허용 목록 밖은 404. 파일은 ID로만 접근
  - ✓ 단위 테스트: `..`, URL 인코딩된 `%2e%2e`, NUL, 절대경로, 다른 ref, 비ASCII·공백 파일명(ID로는 정상) · MIME 타입 확인 · 프론트를 여러 파일로 나눠도 바이너리는 1개
- [x] ~~**M0-5 이벤트 채널 (§7.3):**~~ Swift 전환으로 해당 없음. 남는 성질(요청 취소, 창 닫힘 시 git 중단)은 `Cancel` 테스트와 `scripts/smoke-quit.sh`가 지킨다. `{v, req, type, data}` envelope, `ready` 전 큐잉, 큐 상한, 요청 ID별 취소, 창 닫힘 시 작업 중단
  - ✓ 가짜 생산자로 테스트: ready 전 100개 → 순서대로 전달 · 1만 개 폭주 → 상한 내 합쳐짐 · 취소 → 생산자 중단 · `</script>`, 줄바꿈, 따옴표가 든 데이터도 깨지지 않음
- [x] **M0-6 store (§7.4):** 리뷰 키 생성, 스키마 버전, 원자적 저장(임시 파일 → rename), 손상 파일은 백업 후 새로 시작
  - ✓ 키 생성 단위 테스트(로컬 범위·작업 트리·GitHub) · 같은 로컬 범위를 커밋 후 다시 열어도 같은 키 · 손상 JSON fixture 처리
- [x] **M0-7 에러 화면 (F-IN-5):** git 없음, 저장소 아님, 잘못된 범위, fetch 실패, 권한 없음
  - ✓ 경우마다 통합 테스트 · 앱 코드에 강제 언래핑·`try!`·`fatalError`·`precondition` 0건 (swift-format 규칙 + grep)
- [x] **M0-8 설정 (§6.6):** `config.toml` 로드, 기본값, 잘못된 값 경고
  - ✓ 없는 파일, 빈 파일, 잘못된 타입 fixture 테스트

## M1 로컬 diff 뷰 ⟵ M0-6
- [x] **M1-1 인자 파싱 (F-IN-1, F-IN-2):** `a..b`, `a...b`, 인자 없음, `-C`
  - ✓ 파서 단위 테스트 · 임시 저장소로 base/head sha가 PRD F-IN-2 표와 일치하는지 통합 테스트
- [x] **M1-2 Review 정규화 (F-IN-3):** `head: Sha | WorkTree`
  - ✓ 작업 트리 모드에서 스테이징한 변경과 안 한 변경이 모두 보인다
- [x] **M1-3 diff 파서 (F-DV-10):** 파일/hunk/줄 구조와 메타데이터
  - ✓ 실제 git 출력 fixture: rename, copy, binary, 모드 변경, 삭제, 새 파일, 개행 없음, CRLF, 공백·비ASCII·따옴표 파일명(`core.quotePath`)
- [x] **M1-4 줄 매핑 (F-AI-1 기반):** `Selection { path, side, start, end }` ↔ base/head 파일 줄 범위
  - ✓ hunk 경계, 추가만, 삭제만, 섞인 선택 fixture에서 기대한 base·head 범위가 나온다
  - 결과 (2026-10-13): `File.span(side, lines)`가 반열린 범위로 양쪽 범위를 돌려준다. 문맥 줄은 짝 줄로, 바뀐 줄은 그 변경 블록(`-`/`+` 묶음) 전체로 매핑하고, 삭제만 고르면 반대쪽은 위치를 가진 빈 범위다. `Selection` 구조체(path 포함)는 쓰는 곳이 생기는 M3에서 만든다. hunk·파일 단위는 호출하는 쪽이 범위로 넘긴다
- [x] **M1-5 지연 로딩 (§7.3):** 화면에 보이는 행만 만든다
  - ✓ (Swift) 행은 파싱한 구조체에서 `rows(from:n:)`로 창 단위로 만든다. 12만 줄 저장소에서 깊은 창이 전체의 같은 조각과 같다 (테스트). 초기 주입 데이터 기준은 WebView 경계가 사라져 해당 없음
- [x] **M1-6 가상 스크롤 (F-DV-4)**
  - ✓ scripts/bench.sh 12만 줄: 첫 화면 < 1s, 메모리(physical footprint 합) < 250MB, diff 행 뷰 < 5,000, 자동 스크롤 중 50ms 넘는 프레임 ≤ 1%
  - 결과 (Swift, 2026-10-13, 5라운드 중앙값): 15만 행에서 첫 화면 299ms, footprint 92MB, 행 뷰 최대 39, 50ms 초과 프레임 0/590 (docs/PLAN-swift.md 측정)
- [ ] **M1-7 bench 확장:** 행 뷰 수, 자동 스크롤 long-frame 집계, JSON 출력
  - ✓ CI 아티팩트로 저장 (참고용, 실패 기준 아님)
  - 진행: `scripts/bench.sh`가 첫 화면(앱 벽시계), footprint, 스크롤 프레임, 행 뷰 수를 보고한다 (2026-10-13). 남은 일: CI 아티팩트 저장
- [ ] **M1-8 파일 트리 개선 (F-DV-1):** 접힌 폴더는 펼칠 때 렌더
  - ✓ 1만 파일 저장소에서 트리 뷰 < 2,000
  - 진행: NSOutlineView는 펼친 항목의 자식만 묻는다. 1만 파일 저장소 첫 화면 182ms (2026-10-13). 남은 일: 트리 뷰 수 측정
- [ ] **M1-9 구문 강조 (F-DV-3):** 첫 페인트 후, 보이는 줄만
  - ✓ 강조 전후 bench 첫 화면 차이 < 50ms · 12만 줄 스크롤 기준(M1-6) 유지
- [ ] **M1-10 파일 전체 보기 (F-DV-5)**
  - ✓ 변경 안 된 파일, 작업 트리 파일, 삭제된 파일(base 버전 표시) 각각 확인
- [ ] **M1-11 검색 (F-DV-7):** `⌘P` 파일 퍼지 검색, `/` diff 검색(코어)
  - ✓ 1만 파일에서 `⌘P` 응답 < 50ms · 12만 줄 diff 검색이 아직 로드 안 된 파일의 결과도 찾는다
- [ ] **M1-12 단축키 (F-DV-8):** `] [ n p / ⌘P ? v ⌘/`
  - ✓ 키마다 동작하는지 프론트 테스트 페이지(수동 체크리스트) · 입력창에 포커스가 있을 때는 단축키를 먹지 않는다
- [ ] **M1-13 봤음 체크 (F-DV-9)** ⟵ M0-6
  - ✓ 로컬 범위에서 체크 → 재실행 → 유지 · 새 커밋으로 head 변경 → blob이 같은 파일만 유지

## M2 GitHub PR ⟵ M1-2
- [ ] **M2-1 URL과 `#n` 해석, remote 대조 (F-PR-1)**
  - ✓ 단위 테스트: https/ssh remote, 여러 remote, 일치 없음(에러 화면), fork PR
- [ ] **M2-2 fetch:** `refs/griiy/gh/<owner>/<repo>/<n>/{head,base}`, merge-base 계산
  - ✓ 실행 전후 `git for-each-ref refs/heads refs/remotes refs/tags` 동일 · 재fetch(force-push)도 정상 · 공개 저장소 PR 하나로 수동 확인
- [ ] **M2-3 메타데이터와 코멘트:** `gh api`로 PR, 리뷰 코멘트, 이슈 코멘트, 연결 이슈
  - ✓ `gh` 응답 fixture로 파싱 테스트 · `gh` 없음/미로그인 → 안내 화면
- [ ] **M2-4 PR 패널과 안전 Markdown (F-PR-4, F-PR-5)**
  - ✓ 악성 Markdown fixture(`<script>`, `<img onerror>`, `javascript:` 링크, 외부 이미지, iframe)에서 스크립트 실행·HTML 해석·외부 요청이 없다 · 줄 코멘트가 해당 줄 옆에 보인다

## M3 AI 질문 ⟵ M1-4, M2-3
- [ ] **M3-1 백엔드 (F-AI-5):** `ClaudeCli`와 `AnthropicApi`, 스트리밍, 취소, 모델 설정 · PRD 열린 질문 2
  - ✓ 가짜 백엔드로 스트리밍·취소·오류 테스트 · CLI 모드에서 도구가 꺼진 것을 확인(저장소 파일을 읽으라는 질문에도 읽지 않음) · 지원 CLI 버전 미만이면 안내
- [ ] **M3-2 근거 ① 코드 (F-AI-2)**
  - ✓ unified에서 고른 선택과 같은 범위를 파일 전체 보기에서 고른 선택이 같은 근거를 만든다
- [ ] **M3-3 근거 ② 이력 (F-AI-2):** `log -L`, `log base..head`, blame, timeout, 상한, fallback, 캐시
  - ✓ fixture: 일반, rename된 파일, 2,000줄 초과(→ fallback), 바이너리(→ 제외), timeout(→ fallback) · 같은 질문 두 번째는 캐시 사용
- [ ] **M3-4 근거 ③ PR (F-AI-2):** 본문, 코멘트(해당 파일 우선), 연결 이슈
  - ✓ 토큰 상한 상황에서 해당 파일 코멘트가 다른 파일 코멘트보다 먼저 남는다
- [ ] **M3-5 프롬프트, 인용, 인젝션 방어 (F-AI-3, F-AI-4):** `prompt_version` 상수, 신뢰할 수 없는 자료 구획, 인용 ID 검증
  - ✓ 인용 파서 단위 테스트(정상, 없는 ID, 깨진 형식) · 인젝션 fixture(코드 주석·PR 본문·코멘트에 "이전 지시를 무시하고…")로 기록된 응답 회귀 테스트
- [ ] **M3-6 전송 동의와 근거 미리보기 (F-AI-6)**
  - ✓ 첫 전송 전 동의 화면 · 항목을 빼면 실제 프롬프트에서도 빠진다(테스트) · 토큰 상한 초과 시 오래된 커밋부터 잘린다
- [ ] **M3-7 질문 UI (F-AI-1, F-AI-7, F-AI-8):** 줄 드래그 → `?`, 스트리밍, 취소, 이어 묻기, 👍/👎
  - ✓ 수동 체크리스트 · 인용 링크를 누르면 커밋/코멘트/코드 위치로 이동
- [ ] **M3-8 저장 (F-AI-9)** ⟵ M0-6
  - ✓ 재실행 후 기록 표시 · head 변경 후 "이전 버전" 목록에 코드 스냅샷과 함께 표시 · 설정에서 리뷰별 삭제

## M4 v0.1 릴리스 ⟵ M0–M3
- [ ] **M4-1 `griiy stats`:** 👍 비율, 확인 안 된 인용 비율 (PRD §9)
  - ✓ fixture store로 집계 테스트
- [ ] **M4-2 서명과 공증:** M0-3에서 정한 형태로 Developer ID 서명, notarytool, staple
  - ✓ 새 Mac 계정에서 다운로드 후 Gatekeeper 경고 없이 실행
- [ ] **M4-3 배포:** GitHub Releases(universal `.app`), Homebrew cask
  - ✓ 두 경로 모두 깨끗한 환경에서 설치 확인
- [ ] **M4-4 README 데모:** 스크린샷, GIF, 첫 실행 안내
- [ ] **M4-5 외부 테스터 3명 설치 테스트 (PRD §9)**
  - ✓ 3명 모두 5분 이내, 막힌 지점을 이슈로 기록
- [ ] **M4-6 릴리스 노트:** PRD §8 측정값 표

---

# v0.2

## M5 diff 확장
- [ ] **M5-1 좌우 보기 (F-DV-2)** · ✓ 가상 스크롤 기준(M1-6) 유지, `s` 전환 설정 기억
- [ ] **M5-2 단어 단위 강조 (F-DV-6)** · ✓ 보이는 줄만 계산, 12만 줄 스크롤 기준 유지
- [ ] **M5-3 테마 설정** · ✓ 시스템/라이트/다크, 재실행 후 유지

## M6 Bitbucket Cloud와 Jira
- [ ] **M6-1 Bitbucket PR (F-PR-2)** · ✓ 응답 fixture 테스트, fork 삭제·권한 없음·force-push 처리, 실제 PR 수동 확인
- [ ] **M6-2 Bitbucket 코멘트와 인용 ID `[bb-comment:id]`** · ✓ M2-4와 같은 악성 Markdown fixture 통과
- [ ] **M6-3 Jira (F-AI-2 ④):** 설정된 프로젝트 키만 매칭, 키체인 `jira:<host>` · ✓ `UTF-8`, `SHA-256`, `ISO-8601`이 매칭되지 않는다 · 응답 fixture 테스트
- [ ] **M6-4 `ticket` 모듈 경계:** Jira 하나만 구현하되 Linear 추가 시 바꿀 곳을 문서화 · ✓ CONTRIBUTING에 추가 방법 기재

## M7 Explain 탭
- [ ] **M7-1 정적 문서 렌더러 (F-EX-2, F-EX-3)** — 생성보다 먼저 만든다
  - ✓ 테스트 문서에 `<script>`, `onerror`, 외부 `<img>`, `fetch`, `window.ipc`, `griiy://api/` 링크를 넣어도 실행·요청·접근이 없다 · `griiy://goto` 외 navigation 차단
- [ ] **M7-2 Mermaid → SVG (신뢰 영역)** ⟵ M7-1 · ✓ 오프라인 렌더, 문법 오류 블록은 원문 코드로 표시
- [ ] **M7-3 설명 프롬프트와 큰 PR 분할 (F-EX-1, F-EX-4)** ⟵ M7-1 · ✓ 토큰 미리보기 후 확인해야 실행 · 상한 70% 초과 시 파일별 요약 후 합침
- [ ] **M7-4 캐시와 재생성 (F-EX-5)** · ✓ base만 바뀌어도(대상 브랜치 이동) 캐시를 쓰지 않는다

---

## 이후 후보
PR 코멘트·승인 · Linux/Windows 정식 지원 · GitLab · Bitbucket Server/DC · Linear · head 변경 시 질문 줄 재매핑
