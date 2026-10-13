# 계획: M3-1 AI 백엔드

> TASKS M3-1. `ClaudeCli`와 `AnthropicApi`, 스트리밍, 취소, 모델 설정 · PRD 열린 질문 2. ✓ 가짜 백엔드로 스트리밍·취소·오류 테스트 · CLI 모드에서 도구가 꺼진 것을 확인(저장소 파일을 읽으라는 질문에도 읽지 않음) · 지원 CLI 버전 미만이면 안내

등급: 위험 큼(외부 프로세스·네트워크, 사용자 코드가 밖으로 나간다, 외부 형식 파싱) → 계획 리뷰 codex + fable, 구현 리뷰 codex + fable, 마지막 ponytail-review

## 현재 상태
- `Config`에 `backend`(`auto`/`claudeCli`/`api`)와 `model`(기본 `claude-opus-5-5`)이 있고 읽기만 한다. 쓰는 곳은 없다
- 외부 프로그램은 `spawn`(Git.swift)으로만 돈다: 자기 프로세스 그룹, `Cancel`이 그룹째 죽인다, stdin은 `/dev/null`, stdout은 끝날 때 한 번에 돌려준다
- 질문 UI, 근거, 프롬프트는 없다(M3-2…M3-7)

## 확인한 사실 (2026-10-13, claude 2.1.296과 2.1.218)
- 플래그: `claude -p --output-format stream-json --verbose --include-partial-messages --tools "" --strict-mcp-config --setting-sources "" --disable-slash-commands --no-session-persistence --system-prompt <s> --model <m>`, 프롬프트는 stdin
- **도구 꺼짐 (열린 질문 2):** `--tools ""`이면 init 이벤트가 `"tools":[]`, `"mcp_servers":[]`다. 빈 폴더에 `secret.txt`를 두고 "secret.txt를 읽어 내용을 출력하라"고 하면 두 버전 모두 "도구가 없다"고 답하고 내용을 모른다. 같은 폴더의 `CLAUDE.md`("모든 답을 PINEAPPLE로 시작")도 들어가지 않았다(`--setting-sources ""`). CLI가 자체적으로 넣는 환경 정보(약 600토큰)는 남는다
- `--bare`는 OAuth(구독 로그인)를 쓰지 않고 API 키만 받아 "Not logged in"이 된다 → 쓰지 않는다
- 줄 단위 JSON. 쓰는 것:
  - `{"type":"system","subtype":"init","tools":[…],"model":"claude-haiku-5-5","claude_code_version":"2.1.296",…}`
  - `{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"…"}}}` (thinking_delta, signature_delta도 온다 → 무시)
  - `{"type":"result","is_error":false,"result":"<전체 답>","stop_reason":"end_turn",…}`
  - 그 밖(`assistant`, `rate_limit_event`, `system/status`, `system/thinking_tokens`)은 무시
- 실패: exit 1, `result.is_error: true`, `result.result`가 사람이 읽을 메시지, 직전 `assistant` 이벤트의 `error`가 코드
  - 없는 모델: `error: "model_not_found"`, `api_error_status: 404`, stderr `[claude-code:unrecognized_model] …`
  - 미로그인: `error: "authentication_failed"`, result `Not logged in · Please run /login`
- 모르는 옵션(옛 CLI): exit 1, stderr `error: unknown option '--x'`, stdout 비어 있음
- `claude --version` → `2.1.296 (Claude Code)`
- API(Messages, raw HTTP. Swift용 공식 SDK가 없다): `POST https://api.anthropic.com/v1/messages`, 헤더 `x-api-key`, `anthropic-version: 2023-06-01`, `content-type: application/json`. 본문 `{"model","max_tokens","system","messages":[{"role":"user","content":…}],"stream":true}`. SSE `message_start`, `content_block_start/delta/stop`(`text_delta`, `thinking_delta`), `message_delta`(`stop_reason`), `message_stop`, `ping`, `error`(`{"type":"error","error":{"type":"overloaded_error","message":…}}`). HTTP 오류는 같은 모양의 JSON 본문
  - `claude-opus-5-5`: thinking은 끌 수 없고(adaptive가 기본), `temperature` 등은 400. 그래서 `thinking`·샘플링 파라미터를 보내지 않는다. effort 기본은 `medium`

## 설계
(계획 리뷰로 바뀐 곳이 있다: 아래 "계획 리뷰 반영" 절이 우선한다)

### 1. 공개 모양 (`GriiyCore/AI.swift`, 새 파일 하나)
```swift
public enum AIBackend: Sendable {
    case claudeCli(path: String)          // 실행 파일. 기본 "claude"(PATH), 테스트는 가짜 스크립트
    case api(key: String, url: URL)       // url 기본 https://api.anthropic.com/v1/messages, 테스트는 로컬
}

public struct AIRequest: Sendable {
    public var model: String
    public var system: String
    public var prompt: String             // 근거와 질문을 다 담은 한 덩어리(M3-5가 만든다)
}

/// 스트리밍 질문. 글자가 올 때마다 `onText`, 끝나면 전체 답. 블로킹: Background 스레드에서 부른다.
public func ask(_ b: AIBackend, _ r: AIRequest, cancel: Cancel, onText: @Sendable (String) -> Void) throws(AIError) -> Answer

public struct Answer: Sendable, Equatable { public var text: String; public var model: String }
```
- 두 백엔드 다 **블로킹 함수 하나**: 기존 규칙("블로킹 작업은 Thread, UI는 MainActor")과 `Cancel`을 그대로 쓴다. UI(M3-7)는 `Background`로 부르고 `onText`를 메인으로 넘긴다
- 프로토콜을 두지 않는다: 구현이 둘이고 테스트는 가짜 *실행 파일*·가짜 *서버*로 실제 코드 경로를 지난다
- `model`은 응답에 실제로 쓰인 모델(CLI init의 `model`, API `message_start.message.model`). F-AI-9 저장용
- 이어 묻기(F-AI-7)는 M3-7에서 `prompt`를 대화 전체로 만들거나 `messages` 배열로 넓힌다. 지금은 한 턴

### 2. ClaudeCli
- `spawn`을 넓힌다: `stdin: [UInt8]?`(nil이면 지금처럼 `/dev/null`), `onStdout: ((ArraySlice<UInt8>) -> Void)?`(있으면 읽는 대로 넘기고 모아 두지 않는다), `cwd: FilePath?`(`posix_spawn_file_actions_addchdir_np`). stdin 쓰기는 별도 스레드(큰 프롬프트가 파이프를 채우는 동안 stdout을 막지 않게), 자식이 일찍 닫으면 EPIPE를 무시한다(`SIGPIPE`는 이미 기본값이라 우리 쪽은 `F_SETNOSIGPIPE`)
- 작업 폴더는 빈 임시 폴더(`NSTemporaryDirectory()/griiy-ask-<pid>`): 도구가 꺼져 있어도 CLI가 cwd에서 무엇을 찾는 일이 없게
- 줄 파서 `cliEvent(_ line) -> CliEvent?`(순수 함수): `.initialized(tools, model, version)`, `.text(String)`, `.result(isError, text)`, 그 외 nil. 줄이 JSON이 아니면 nil(무시)
- **init의 `tools`가 비어 있지 않으면 즉시 그룹을 죽이고 `.toolsNotOff`**: 버전·플래그 의미가 바뀌어도 도구가 켜진 채로는 답을 받지 않는다
- 판정: `result`가 오고 `is_error == false` → 성공(text는 `result.result`, 스트리밍 조각 합과 다르면 `result`가 우선). `is_error` → 직전 `assistant.error`로 분류: `authentication_failed` → `.cliAuth`, `model_not_found` → `.badModel(model)`, 그 밖 → `.failed(result 메시지)`. `result` 없이 끝남 → stderr에 `unknown option`이면 `.cliTooOld(version)`, 아니면 `.unreadable(stderr 마지막 줄)`
- 버전: `claudeVersion(path) -> Version?`을 `claude --version`으로 한 번 묻는다(앱에서 캐시는 M3-7). `2.1.218` 미만이면 `.cliTooOld`. 2.1.218은 위 플래그가 모두 동작하는 걸 확인한 가장 옛 버전이다. 파싱 못 하면 막지 않는다(init의 tools 검사가 지킨다)
- 실행 파일 없음(ENOENT) → `.cliMissing`

### 3. AnthropicApi
- `URLSession`의 delegate 기반 `dataTask`를 Background 스레드에서 세마포어로 기다린다(블로킹 모양을 맞춘다). ephemeral 세션, 쿠키·캐시 없음, `timeoutIntervalForRequest` 120s(스트림이 끊긴 채 멈추는 경우), redirect 따르지 않음(키가 다른 host로 가지 않게)
- `Cancel`에 `onCancel(_ f: @Sendable () -> Void)`를 하나 더한다(이미 취소면 바로 부른다). API는 `task.cancel()`을 건다. CLI는 지금 그대로 그룹을 죽인다
- SSE 파서 `SSE`(순수, 바이트를 받아 `(event, data)`를 낸다: `\n`/`\r\n`, 빈 줄로 끝, `:` 주석 무시, 여러 `data:` 줄은 `\n`으로 잇는다) + `apiEvent(event, data) -> ApiEvent?`: `.start(model)`, `.text`, `.stop(reason)`, `.error(type, message)`
- 본문: `{"model","max_tokens":64000,"system","messages":[{"role":"user","content":prompt}],"stream":true}`. thinking·effort는 보내지 않는다(모델 기본)
- 판정: HTTP 200이 아니면 본문 JSON의 `error.type`/`message`: 401 → `.apiAuth`, 404 + `not_found_error` → `.badModel`, 그 밖 → `.failed("\(status) \(message)")`. 스트림 중 `error` 이벤트 → `.failed`. `stop_reason`이 `refusal` → `.refused`, `max_tokens` → 답은 돌려주되 `Answer`에 잘렸다는 표시 없이… (아래 열린 점)
- 네트워크 오류 → `.failed(localizedDescription)`, 취소 → `.cancelled`
- 키는 인자로 받는다. 키체인 저장과 입력 카드는 M3-6/M3-7(M0-3 POC와 함께)

### 4. 백엔드 고르기
```swift
public func chooseBackend(_ c: Config, apiKey: String?, claudeOnPath: Bool) -> AIBackend?
```
- PRD §6: `auto`는 PATH에 claude가 있으면 CLI, 없으면 키가 있으면 API, 둘 다 없으면 nil(Ask 패널이 키 입력 카드). `claude-cli`/`api`는 그것만. 순수 함수
- `claudeOnPath`는 `PATH`의 각 폴더에서 `access(X_OK)`. Finder로 띄운 앱은 PATH가 짧다(`~/.local/bin` 없음): gh와 같은 한계, 힌트에 "터미널에서 실행"

### 5. 에러 (`AIError`, 새 enum. `GitError`와 따로: 에러 화면이 아니라 Ask 패널에 뜬다)
`cliMissing`, `cliTooOld(version)`, `cliAuth`, `toolsNotOff`, `apiAuth`, `badModel(String)`, `refused`, `failed(String)`, `unreadable(String)`, `cancelled`. 각각 `title`/`hint`(GitError와 같은 모양). 에러 문자열에 API 키가 들어가지 않는다(키는 헤더에만)

## 테스트 (먼저) `AITests.swift`
- 파서(순수): 실제 출력에서 줄인 stream-json fixture 세 개(성공, 없는 모델, 미로그인) → 이벤트·판정. init tools 비어 있지 않음 → `.toolsNotOff`. JSON 아닌 줄·모르는 type은 무시
- SSE: 이벤트 경계, `\r\n`, 여러 data 줄, 주석, 한 이벤트가 두 청크에 걸침, 한 청크에 이벤트 여럿. `apiEvent`: text_delta, thinking_delta(무시), message_delta refusal, error
- **가짜 CLI**(테스트가 TempDir에 쓰는 sh 스크립트, `.claudeCli(path:)`로 넘긴다):
  - 스트리밍: fixture 줄을 사이에 `sleep 0.1`을 두고 낸다 → `onText`가 끝나기 전에 여러 번 불린다(첫 조각 시각 < 종료 시각)
  - 인자 확인: 스크립트가 받은 argv와 stdin을 파일로 남긴다 → `--tools ""`, `--setting-sources ""`, `--no-session-persistence`, `--model`이 있고, 프롬프트는 argv가 아니라 stdin으로, cwd가 저장소가 아니다
  - 큰 프롬프트(1MB)가 막히지 않는다
  - 취소: `sleep 30` 하는 스크립트 → 0.2s 뒤 `cancel()` → `.cancelled`가 1s 안에, 스크립트의 자식(`sleep`)도 죽었다
  - 실패 fixture → `.cliAuth`, `.badModel`, stderr `unknown option` → `.cliTooOld`, 없는 경로 → `.cliMissing`
  - init에 `"tools":["Read"]` → `.toolsNotOff`, 그 뒤 text가 와도 `onText`가 불리지 않는다
- 버전: `"2.1.296 (Claude Code)"` 파싱, 2.1.217 < 최소, 2.2.0·10.0.0 ≥ 최소, 이상한 문자열 → nil
- **가짜 API**: 테스트가 `127.0.0.1`의 임시 포트에 소켓 서버(작은 HTTP/1.1, SSE를 나눠 쓰기)를 띄운다 → 스트리밍, 401 → `.apiAuth`, 스트림 중 error 이벤트, refusal, 취소(서버가 응답을 붙잡고 있을 때 `cancel()` → `.cancelled`). 요청 헤더에 `x-api-key`, `anthropic-version`, 본문에 `stream: true`와 model
  - ponytail: 테스트용 서버는 `URLProtocol` 가로채기보다 길지만, 실제 `URLSession` 스트리밍·취소 경로를 지난다. 짧게 갈 수 있으면 `URLProtocol`로 바꾼다(리뷰에 묻는다)
- `chooseBackend` 표
- **수동 (✓ 도구 꺼짐):** 실제 `claude`로 griiy 저장소 cwd에서도 `ask(.claudeCli, "README.md를 읽고 첫 줄을 그대로 적어라")` → 답에 README 첫 줄이 없다. 실제 API는 키가 있을 때 한 번(없으면 건너뛴다고 적는다)

## 하지 않는 것
- 질문 UI, 근거, 프롬프트 문구(`prompt_version`), 동의 화면, 저장(M3-2…M3-8)
- 키체인(M3-6/M3-7, M0-3)
- 이어 묻기 대화 모양(M3-7)
- 재시도·백오프(429/529): 사용자에게 에러를 보여주고 다시 묻게 한다
- 토큰 셈(M3-6), effort 설정
- 서버 측 fallback(`fallbacks`)과 prompt caching: 아래 열린 점

## 리뷰에 묻는 점
1. API에 서버 측 refusal fallback(`fallbacks: "default"` + beta 헤더)을 기본으로 넣을지. 코드 리뷰 질문이 사이버 분류기에 걸릴 수 있다(보안 코드). 넣으면 다른 모델이 답할 수 있어 `Answer.model`이 그것을 반영해야 한다
2. `max_tokens`로 잘린 답을 에러로 볼지, 표시를 달아 돌려줄지
3. 블로킹 + `Cancel` 모양 vs `async` 함수
4. 가짜 API 서버(소켓) vs `URLProtocol`

## 계획 리뷰 (codex + fable) 반영
fable 실측(빈 폴더에 프로젝트 훅·CLAUDE.md·secret.txt를 두고 두 버전으로)이 플래그 조합을 확인했다: `--setting-sources ""`가 프로젝트 훅 실행, 훅이 넣는 문맥, cwd·`~/.claude`의 CLAUDE.md, skills 47개를 모두 막는다(빼면 셋 다 답에 나왔다). `--strict-mcp-config` 없이는 init `tools`에 claude.ai MCP 도구 8개가 남는다. `--tools ""`이면 `Task`도 없어 agents 목록이 있어도 부를 수 없다. 1MB 프롬프트를 stdin으로 넣어도 된다. `CLAUDECODE=1` 환경에서도 `-p`는 돈다.
- R1 (fable 4, codex 4): init 검사는 **닫힌 쪽으로**: 유효한 init이 먼저 와야 하고 `tools`와 `mcp_servers`가 둘 다 빈 배열이어야 한다. init 전에 오는 text·result, init 없음, 필드 없음 → `.toolsNotOff`(그룹을 죽인다)
- R2 (fable 1, codex 12): `Background<T, E: Error>`로 일반화한다. `ask`는 `spawn`의 `GitError`를 옮긴다: `.gitMissing` → `.cliMissing`, `.cancelled` → `.cancelled`, 나머지 → `.failed(detail)`
- R3 (fable 2·3·6): 작업 폴더는 고정 하나 `NSTemporaryDirectory()/griiy-ask`, spawn 전에 만든다(없으면 `addchdir`이 ENOENT라 `.cliMissing`으로 오분류된다). env에 `CLAUDE_CODE_DISABLE_AUTO_MEMORY=1`: 없으면 cwd마다 `~/.claude/projects/<cwd>/memory/`가 생긴다(실측). 이유는 "도구가 꺼져 있어도"가 아니라 "내장 플러그인(AGENTS.md)·메모리 경로가 저장소에 닿지 않게". git 상태는 `--system-prompt`가 기본 프롬프트를 바꿔서 이미 안 들어간다(실측)
- R4 (fable 5, codex 6·13): **취소 뒤에는 `onText`를 부르지 않는다**(SIGKILL 뒤 파이프에 남은 1.5KB가 완전한 줄로 왔다, 실측). `onText`는 읽는 스레드에서 차례로 불리고 막으면 안 된다: UI는 `DispatchQueue.main.async`로 넘긴다(주석). `ask`가 돌아온 뒤에는 불리지 않는다(읽기가 끝난 뒤 돌아온다)
- R5 (codex 3): 파서는 `assistant`의 `error` 코드를 버리지 않는다(`.failure(code)`). 판정은 `result.is_error` + 그때까지 본 마지막 코드. 사이에 다른 이벤트가 낀 fixture
- R6 (codex 7, fable 14): 바이트로 모아 `\n`에서만 자르고 줄·이벤트 단위로 UTF-8 디코드. 다바이트 글자가 청크에 걸리는 테스트
- R7 (codex 8·9, fable 14): SSE는 `\n`/`\r\n`, `data:` 뒤 공백 하나 제거, `:` 주석, 빈 줄로 이벤트 끝, EOF에 끝나지 않은 이벤트는 버린다. API 성공은 `message_start`와 `message_stop`이 둘 다 와야 한다. `message_stop` 없이 EOF → `.failed("stream ended early")`. `error` 이벤트 뒤에는 아무것도 성공이 아니다
- R8 (codex 10, fable 10): `AIBackend.api(key:)`만. URL은 상수(`https://api.anthropic.com/v1/messages`), 리다이렉트는 delegate에서 거부. 서버 오류 메시지는 한 줄·200자로 자른다. 키는 헤더에만 있고 에러 문자열은 URL·헤더·본문을 담지 않는다
- R9 (codex 11): stdin 쓰는 스레드는 어떤 경우든 stdin을 닫고 `spawn`이 돌아오기 전에 끝난다. EPIPE(자식이 안 읽음)는 조용히 멈춘다. 다른 쓰기 오류도 멈추고 결과는 자식의 출력으로 판정한다
- R10 열린 질문 1 (fable 8 vs codex): **넣는다**, 최소로. `"fallbacks":"default"` + `anthropic-beta: server-side-fallback-2026-07-01`(2026-10-13 기준 beta). 보안 패치 diff 질문이 cyber 분류기에 걸리면 `.refused`로는 사용자가 할 게 없다. 출력 전 fallback은 `message_start.message.model`이 이미 그 모델, 중간 fallback은 `content_block_start`의 `type: "fallback"`(`to.model`) → `Answer.model`을 바꾼다. 그래도 `refusal`이면 `.refused`. beta가 사라지면 400 → `.failed`로 보인다. CLI는 CLI가 정한다
- R11 열린 질문 2 (둘 다): 잘림은 에러가 아니다. `Answer.truncated`(API `message_delta.stop_reason`, CLI `result.stop_reason`이 `max_tokens`)
- R12 열린 질문 3 (둘 다): 블로킹 + `Cancel` 유지. `Cancel.onCancel`은 Mutex 안에서 등록, 이미 취소면 곧바로 부른다, 부르기는 락 밖에서
- R13 열린 질문 4 (fable 10 vs codex 15 "둘 다"): **`URLProtocol`만**. 청크 경계, 401, 헤더·본문, 취소(`stopLoading`이 불림)를 다 본다. 내부 `askApi(..., session:)`에 테스트가 `protocolClasses`를 넣은 세션을 준다. 소켓 서버는 수십 줄인데 더 보는 것이 리다이렉트 거부 하나라 코드 리뷰로 갈음한다
- R14 (fable 15): CLI 찾기는 PATH 다음에 `~/.local/bin/claude`(공식 설치 경로, Finder로 띄워도 있다). `chooseBackend`는 찾은 경로를 받는다
- R15 (codex 14): 취소 테스트는 시간이 아니라 표시 파일로 맞춘다(스크립트가 시작 표시를 쓰고 자식 `sleep`의 pid를 남긴다 → 테스트가 표시를 기다려 취소 → pid가 죽었는지)
- R16 (codex 16, fable 12): 수동 확인은 `AIRequest(model:system:prompt:)`로. 버전은 23ms라 캐시 언급을 뺀다
- 받지 않음: 디스크립터 소유 표·fd 셈 테스트(codex 5: `POSIX_SPAWN_CLOEXEC_DEFAULT`가 이미 dup하지 않은 fd를 자식에서 닫고, 부모 쪽은 기존 `readAll`의 `defer close` 모양 그대로), 정지 순서 상태 기계(codex 6: 그룹을 죽이면 자식 쪽 쓰기 끝이 닫혀 읽기가 EOF로 끝난다. 기존 git 취소가 같은 경로이고 테스트가 있다), lone `\r`·BOM·이벤트 크기 상한(codex 8: Anthropic이 보내지 않는다), 키 모양 문자열 지우기(codex 10: 키는 우리가 만든 헤더 밖으로 가지 않는다), stderr 폭주 테스트(codex 14: 기존 spawn이 stderr를 따로 비운다)

## 구현 리뷰 (codex + fable) 반영
- fable 1: `pipe(&err)`가 실패하면 `[0, 0]`으로 초기화된 `err` 때문에 fd 0(stdin)을 닫았다. 모든 pipe 배열을 `[-1, -1]`로 시작한다
- fable 2: 답이 다 온 뒤(`message_stop`) 연결이 끊기면 답을 버렸다. `ended` 뒤의 네트워크 오류는 무시한다(테스트: 가짜가 끝까지 보낸 뒤 연결을 끊는다)
- fable 3: 도구가 켜진 CLI의 출력을 버리는 것만 테스트했고, 그룹을 죽이는 것은 지워도 통과했다. 켜진 init 뒤 `sleep 30`을 띄우는 가짜로 자식이 죽는지 확인한다(mutation 확인)
- fable 4: 작업 폴더를 못 만들면 `.cliMissing`이 됐다(`--version`은 방금 성공했다). 만들기 실패는 `.failed`
- fable 5: 손자 프로세스가 stdin·stdout을 쥐고 있으면 그것이 끝날 때까지 `spawn`이 돌아오지 않는다. git과 같은 한계이고 취소가 그룹을 죽인다. `ponytail:` 주석
- fable 6: URLSession이 가짜의 두 조각을 하나로 합쳐 다바이트 분할이 `APIStream`을 지나지 않았다. `sseFraming`에 한글이 걸친 경우를 넣었다. `message_start` 없는 스트림 fixture를 넣었다(`started` 확인을 지우면 실패)
- fable 7: 취소 테스트의 대기 상한 2s → 10s(부하에서 두 번 걸렸다. hang 방지용이라 잃는 것이 없다)
- fable 8, codex 1: 다른 스레드의 취소와 `onText` 사이에 조각 하나가 지나갈 수 있다. 락으로 감싸면 `onText` 안에서 `cancel()`할 때 교착이라 하지 않는다. `ask` 주석에 "UI가 메인에서 다시 확인"을 적었다
- fable 10: `AIBackend.api(key:)`의 기본 description이 키를 찍었다(로그, `#expect` 실패 출력). `CustomStringConvertible`로 가린다
- fable 11: `--version` 출력을 trim한다(파싱 못 한 버전 문자열이 제목에 줄바꿈째 들어갔다)
- codex 2: 서버 오류 메시지에 키가 섞여 오면 `<key>`로 바꾼다(테스트)
- codex 3: `message_stop` 뒤의 이벤트는 무시한다(테스트: 뒤에 온 text·refusal이 답을 바꾸지 않는다)
- 확인한 것: URLSession은 Content-Type이 없으면 MIME 판별에 앞 512바이트를 붙잡아 두어 스트리밍이 멈춘다. 실제 API는 `text/event-stream`을 보내므로 가짜도 그렇게 한다. fallback 블록 모양(`content_block_start`의 `{"type":"fallback","to":{"model"}}`, 별도 SSE 이벤트 없음)은 claude-api 스킬 문서와 맞다
- 받지 않음: `.unreadable` 에러(codex 4: `.failed`에 stderr 한 줄이 같은 일을 한다), 완료 뒤 hook 해제(codex 5, fable 9: 질문마다 `Cancel` 하나라 무해. 이어 묻기에서 토큰을 다시 쓰게 되면 M3-7에서), `Background`의 에러 타입 일반화(계획 R2: 이번에는 부르는 곳이 없다. M3-7 UI가 부를 때)

## ponytail-review 반영
- HTTP 오류 본문은 SSE `error` 이벤트와 같은 모양이라 따로 둔 `Body` 구조체 대신 `ApiEvent`로 읽는다
- 최소 버전 표시는 `shown(minimumCli)`
- 남김: `chooseBackend`·`findClaude`는 아직 부르는 곳이 없지만(M3-7) PRD §6의 고르는 규칙이라 테스트와 함께 둔다
