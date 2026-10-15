# 계획: M1-7 bench 확장

> TASKS M1-7: 행 뷰 수, 자동 스크롤 long-frame 집계, JSON 출력. ✓ CI 아티팩트로 저장 (참고용, 실패 기준 아님)

등급: 작음 (스크립트 한 줄 + CI 단계 하나, 앱 코드 변경 없음)

## 현재 상태
- 행 뷰 수(`views`, `viewsMax`), long-frame(`scroll.long/frames/max/median`), 트리 뷰 수는 앱이 `GRIIY_MARK` 파일에 JSON 두 줄로 이미 쓴다
- `scripts/bench.sh`는 실행마다 `round=1 app=griiy … first={…} scroll={…}` 꼴의 key=value 한 줄을 낸다. 기계가 읽기 어렵다(JSON 출력이 남은 일)
- CI(`ci.yml`의 `check`)는 bench를 돌리지 않는다. bench용 큰 저장소를 만드는 스크립트도 저장소에 없다(측정 때는 손으로 만들었다)

## 확인한 사실
- 로컬에서 300파일 × 500줄 새 파일 저장소(`HEAD~1..HEAD`, 15만 600행)로 `bench.sh 1` 한 번이 약 15초, `status=ok`, paint 585ms, long 0/590
- 앱은 `GRIIY_MARK`가 있으면 저장소 고르기·토큰 시트 같은 대화 상자를 띄우지 않는다(`main.swift` 321행)
- GitHub macOS 러너는 로그인된 GUI 세션이 있다(창을 띄울 수 있다). 실제로 되는지는 CI에서 확인한다

## 설계
1. `bench.sh`의 출력 줄을 JSON 한 줄(JSON Lines)로 바꾼다. 줄은 `jq -nc … '$ARGS.named'`가 만든다(macOS 15 이상에 `/usr/bin/jq`가 있다. 앱도 macOS 15 이상):
   `{"round":1,"app":"griiy","repo":"big","paint":585,"fp":72,"rss":124,"status":"ok","first":{…},"scroll":{…}}`
   - `paint`·`fp`·`rss`는 숫자(ms, MB). 못 잰 값은 `null`(지금의 `?`). `first`·`scroll`은 mark 줄에서 `"type":"mark",`를 뺀 객체 그대로, 없으면 `null`
   - 기다리는 동안 앱이 끝나면 바로 `FAILED(exited)`(150초를 다 기다리지 않는다). 두 번째 mark가 `"scroll":null`(에러 화면, 빈 diff)이면 `FAILED(no scroll)`. 이때 `fp`·`rss`는 0일 수 있다: `status`가 `ok`인 줄만 의미가 있다
   - 사람이 읽기에도 지금과 같은 정보다. 따로 `--json` 옵션을 두지 않는다
2. `ci.yml`의 `check`에 단계 두 개 (bundle 뒤):
   - `Bench (reference only)`: `continue-on-error: true`. `$RUNNER_TEMP/big`에 위 확인과 같은 저장소(빈 커밋 → 300파일 × 500줄, 커밋은 `git -c user.name=… -c user.email=…`)를 만들고 `scripts/bench.sh 3 griiy=.build/release/griiy -- "$RUNNER_TEMP/big:HEAD~1..HEAD" | tee bench.jsonl`. `timeout-minutes: 10`(실행마다 최악 약 160초)
   - `actions/upload-artifact@v4`로 `bench.jsonl`(`if: always()`, `continue-on-error: true`, `if-no-files-found: ignore`). 업로드 실패도 `check`를 막지 않는다
   - 3라운드 × 약 15초 ≈ 1분. 저장소는 스크립트 파일로 따로 두지 않고 단계 안에 쓴다(몇 줄)
3. CONTRIBUTING의 bench 설명에 "JSON 한 줄씩, CI가 artifact `bench`로 저장"을 덧붙인다

## 테스트 (먼저)
- 셸 스크립트라 단위 테스트는 두지 않는다. 확인: 로컬 실행 결과를 `jq -c .`로 줄마다 파싱 → 모든 줄이 통과. mark 파일이 없을 때(잘못된 바이너리 경로)도 `null`로 파싱되는지
- CI: PR에서 `check`가 초록이고 artifact `bench`에 3줄이 있다

## 계획 리뷰 (codex + opus) 반영
fable은 사용 한도로 돌지 못해 opus가 대신했다
- codex 4, opus 1: 러너에 git 사용자가 없다 → 커밋에 `-c user.name/-c user.email`
- codex 1, opus 2: 대기 150초 × 3이 5분을 넘는다 → 대기 중 `kill -0`으로 앱이 끝났으면 바로 실패, `timeout-minutes: 10`
- codex 5·6, opus 4: 손으로 만든 JSON은 따옴표·빈 mark 줄에서 깨진다 → `jq --arg/--argjson`, 없는 값은 `null`
- codex 9: 에러 화면·빈 diff도 `ok`였다 → `"scroll":null`이면 `FAILED(no scroll)`. opus 3: 그때 `fp`·`rss` 0은 `status`로 거른다
- codex 3: 업로드 실패도 `check`를 떨어뜨린다 → 업로드에도 `continue-on-error`
- codex 2, opus 5: 러너의 GUI는 첫 PR에서 artifact의 `status`로 확인한다(초록만 보지 않는다)
- 받지 않음: 정리용 `trap`(codex 8, opus 7: 러너가 job 끝에 남은 프로세스를 정리한다), 줄 수 검증·pipefail(codex 7, opus 8: 참고용 단계라 `status`로 충분), 따로 둔 bench job(codex 3, opus 10: release 빌드를 한 번 더 한다), 러너의 다른 WebKit 프로세스가 `FAILED(n new WebKit helpers)`를 낼 수 있음(opus 6: 참고용, 보이면 고친다), `.app` 안의 바이너리(opus 9: 지금까지의 측정과 같은 `.build/release/griiy`)

## 구현 리뷰 (codex + opus) 반영
- opus 1, codex 2: 반쯤 쓴 mark 줄(150초 timeout 길)이면 `--argjson`이 실패해 그 실행의 줄이 사라진다 → mark 줄은 `--arg`로 넘기고 jq가 `try fromjson catch null`
- opus 2: WebKit 도우미 검사가 앞의 실패 이유를 덮는다 → `status`가 `ok`일 때만
- opus 3: `footprint`가 실패하면 `fp: 0`인데 `status: ok`다 → 첫 CI artifact에서 `fp`가 0이 아닌지 본다(코드 변경 없음)
- 받지 않음: 정리용 `trap`(codex 1: 계획 리뷰와 같은 이유)

## ponytail-review 반영
- mark 줄의 `"type":"mark"` 빼기를 sed 두 번 대신 jq 한 식으로(`(.first, .scroll) |= (try (fromjson | del(.type)) catch null)`)

## 하지 않는 것
- 실패 기준(첫 화면 < 1s 등)으로 CI를 막지 않는다(TASKS: 참고용). 러너 성능이 들쭉날쭉하다
- 1만 파일 트리·12만 줄 한 파일 저장소는 CI에서 돌리지 않는다(시간). 필요하면 같은 단계에 저장소를 더한다
- 라운드 중앙값 요약은 내지 않는다(jq로 볼 수 있다)
