# 계획: M4-2 서명과 공증

> TASKS M4-2: M0-3에서 정한 형태로 Developer ID 서명, notarytool, staple. ✓ 새 Mac 계정에서 다운로드 후 Gatekeeper 경고 없이 실행

등급: 위험 큼(CI가 서명 인증서와 Apple 계정 비밀을 다룬다, 남이 받아 실행할 바이너리) → 계획 리뷰 codex + fable, 구현 리뷰 codex + fable, 마지막 ponytail-review

## 현재 상태
- 배포 형태는 `.app` + CLI 심링크(M0-3, PRD F-IN-4). `scripts/bundle.sh`가 arm64 release를 `.build/griiy.app`에 담고 **ad hoc** 서명한다. CI(`ci.yml`)가 매 push에 돌린다
- 이 Mac의 키체인에는 Developer ID Application 인증서가 없다(`security find-identity`에 다른 사람의 Apple Development/Distribution만). 그래서 실제 서명·공증은 CI에서만 한다
- codespark(같은 사용자의 앱)의 `release.yml`이 Developer ID 서명·공증을 이미 한다: 비밀 5개(`DEVELOPER_ID_CERT_BASE64`, `DEVELOPER_ID_CERT_PASSWORD`, `APPLE_ID`, `APPLE_APP_PASSWORD`, `APPLE_TEAM_ID`)를 임시 키체인에 넣고, hardened runtime + timestamp로 서명, zip을 `notarytool submit --wait`, `stapler staple`. griiy 저장소에는 비밀이 아직 없다
- 확인: `swift build -c release --arch arm64 --arch x86_64`가 된다(`.build/apple/Products/Release/griiy`, universal 2.7MB)

## 설계

### 1. `scripts/bundle.sh`
- universal로 빌드한다(`--arch arm64 --arch x86_64`). 로컬 `--install`도 같은 길이라 개발자가 쓰는 것과 배포되는 것이 같다
- 버전: `VERSION` 환경변수(기본 `0.1.0`) → `CFBundleShortVersionString`과 `CFBundleVersion`
- 서명: **언제나 hardened runtime**(`--options runtime`). `GRIIY_SIGN`(서명 identity)이 있으면 그것과 `--timestamp`, 없으면 ad hoc(`-`). 로컬·CI 검사에서도 배포본과 같은 runtime 제약을 받아, git·gh·claude 실행이나 네트워크가 runtime에서 막히면 공증 전에 보인다
- entitlements는 두지 않는다: 샌드박스가 아니고, JIT·dyld 환경변수·서명 안 된 라이브러리를 쓰지 않는다. 자식 프로세스(git 등)는 자기 서명으로 돈다

### 2. `.github/workflows/release.yml` (새로)
- 트리거: `v*` 태그 push와 `workflow_dispatch`(태그 없이 서명·공증을 시험)
- 단계: checkout → 임시 키체인에 p12 넣기(codespark와 같은 명령, 끝에 `if: always()`로 지움) → identity는 그 키체인에서 `Developer ID Application`을 찾아 SHA-1로(이름을 워크플로에 박지 않는다) → `VERSION=${GITHUB_REF_NAME#v}`(태그일 때만) `GRIIY_SIGN=<sha1> scripts/bundle.sh` → `codesign --verify --strict --verbose=2` → `ditto -c -k --keepParent`로 zip → `notarytool submit --wait`, 출력에 `status: Accepted`가 없으면 `notarytool log`를 찍고 실패 → `stapler staple` → `stapler validate`와 `spctl --assess --type execute -vv`(`source=Notarized Developer ID`) → staple된 앱을 다시 zip(`griiy-<ver>.zip`) → `actions/upload-artifact`
- 비밀은 `env:`로만 넘기고 `set -x`를 쓰지 않는다. p12는 `$RUNNER_TEMP`에 쓰고 지운다
- GitHub Release 올리기와 Homebrew cask는 M4-3

### 3. 사용자가 할 일 (내가 할 수 없다)
- griiy 저장소에 비밀 5개를 넣는다(codespark와 같은 값): `gh secret set <NAME> -R jinto/griiy`
- ✓ 확인: Actions에서 release를 `workflow_dispatch`로 돌려 받은 zip을 새 macOS 사용자 계정에서 브라우저로 내려받아 연다

## 테스트
- 셸 스크립트·워크플로라 단위 테스트는 없다. 로컬에서:
  - `scripts/bundle.sh` → `lipo -archs`가 `x86_64 arm64`, `codesign -dv`에 `flags=0x10002(adhoc,runtime)`, Info.plist 버전
  - **runtime에서 실제로 돈다:** 번들 바이너리를 `GRIIY_MARK=<file>`로 이 저장소에 띄워 mark 두 줄(첫 페인트 = git이 돈 뒤)이 생기는지. PR(`'#n'`, gh)도 한 번
  - `VERSION=1.2.3 scripts/bundle.sh` → plist에 1.2.3
- CI: 비밀이 생긴 뒤 `workflow_dispatch`로 한 번 돌려 spctl까지 초록인지(사용자가 비밀을 넣은 뒤)

## 하지 않는 것
- GitHub Release 업로드, dmg, Homebrew cask(M4-3)
- 앱 아이콘, Sparkle 같은 자동 업데이트
- App Store

## 리뷰에 묻는 점
1. 로컬 ad hoc에도 hardened runtime을 거는 것
2. 로컬 `--install`까지 universal로 빌드하는 것(빌드 시간 약 2배) vs CI에서만
3. zip vs dmg(M4-3의 cask는 zip이면 충분하다)

## 계획 리뷰 (codex + fable) 반영
위 설계보다 이 절이 우선한다. fable이 실측: universal 바이너리를 ad hoc + `--options runtime`으로 서명하면 돌고(`flags=0x10002(adhoc,runtime)`), 시스템 라이브러리만 링크한다.
- R1 (fable 1): `--arch`를 주면 결과가 `.build/apple/Products/Release/`에 생기고 `.build/release`는 옛 arm64 그대로다. 경로는 `swift build … --show-bin-path`로 얻는다. CI의 바이너리 크기도 번들 안의 바이너리를 잰다
- R2 (Q2 둘 다): universal은 **release 워크플로에서만**(`GRIIY_ARCHS="--arch arm64 --arch x86_64"`). 매 push CI와 로컬 `--install`은 이 Mac 아키텍처 하나. 로컬은 x86_64 조각을 어차피 실행하지 않는다
- R3 (Q1 둘 다): 로컬 ad hoc에도 hardened runtime. 디버거는 번들이 아니라 `.build/debug/griiy`에 붙인다(fable)
- R4 (codex 2): 수동 실행의 버전은 `0.0.<run_number>`, 태그면 `${GITHUB_REF_NAME#v}`
- R5 (fable 3): identity를 못 찾으면 `::error::`로 바로 실패(빈 문자열로 codesign하지 않는다)
- R6 (codex 5): `notarytool submit --wait --output-format json`의 `status`가 `Accepted`가 아니면 `notarytool log`를 찍고 실패. `--timeout 30m`(fable 4: 공증 서비스가 멈추면 6시간을 기다린다)
- R7 (codex 4, fable 5): p12와 키체인을 같은 `if: always()` 단계에서 지운다. `permissions: contents: read`(올리기는 M4-3). runner는 `macos-26`으로 고정(CI가 지금 도는 이미지. `-warnings-as-errors`라 도구 체인이 바뀌면 다시 태그할 수 없는 release가 깨진다)
- R8 (fable 2): ad hoc 서명의 designated requirement는 cdhash라 빌드마다 키체인에는 다른 앱이다. Developer ID면 `identifier "dev.griiy.griiy" and anchor apple generic … OU = <team>`로 버전이 바뀌어도 같다. M0-3 ②(재빌드 후 키체인을 다시 묻는가)는 Developer ID 빌드로만 답할 수 있다: M0-3에 적는다. M3-6이 data protection keychain을 쓰면 application-identifier entitlement가 필요하다(그때)
- R9 (fable 6): ✓의 기준: 공증된 앱도 처음 열 때 "인터넷에서 받은 앱… Apple이 확인했다" 대화상자는 한 번 뜬다. 실패는 "Apple이 확인할 수 없다"·악성 경고다. upload-artifact는 zip을 한 번 더 싸므로 두 번 푼다(격리 속성은 따라간다). 새 계정에 Xcode CLT가 없으면 git 설치 안내가 뜬다: Gatekeeper 문제와 헷갈리지 않게 적는다
- 받지 않음: `notarytool store-credentials`(codex 4: 비밀번호가 `ps`에 보이는 것은 한 번 쓰고 버리는 runner라 무해하다, fable 5), dmg(Q3 둘 다 zip)

## 구현 리뷰 (codex + fable) 반영
fable이 계획 R1–R9가 모두 들어갔고, `codesign`과 `stapler staple` 사이에 번들을 바꾸는 단계가 없으며, `GITHUB_ENV`로 넘기는 `GRIIY_SIGN`·`VERSION`이 맞게 이어진다고 확인했다. hardened runtime 번들을 `GRIIY_MARK`로 띄워 git 실행·첫 페인트·스크롤 mark까지 확인했다(entitlements 없음, `get-task-allow` 없음).
- fable 1: `lipo -archs`는 찍기만 했다. 조각 하나가 빠져도 초록으로 공증·업로드된다 → `lipo -verify_arch arm64 x86_64`(arm64만이면 실패하는 것을 로컬에서 확인)
- fable 2: identity를 못 찾으면 `-v` 없는 `find-identity`(이름과 해시만)를 찍는다. 중간 인증서가 없어 체인 검증이 실패한 경우를 구별한다
- fable 3: `--wait`가 Accepted를 준 직후 `stapler staple`이 65로 실패할 수 있다(티켓 전파 전). job을 다시 돌리면 된다(같은 해시는 곧바로 Accepted). 주석으로 남기고 재시도 루프는 두지 않는다
- fable 4: `stapler validate`를 뺐다. `spctl --assess`(`source=Notarized Developer ID`)가 Gatekeeper의 답이다
- codex 1: `GRIIY_ARCHS`를 일부러 따옴표 없이 펼치므로 `set -f`로 glob을 막는다
- codex 2: `notarytool submit`의 종료 코드도 본다(`status`만이 아니라)
- 받지 않음: 비밀번호가 argv에 보이는 것(codex 3: 계획 리뷰에서 받지 않음. 한 번 쓰고 버리는 runner이고, 악성 태그라면 이미 비밀이 든 환경에서 코드를 돌린다)

## ponytail-review 반영
- `stapler validate`(fable 4)만. 나머지는 줄일 곳이 없다: `codesign --verify`는 공증 전에 읽을 수 있는 로그를 주고, `auth` 배열은 submit과 log 두 곳에서 쓴다
