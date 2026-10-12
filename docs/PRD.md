# griiy PRD

> 상태: v0.2 초안 (2026-10-12, Codex·Fable 리뷰 반영) · 라이선스: MIT OR Apache-2.0 · 공개 저장소 예정

## 1. 한 줄 요약
**griiy는 PR 리뷰만 하는 작고 빠른 데스크톱 앱이다.** 변경을 보고, 코드에 대고 "이건 왜 바뀌었지?"라고 물으면 커밋, PR, 티켓을 근거로 인용하며 답한다.

## 2. 문제
- GitLens 같은 도구는 기능이 많고 무겁다. PR 리뷰에 필요한 건 그중 **코드 비교** 하나다.
- 웹 PR 화면은 diff는 보여주지만 **"왜"는 보여주지 않는다.** 이유는 커밋 메시지, PR 본문, 리뷰 코멘트, 티켓에 흩어져 있어 리뷰어가 직접 찾아 맞춰 봐야 한다.
- 큰 PR은 줄 단위 diff만으로는 전체 구조를 파악하기 어렵다.

## 3. 릴리스 범위

| | v0.1 (첫 공개) | v0.2 이후 |
|---|---|---|
| 입력 | 로컬 범위, 작업 트리, GitHub PR | Bitbucket Cloud PR (이후 Server/DC) |
| diff 뷰 | unified, 파일 트리, 가상 스크롤, 구문 강조, 파일 전체 보기, 검색, 단축키, 봤음 체크 | 좌우 보기, 단어 단위 강조, 테마 설정 |
| AI 질문 | 근거 ①코드 ②커밋 이력 ③PR 본문·코멘트·연결 이슈 | 근거 ④Jira 티켓 (이후 Linear 등) |
| 설명 | — | Explain 탭 (Markdown + Mermaid) |

**비목표:** PR에 코멘트·승인·머지, 코드 편집과 커밋, Linux·Windows 정식 지원, GitLab, 텔레메트리, 계정과 서버.
작업 순서는 diff 뷰 → PR 소스 → AI 질문이다 (사용자 결정, 2026-10-12).

## 4. 사용자
- **주 사용자:** 매일 동료 PR을 리뷰하는 개발자. 터미널과 git CLI에 익숙하다.
- **환경:** macOS 15 이상, git 필수. `gh`, `claude` CLI는 선택.
- **첫 실행 원칙:** AI도 토큰도 없이 diff 뷰어로 바로 동작한다. 설정은 필요한 기능을 처음 쓸 때 그 자리에서 요청한다 (§6.6).

## 5. 핵심 시나리오
1. **로컬 리뷰:** `griiy main...feature` → merge-base 기준 diff와 파일 트리가 뜬다.
2. **작업 트리:** 인자 없이 `griiy` → 커밋 안 한 변경(스테이징 포함)을 HEAD와 비교한다.
3. **GitHub PR:** `griiy https://github.com/o/r/pull/42` 또는 저장소 안에서 `griiy '#42'` → base와 head를 fetch하고 PR 본문, 코멘트와 함께 연다.
4. **왜 바뀌었지:** 줄 범위를 드래그하고 `?` → 보낼 근거를 미리 보고 → 답이 스트리밍되며 커밋, PR 코멘트, 이슈가 링크로 인용된다.
5. **다시 열기:** 같은 PR을 다시 열면 이전 질문과 답이 보인다. head가 바뀌었으면 이전 질문은 "이전 버전" 목록으로 가고, 당시 인용한 코드 스냅샷과 함께 보인다.
6. **(v0.2) 전체 설명:** `Explain` → 예상 토큰을 확인한 뒤 생성 → 다이어그램이 있는 설명 문서가 탭으로 열린다.

## 6. 기능 요구사항

### 6.1 입력과 정규화
| ID | 요구사항 |
|---|---|
| F-IN-1 | `griiy [<range> \| <PR URL> \| #<n>] [-C <repo>]` |
| F-IN-2 | 범위 의미 (git과 같음): `a..b` → base=`a`, head=`b` (끝점 비교) · `a...b` → base=`merge-base(a,b)`, head=`b` · 인자 없음 → base=`HEAD`, head=작업 트리(인덱스 포함, `git diff HEAD`) · PR → base=`merge-base(base 브랜치 tip, head)` |
| F-IN-3 | 모든 입력은 `Review { repo, base: Sha, head: Sha \| WorkTree, pr: Option<PrMeta> }`로 정규화한다. diff는 항상 로컬 git으로 계산한다 |
| F-IN-4 | 실행하면 창이 앞으로 나오고 키 입력을 받는다. 서명된 `.app` 배포와 bare binary 둘 다에서 M0 POC로 확인하고, bare binary에서 보장되지 않으면 `.app` + CLI 심링크 배포로 정한다 |
| F-IN-5 | git 없음, 저장소 아님, 잘못된 범위, fetch 실패, 권한 없음 → 창 안에 원인과 해결 방법을 보여준다. 패닉 금지 |

### 6.2 PR 소스
| ID | 요구사항 |
|---|---|
| F-PR-1 | **GitHub (v0.1):** `gh` 인증을 재사용한다. URL의 owner/repo를 `git remote -v`와 대조해 remote를 고른다. 일치하는 remote가 없으면 F-IN-5 화면으로 clone 경로를 안내한다. 명시적 refspec으로 fetch한다: `refs/pull/<n>/head:refs/griiy/gh/<owner>/<repo>/<n>/head`, base 브랜치는 `refs/griiy/gh/<owner>/<repo>/<n>/base`. fork PR도 `refs/pull/<n>/head`로 받는다 |
| F-PR-2 | **Bitbucket Cloud (v0.2):** API 2.0으로 source/destination의 저장소 URL과 커밋 SHA를 확정한 뒤 SHA를 `refs/griiy/bb/...`로 fetch한다. fork 삭제, 권한 없음, force-push는 F-IN-5로 처리한다 |
| F-PR-3 | **비밀값:** 우선순위는 환경변수 → 키체인. 키체인 항목은 service=`griiy`, account=`github` / `bitbucket:<workspace>` / `jira:<host>` / `anthropic`. 입력은 마스킹하고, 설정 화면에서 교체·삭제할 수 있다. 키체인 접근이 거부되면 이번 실행에서만 메모리에 보관하고 그 사실을 알린다. 로그와 화면, AI 프롬프트에 비밀값을 넣지 않는다 |
| F-PR-4 | PR 패널: 제목, 작성자, 본문, 리뷰 코멘트. 줄 코멘트는 해당 줄 옆에 표시한다 (읽기 전용) |
| F-PR-5 | **PR Markdown 안전 렌더:** 원본 HTML 태그는 이스케이프한다. 링크는 `https:`와 `mailto:`만 허용하고 외부 브라우저로 연다. 외부 이미지는 기본적으로 차단하고 "이미지 보기"를 눌러야 불러온다. iframe과 이벤트 핸들러는 생성하지 않는다 |
| F-PR-6 | griiy는 `refs/griiy/*` fetch 외에는 저장소에 아무것도 쓰지 않는다 |

### 6.3 Diff 뷰
| ID | 요구사항 |
|---|---|
| F-DV-1 | 파일 트리: 전체 추적 파일과 변경 표시, 변경 폴더 자동 펼침, 단일 자식 폴더 합치기. 접힌 폴더의 자식은 펼칠 때 렌더한다 |
| F-DV-2 | (v0.2) unified와 side-by-side 전환, 설정 기억 |
| F-DV-3 | 구문 강조: 첫 페인트 후 지연 로드하고, 보이는 줄만 강조한다 |
| F-DV-4 | 가상 스크롤: diff 패널의 DOM은 보이는 줄 수에 비례한다 |
| F-DV-5 | 파일 전체 보기: 트리에서 아무 파일이나 열면 head 버전 전체(작업 트리면 디스크 파일)를 보여주고 변경 줄을 표시한다 |
| F-DV-6 | (v0.2) 줄 안 단어 단위 강조 |
| F-DV-7 | 검색: `⌘P` 파일 이름 퍼지 검색은 프론트에서, `/` diff 텍스트 검색은 백엔드(`griiy://api/search`)에서 하고 결과 위치로 이동한다 |
| F-DV-8 | 단축키: `]` `[` 파일, `n` `p` hunk, `/` `⌘P` 검색, `?` 질문, `v` 봤음, `⌘/` 도움말. (v0.2) `s` 보기 전환 |
| F-DV-9 | 파일별 봤음 체크. head가 바뀌면 blob이 같은 파일만 체크를 이월한다 |
| F-DV-10 | 바이너리, 이름 변경, 모드 변경, 삭제, 대용량 파일(기본 1MB 초과는 접힘) 표시 |

### 6.4 AI 질문 ("왜 바뀌었지?")
| ID | 요구사항 |
|---|---|
| F-AI-1 | **선택 좌표:** `Selection { path, side: Base \| Head, start, end }`. 줄 번호는 화면 줄이 아니라 해당 쪽 파일의 줄 번호다. 질문할 때 base 쪽과 head 쪽 범위를 모두 계산한다 (hunk 매핑). 단위는 줄 범위, hunk, 파일 |
| F-AI-2 | **근거 수집기**: 항목마다 출처 ID를 붙인다 (F-AI-3) |
| | ① 코드: 선택 diff와 base/head 양쪽 주변 ±40줄 |
| | ② 이력: `git log -L <base 범위>:<path> <base>` (이전 이력), `git log <base>..<head> -- <path>` (이번 PR의 커밋), base 쪽 blame. `-L`은 텍스트 파일이고 범위 2,000줄 이하일 때만 쓰고, 5초 timeout과 출력 상한을 둔다. 실패하면 `git log -- <path>`로 대신한다. 결과는 (sha, path, range)로 캐시한다 |
| | ③ PR: 본문, 리뷰 코멘트(해당 파일 우선), 본문과 커밋에 적힌 GitHub 이슈(`#n`, `closes #n`) |
| | ④ (v0.2) 티켓: 설정된 Jira 프로젝트 키에만 매칭한다 (`ABC-123`; `UTF-8`, `SHA-256` 같은 오탐 방지) |
| F-AI-3 | **인용 ID:** `[code:<path>:L<a>-<b>@<base\|head>]`, `[commit:<sha7>]`, `[gh-pr]`, `[gh-review:<id>]`, `[gh-comment:<id>]`, `[gh-issue:<n>]`, (v0.2) `[bb-comment:<id>]`, `[jira:<KEY>]`. UI는 **근거 집합에 실제로 있는 ID만** 링크로 바꾸고, 없는 ID는 "확인 안 된 인용"으로 표시하고 집계한다. 근거 없는 주장은 "추정"으로 표시하도록 지시한다 |
| F-AI-4 | **프롬프트 인젝션 방어:** 코드, 주석, PR 본문, 코멘트, 이슈, 티켓은 모두 "신뢰할 수 없는 인용 자료"로 구획해 넣는다. 시스템 지시로 자료 안의 지시를 따르지 않게 한다. 인젝션 fixture로 회귀 테스트한다 |
| F-AI-5 | **백엔드:** `claude` CLI(`claude -p`, 스트리밍 JSON) 또는 Anthropic API 중 선택한다. 기본 모델은 `claude-opus-5-5`이고 설정에서 바꿀 수 있다. CLI 모드에서는 **도구 사용을 끄고** 프롬프트로 준 근거만 쓰게 한다. CLI 버전을 확인하고, 출력 파싱에 실패하면 안내한다 |
| F-AI-6 | **전송 동의와 미리보기:** 처음 보낼 때 백엔드, 모델, 전송 대상(Anthropic)을 알리고 동의를 받는다. 질문마다 보낼 근거 목록과 항목별 토큰 수를 보여주고, 항목을 뺄 수 있다. 상한을 넘으면 오래된 커밋부터 자른다 |
| F-AI-7 | 스트리밍 표시, 취소, 같은 스레드에서 이어 묻기 |
| F-AI-8 | 답변마다 👍/👎를 남길 수 있다 (§9 지표) |
| F-AI-9 | **저장:** 질문, 답, 근거 ID 목록, **인용된 코드의 텍스트 스냅샷**, base/head sha, 모델, `prompt_version`, 평가를 저장한다. head가 바뀌면 줄을 다시 매핑하지 않고 모두 "이전 버전"으로 분류한다 (v0.1) |

### 6.5 Explain 탭 (v0.2)
| ID | 요구사항 |
|---|---|
| F-EX-1 | 모델은 **Markdown과 ```mermaid 블록만** 출력한다: 요약, 변경 구조 다이어그램, 파일별 요점, 위험 지점 |
| F-EX-2 | **신뢰 영역**(앱)이 Markdown을 F-PR-5 규칙으로 렌더하고, Mermaid를 내장 라이브러리로 SVG로 바꾼다. 결과는 `script-src 'none'`, 네트워크 금지 CSP를 건 정적 문서로 별도 탭에 띄운다. 모델 출력의 스크립트는 어떤 경우에도 실행되지 않는다 |
| F-EX-3 | 파일과 줄 참조는 `griiy://goto?...` 링크로 만들고, wry navigation handler가 가로채 diff 탭으로 이동한다. 그 밖의 navigation, 팝업, 다운로드는 차단한다 |
| F-EX-4 | 실행 전에 F-AI-6과 같은 근거·토큰 미리보기를 보여준다. 상한의 70%를 넘는 "큰 PR"이면 파일별 요약을 먼저 만들어 합친다 |
| F-EX-5 | 캐시 키는 (리뷰 키, base sha, head sha, `prompt_version`)이다. 재생성 버튼을 둔다 |

### 6.6 첫 실행과 설정
- **AI 백엔드 선택 순서:** PATH에 `claude`가 있으면 그것을 쓴다. 없으면 Ask 패널 안에서 API 키 입력 카드를 보여준다. 둘 다 없어도 diff 뷰어는 정상 동작한다.
- **토큰 요청:** GitHub는 `gh`가 없거나 로그인 안 됐을 때 `gh auth login` 안내를 보여준다. Jira 설정은 티켓 키가 처음 감지될 때 보여준다 (v0.2).
- **설정 파일:** `~/Library/Application Support/griiy/config.toml`. AI 백엔드와 모델, Jira 주소와 프로젝트 키, 주변 줄 수, 토큰 상한, 대용량 기준. 잘못된 값은 기본값으로 대체하고 경고한다. 비밀값은 이 파일에 두지 않는다.

## 7. 설계

### 7.1 원칙
- **실행 파일 하나.** HTML, JS, CSS, highlight, Mermaid를 모두 바이너리에 내장한다. CDN은 쓰지 않는다
- **프론트엔드 빌드 단계 없음:** vendored 라이브러리와 순수 ES 모듈
- **외부 도구는 이미 설치된 것을 호출한다:** git(필수), gh, claude(선택)
- **읽기 전용:** 저장소에는 `refs/griiy/*`만 쓴다

### 7.2 구조
```
griiy (Rust)
 ├─ cli      인자 → Input
 ├─ source   Input → Review (Local | GitHub | Bitbucket)
 ├─ git      git CLI 래퍼 (timeout, 출력 상한, 취소)
 ├─ diff     unified diff → 파일/hunk/줄 구조, Selection ↔ base/head 줄 매핑
 ├─ ai       Backend(ClaudeCli | AnthropicApi), 근거 수집기, 프롬프트(prompt_version), 인용 검증
 ├─ ticket   (v0.2) Jira
 ├─ store    리뷰별 JSON, 스키마 버전
 ├─ secret   환경변수 → 키체인
 └─ ui       tao 창, wry WebView, griiy:// 프로토콜, 이벤트 채널
frontend (내장)  index.html · app.js · diff-view.js · tree.js · ask.js · md.js · vendor/{highlight, mermaid}
```

### 7.3 백엔드와 화면 사이 통신
- **시작:** 파일 목록, 통계, PR 메타데이터만 보낸다. 파일별 diff, 파일 내용, 검색, 근거 미리보기는 필요할 때 요청한다.
- **`griiy://` 라우트는 허용 목록만:** `griiy://app/<asset>`(내장 자산), `griiy://api/<route>`(JSON). 파일은 경로 문자열이 아니라 현재 `Review`의 **파일 ID**(목록 인덱스)로만 요청한다. 임의 경로, `..`, 다른 ref 요청은 404다. 응답에 정확한 MIME 타입을 붙인다.
- **이벤트 채널 (스트리밍):** 백엔드에서 화면으로 가는 모든 메시지는 `{v:1, req:<id>, type, data}` JSON 하나로 `evaluate_script`를 통해 보낸다. 화면이 `ready`를 보내기 전에는 큐에 쌓고, 큐 상한을 넘으면 청크를 합친다. 취소하거나 창을 닫으면 요청 ID에 연결된 백엔드 작업(AI 프로세스, git)을 중단한다.
- **첫 페인트를 늦추지 않는다:** highlight와 Mermaid는 첫 페인트 후 지연 로드한다.

### 7.4 저장
- 경로: `~/Library/Application Support/griiy/reviews/<key>.json`, 스키마 `version` 필드.
- **리뷰 키:** GitHub `gh-<owner>-<repo>-<n>`, Bitbucket `bb-<ws>-<repo>-<n>`, 로컬 범위 `local-<repo 경로 해시>-<base ref 이름>-<head ref 이름>` (sha가 아니라 ref 이름이라 커밋해도 이어진다), 작업 트리 `local-<repo 해시>-worktree`.
- 항목(질문, 봤음, Explain)마다 base/head sha를 함께 저장해 버전을 구분한다.
- **민감정보:** 질문 기록에는 코드 스냅샷이 들어간다. 설정 화면에서 리뷰별·전체 삭제를 제공하고, README에 저장 위치를 적는다.

## 8. 비기능 요구사항
| 항목 | 목표 | 측정 방법 | 스파이크 참고치 |
|---|---|---|---|
| 첫 화면, ≤2,000줄, 웜 스타트 | < 1s | bench.sh 실행→첫 페인트 | 670–810ms |
| 첫 화면, 12만 줄 | < 1s | bench.sh | 1.5s (가상 스크롤 전) |
| 스크롤 | 12만 줄에서 끝까지 스크롤할 때 50ms 넘는 프레임 ≤ 1% | bench.sh 자동 스크롤 + long-frame 집계 | 미측정 |
| diff 패널 DOM | < 5,000 노드 (트리 제외) | bench.sh가 보고 | 12만+ |
| 메모리, ≤2,000줄 | < 200MB (WebKit 포함) | bench.sh RSS | 148–158MB |
| 메모리, 12만 줄 | < 250MB | bench.sh RSS | 531MB |
| 바이너리 | < 15MB | CI | 1.5MB |
| 오프라인 | AI와 PR 조회를 빼면 모두 오프라인 동작 | 수동 | — |
| 외부 요청 | 사용자가 고른 AI, GitHub, (v0.2) Bitbucket, Jira만. 외부 이미지는 사용자가 누를 때만 | 코드 리뷰와 테스트 | — |

## 9. 성공 기준
- **유용성:** AI 답변 👍 비율 ≥ 70% (store 집계, `griiy stats`)
- **근거 정확도:** 확인 안 된 인용 비율 ≤ 2% (F-AI-3 집계)
- **채택:** 작성자가 v0.1 이후 2주 동안 업무 PR 리뷰의 80% 이상을 griiy로 한다 (dogfooding)
- **설치 경험:** 외부 테스터 3명이 README만 보고 설치부터 첫 PR 열기까지 5분 이내

## 10. 마일스톤 (세부는 TASKS.md)
| 단계 | 내용 | 릴리스 |
|---|---|---|
| M0 | 기반: 오픈소스 정리, CI, 포커스·키체인 POC, `griiy://` 프로토콜, 이벤트 채널, store, 에러 화면 | v0.1 |
| M1 | 로컬 diff 뷰: 범위·작업 트리, 지연 로딩, 가상 스크롤, 구문 강조, 전체 파일, 검색, 단축키, 봤음 | v0.1 |
| M2 | GitHub PR | v0.1 |
| M3 | AI 질문: 백엔드 2종, 근거 ①②③, 인용 검증, 인젝션 방어, 저장 | v0.1 |
| M4 | v0.1 공개 릴리스: 서명·공증, Homebrew, `griiy stats` | v0.1 |
| M5 | diff 확장: 좌우 보기, 단어 강조, 테마 | v0.2 |
| M6 | Bitbucket Cloud, Jira | v0.2 |
| M7 | Explain 탭 | v0.2 |

## 11. 결정 기록
| 질문 | 결정 (2026-10-12) |
|---|---|
| 스택 | Rust + wry (docs/SPIKE-rust-vs-tinyjs.md) |
| Bitbucket | Cloud만. Server/DC는 이후 |
| 기본 모델 | `claude-opus-5-5` (설정으로 변경 가능) |
| 서명·공증 | Apple Developer 계정 있음 → 서명·공증한 바이너리 배포 |
| 티켓 | v0.2에 Jira만. Linear 등은 이후 추가할 수 있게 `ticket` 모듈을 둔다 |
| 이름 | `griiy` (graz → graya → grun → griiy, "그리 바꿨어?"). crates.io·Homebrew·npm·이 Mac 명령어에서 비어 있음 (2026-10-12 확인). 쓰지 않은 후보: `grun`(Homebrew `antlr`의 명령어와 겹침), `gree`(crates.io에 이미 있음), `gry`, `grya`, `griy` |
| v0.1 범위 | 로컬 + GitHub + AI 질문 + 기본 diff 뷰 |
| 작업 순서 | diff 뷰 → PR → AI (핵심 기능을 먼저 하자는 리뷰 의견은 채택하지 않음) |
| Explain 형식 | HTML 생성 대신 Markdown + Mermaid, 앱이 정적 문서로 렌더 |

## 12. 열린 질문
1. bare binary로 창 포커스와 키체인이 문제없이 되는가, 아니면 `.app` + CLI 심링크로 배포해야 하는가 → M0-3 POC 결과로 결정
2. `claude -p`에서 도구를 완전히 끄는 플래그와 stream-json 형식의 안정성 → M3-1에서 확인
