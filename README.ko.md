<p align="center">
  <img src="icon.png" width="180" alt="AIShot icon">
</p>

<h1 align="center">AIShot</h1>

<p align="center">
  단축키 한 번: 스크린샷 → <b>지금 대화 중인 AI 앱에 바로</b>.<br>
  <i>Finder 뒤지기 없음 · 드래그&드롭 없음 · 상주 프로세스 없음</i>
</p>

<p align="center"><a href="README.md">English</a></p>

---

단축키 → 영역 드래그(<kbd>Space</kbd>로 창 선택, <kbd>Esc</kbd> 취소) → PNG가
기존 스크린샷 폴더에 저장되는 **동시에**, 단축키를 누른 순간 최전면에 있던
앱으로 들어간다:

| 최전면 앱 | 붙여넣는 것 | 이유 |
|---|---|---|
| 터미널·IDE — Ghostty, Terminal, iTerm2, kitty, WezTerm, Warp, VS Code, Antigravity, Cursor | 이스케이프된 **파일 경로** + 자동 ⌘V | Claude Code·Codex CLI는 경로로 이미지를 읽음 (드래그&드롭과 같은 형식) |
| AI 앱·브라우저 — Claude, Codex, ChatGPT, Gemini, Safari, Chrome | **PNG 이미지** + 자동 ⌘V | 채팅 입력창에 이미지로 첨부 |
| 그 외 모든 앱 | **지정 앱**([아래](#지정-앱--어디서-찍든-한-곳으로)) 설정 시: 그 앱으로 전환해 붙여넣기. 미설정 시: 클립보드 복사만 | 어디서 찍든 스크린샷이 늘 내 AI 앱에 도착 — 지정 안 했으면 엉뚱한 곳에 붙는 사고 방지 |

모든 캡처는 macOS 기본 파일명(`Screenshot 2026-07-08 at 11.09.27 AM.png`)의
**파일로도 저장**되므로 붙여넣기와 아카이빙이 한 동작에 끝난다.

**설정 필요 없음**: AIShot은 macOS가 ⌘⇧3/4/5 스크린샷을 저장하는 폴더에
그대로 저장한다. 스크린샷 폴더를 옮겨놨다면(시스템 설정 /
`defaults write com.apple.screencapture location`) 자동으로 따라간다.
일반 스크린샷과 **다른** 폴더에 AIShot 캡처만 모으고 싶을 때만 내장 폴더
선택창을 한 번 실행하면 된다:

```sh
open -na AIShot --args --choose-dir
```

전체 우선순위: `--out DIR` 플래그 → 앱 자체 폴더(`--choose-dir` 또는
`defaults write com.techjuicelab.aishot saveDir ...`) → 시스템 스크린샷 폴더
→ `~/Desktop`(macOS 순정 기본값).

AIShot은 **호출될 때만 실행**된다 — 캡처하고, 붙여넣고, 종료.
메뉴 막대 아이콘도, 데몬도 없고, 대기 중 점유율은 0이다.

## 지정 앱 — 어디서 찍든 한 곳으로

위 표의 첫 두 줄(터미널·IDE·AI 앱에 포커스 중)은 지금처럼 **그 자리에**
붙여넣는다. 지정 앱은 그 외 "모르는 앱"에 포커스가 있을 때의 목적지다 —
한 번 설정해두면 AIShot이 캡처 후 그 앱으로 전환해서 붙여넣는다:

```sh
defaults write com.techjuicelab.aishot targetApp claude
```

별칭: `claude` · `codex` · `chatgpt` · `gemini` · `antigravity` · `cursor` ·
`vscode` · `safari` · `chrome`. 그 외 앱은 번들 ID를 그대로 적는다
(`osascript -e 'id of app "SomeApp"'`).

- 지정 앱이 **실행 중일 때만** 붙여넣는다 — 꺼져 있으면 앱을 띄우지 않고
  클립보드 복사까지만 한다 (파일 저장은 항상 됨).
- 붙여넣는 형식은 앱 분류를 따른다: Antigravity·Cursor처럼 터미널·IDE로
  분류된 앱이면 파일 경로, Claude·Codex 같은 채팅 앱이면 PNG 이미지.
- 붙여넣은 뒤 포커스는 지정 앱에 남는다(바로 프롬프트 타이핑). 캡처 전에
  쓰던 앱으로 자동 복귀하고 싶으면:

  ```sh
  defaults write com.techjuicelab.aishot returnFocus -bool true
  ```

- 해제: `defaults delete com.techjuicelab.aishot targetApp`

포커스와 무관하게 **무조건** 특정 앱으로 보내는 핫키를 따로 만들 수도 있다 —
`--target`은 이 실행에만 적용되고 저장된 지정 앱보다 우선한다:

```sh
open -gn "$HOME/Applications/AIShot.app" --args --target codex
```

현재 설정으로 어떻게 동작할지는 `--self-test`로 미리 확인할 수 있다.

## 설치

macOS 14 이상 (Apple Silicon / Intel).

**소스에서 빌드** (Xcode Command Line Tools 필요) — 권장, Gatekeeper 걸릴 일 없음:

```sh
git clone https://github.com/techjuicelab/aishot.git
cd aishot && ./build.sh   # 빌드 → 애드혹 서명 → ~/Applications 설치
```

**또는** [Releases](https://github.com/techjuicelab/aishot/releases)에서
`AIShot.app.zip`을 받아 `~/Applications`에 풀기. 공증(notarize)되지 않은 앱이라
다운로드에 격리 플래그가 붙는다 — 아래 명령으로 제거하거나

```sh
xattr -dr com.apple.quarantine ~/Applications/AIShot.app
```

한 번 실행한 뒤 시스템 설정 → 개인정보 보호 및 보안 → "그래도 열기"로 승인
(macOS 15부터는 우클릭 → 열기 우회가 더 이상 통하지 않는다).

## 단축키

쓰고 있는 런처 아무거나 아래 명령에 연결:

```sh
open -gn "$HOME/Applications/AIShot.app"
```

- **Karabiner-Elements**:

  ```sh
  mkdir -p ~/.config/karabiner/assets/complex_modifications
  cp karabiner/aishot.json ~/.config/karabiner/assets/complex_modifications/
  ```

  그다음 Karabiner-Elements → Complex Modifications → Add predefined rule에서
  "AIShot" 활성화. 기본 키는 <kbd>⌘⇧2</kbd> — 시스템 ⌘⇧3/4/5 스크린샷
  패밀리 옆자리. **양쪽 <kbd>⇧</kbd> 동시 누르기** 룰(Codex 스타일)도 같이
  들어 있으니 원하면 추가로 활성화.
- **Alfred / Raycast / 단축어 앱**: 같은 `open` 명령에 핫키 지정.

## 첫 실행 권한 (한 번만)

1. 첫 단축키 → **화면 기록** 프롬프트가 뜨고 앱은 캡처 없이 종료
   (시스템 설정 → 개인정보 보호 및 보안 → 화면 및 시스템 오디오 기록 → AIShot 허용).
2. 다시 단축키 → 캡처 UI. 저장 시점에 스크린샷 폴더(iCloud Drive/데스크탑)에 대한
   **파일 및 폴더** 프롬프트가 나올 수 있다 — 거부하면 저장이 안 되니 허용.
3. 첫 캡처 완료 후 → **손쉬운 사용** 프롬프트(자동 ⌘V용). 허용 전에는 클립보드
   복사까지만 동작하고, 허용한 다음 샷부터 자동 붙여넣기.

**재빌드 주의**: 애드혹 서명이라 재빌드하면 코드 해시가 바뀌어 기존 TCC 권한이
조용히 무효화된다 — 시스템 설정 토글은 켜져 보이지만 실제로는 무효(창 내용 없이
배경화면만 찍히는 증상). 그래서 `build.sh`가 설치 후
`tccutil reset All com.techjuicelab.aishot`을 실행해 다음 실행에서 프롬프트가
다시 뜨게 한다. 자주 재빌드한다면 키체인 접근 → 인증서 지원에서 코드 서명용
자체 서명 인증서를 만들어 `codesign` 라인을 바꾸면 권한이 빌드를 넘어 유지된다.

## 플래그

```sh
open -gn "$HOME/Applications/AIShot.app" --args --mode image
```

| 플래그 | 설명 | 기본값 |
|---|---|---|
| `--mode auto\|path\|image` | 자동 감지 대신 붙여넣기 형식 강제 | `auto` |
| `--target 별칭\|번들ID` | 이번 실행은 무조건 이 앱으로 (저장된 지정 앱보다 우선) | — |
| `--out DIR` | 저장 폴더 (이번 실행만) | 위 저장 폴더 순서 참고 |
| `--choose-dir` | 폴더 선택창을 열어 앱 기본 저장 폴더로 저장 | — |
| `--no-paste` | 클립보드 복사까지만, 자동 ⌘V 안 함 | — |
| `--timeout SEC` | 선택 UI 대기 시간 | `300` |
| `--self-test` | 폴더·최전면 앱·권한 상태만 출력하고 종료 | — |

## 커스터마이즈

**재빌드 없이** 앱 분류 추가 — AIShot은 실행 시 `defaults` 배열 두 개를 읽는다:

```sh
# 앱의 번들 ID 확인
osascript -e 'id of app "SomeTerm"'

defaults write com.techjuicelab.aishot extraPathApps  -array-add "com.example.someterm"
defaults write com.techjuicelab.aishot extraImageApps -array-add "com.example.chatapp"
```

또는 [`main.swift`](main.swift) 상단의 `pathPasteIDs` / `imagePasteIDs`를
수정하고 `./build.sh` 재실행.

## 제거

```sh
rm -rf ~/Applications/AIShot.app
tccutil reset All com.techjuicelab.aishot
defaults delete com.techjuicelab.aishot 2>/dev/null
# 런처/Karabiner에서 핫키 룰 제거
```

로그: `/tmp/aishot.log`

## 라이선스

[MIT](LICENSE) © TechJuiceLab
