<p align="center">
  <img src="icon.png" width="180" alt="AIShot icon">
</p>

<h1 align="center">AIShot</h1>

<p align="center">
  단축키 한 번: 스크린샷 → <b>지금 대화 중인 AI 앱에 바로</b>.<br>
  <i>Finder 뒤지기 없음 · 드래그&드롭 없음 · 메뉴 막대에서 목적지 바로 전환</i>
</p>

<p align="center"><a href="README.md">English</a></p>

---

단축키 → 영역 드래그(<kbd>Space</kbd>로 창 선택, <kbd>Esc</kbd> 취소) → PNG가
기존 스크린샷 폴더에 저장되는 **동시에**, [메뉴 막대 또는 설정](#메뉴-막대)에서
고른 목적지로 들어간다:

| 목적지 설정 | 모든 캡처가 가는 곳 | 붙여넣는 형식 |
|---|---|---|
| 특정 앱 — Claude, Antigravity, ChatGPT, Codex 또는 다른 앱 | 무엇이 최전면이었든 그 앱. 필요하면 기본적으로 AIShot이 앱을 실행 | **자동**, **PNG 이미지**, **파일 경로** 중 설정 가능 |
| 목적지 **Automatic** + 최전면 터미널·IDE — Ghostty, Terminal, iTerm2, kitty, WezTerm, Warp, VS Code, Antigravity, Cursor | 최전면 앱 | Paste as **Automatic**일 때: 이스케이프된 **파일 경로** + 자동 ⌘V |
| 목적지 **Automatic** + 최전면 AI 앱·브라우저 — Claude, Codex, ChatGPT, Gemini, Safari, Chrome | 최전면 앱 | Paste as **Automatic**일 때: **PNG 이미지** + 자동 ⌘V |
| 목적지 **Automatic** + 그 외 모든 앱 | 클립보드 복사만 하고 ⌘V는 보내지 않음 | Paste as **Automatic**일 때: 수동으로 붙여넣을 수 있는 **PNG 이미지** |

모든 캡처는 macOS 기본 파일명(`Screenshot 2026-07-08 at 11.09.27 AM.png`)의
**파일로도 저장**되므로 붙여넣기와 아카이빙이 한 동작에 끝난다.

**저장 폴더 설정은 필요 없음**: AIShot은 macOS가 ⌘⇧3/4/5 스크린샷을 저장하는 폴더에
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

AIShot은 제어와 캡처를 분리한다. 가벼운 **메뉴 막대 호스트** 하나가 목적지
전환을 위해 대기하고, 실제 캡처는 매번 별도의 단기 프로세스에서 실행되어
저장·붙여넣기가 끝나는 즉시 종료된다.

## 메뉴 막대

`build.sh`는 메뉴 막대 호스트 하나를 설치해 즉시 시작하고, 사용자 LaunchAgent로
등록해 로그인할 때마다 다시 띄운다. 뷰파인더 아이콘을 누르면 다음 항목이 나온다:

- **Capture Screenshot…** — 단축키와 같은 일회성 영역 캡처를 시작.
- **Destination: _현재 앱_** — **Automatic (Frontmost App)**과 설치된 프리셋
  사이를 빠르게 전환. 현재 선택에는 체크 표시가 붙고,
  **More Destinations in Settings…**에서 전체 선택창을 연다.
- **Settings…** — 어떤 앱이든 목적지로 고르고 붙여넣기 형식, 목적지 자동 실행,
  포커스 복귀를 설정하는 기본 진입점.
- **Open Screenshot Folder** — 현재 AIShot 저장 폴더 열기.
- **Quit AIShot** — 이번 세션의 메뉴 호스트 종료. 다음 로그인 때 LaunchAgent가
  다시 시작한다.

메뉴 아이콘이 보이지 않으면 단일 호스트를 직접 시작할 수 있다:

```sh
open -gn "$HOME/Applications/AIShot.app" --args --menubar
```

## 지정 앱 — 어디서 찍든 한 곳으로

**AIShot 메뉴 막대 → Settings…**를 연다. Claude, Antigravity, ChatGPT,
Codex, Gemini 같은 프리셋을 고르거나
**Choose Other…**로 설치된 어떤 `.app`이든 선택할 수 있다. 목적지를 지정하면
**어떤 앱이 최전면이었는지와 무관하게 모든 캡처가 그곳으로 간다**.

같은 설정창에서 다음 항목도 고를 수 있다:

- **Paste as**: **Automatic**은 알려진 터미널·IDE 목적지에는 파일 경로를,
  그 외 목적지에는 PNG를 쓴다. **PNG image** 또는 **File path**로 형식을
  고정할 수도 있으며 목적지가 Automatic일 때도 이 설정이 적용된다.
- **Open the destination app when it is not running**: 기본으로 켜져 있다.
  지정 앱이 꺼져 있으면 AIShot이 실행하고 최전면으로 가져와 붙여넣는다.
  앱을 실행하거나 활성화하지 못하면 ⌘V를 보내지 않고 캡처를 클립보드에
  남긴다(PNG 파일 저장은 항상 완료됨).
- **Return to the previous app after pasting**: 기본으로 꺼져 있어 붙여넣은 뒤
  지정 앱에 포커스가 남고, 바로 프롬프트를 입력할 수 있다.
- 목적지의 **Automatic (frontmost app)**: 기존 최전면 라우팅을
  그대로 유지한다. Paste as도 **Automatic**일 때 알려진 터미널·IDE에는 경로,
  알려진 AI 앱·브라우저에는 PNG를 보내고, 지원하지 않는 앱에서는 클립보드
  복사만 한다.

### 고급: CLI와 `defaults`

일반적인 설정은 메뉴 막대를 쓰면 된다. 스크립트나 dotfiles에서는 같은 설정창과
값을 CLI로도 열거나 지정할 수 있다:

```sh
# 메뉴 없이 같은 설정창 열기
open -na "$HOME/Applications/AIShot.app" --args --settings

# 목적지 지정
defaults write com.techjuicelab.aishot targetApp claude

# auto | image | path
defaults write com.techjuicelab.aishot targetPasteMode image

# 선택: 꺼진 목적지를 실행하지 않기, 붙여넣은 뒤 원래 앱으로 돌아오기
defaults write com.techjuicelab.aishot autoLaunchTarget -bool false
defaults write com.techjuicelab.aishot returnFocus -bool true

# 목적지를 Automatic으로 복원
defaults delete com.techjuicelab.aishot targetApp
```

목적지 별칭: `claude` · `codex` · `chatgpt` · `gemini` · `antigravity` ·
`antigravity-ide` · `cursor` · `vscode` · `safari` · `chrome`. 그 외 앱은
선택창에서 고르거나 번들 ID로 지정한다
(`osascript -e 'id of app "SomeApp"'`).

포커스와 무관하게 이번 실행만 특정 앱으로 보내는 핫키도 만들 수 있다.
`--target`은 이번 실행에만 적용되고 저장된 목적지보다 우선한다:

```sh
open -gn "$HOME/Applications/AIShot.app" --args --target codex
```

현재 설정으로 어떻게 동작할지는 `--self-test`로 미리 확인할 수 있다.

## 설치

macOS 14 이상 (Apple Silicon / Intel).

**소스에서 빌드** (Xcode Command Line Tools 필요) — 권장, Gatekeeper 걸릴 일 없음:

```sh
git clone https://github.com/techjuicelab/aishot.git
cd aishot && ./build.sh   # 빌드·서명·설치 후 메뉴 막대 호스트 시작
```

`build.sh`는 AIShot을 `~/Applications`에 설치하고
`~/Library/LaunchAgents/com.techjuicelab.aishot.menubar.plist`을 만든 뒤 메뉴
호스트를 즉시 시작한다. 이후 로그인 때마다 호스트가 자동으로 뜨며, 실제 캡처는
계속 별도의 일회성 프로세스로 실행된다.

**또는** [Releases](https://github.com/techjuicelab/aishot/releases)에서
`AIShot.app.zip`을 받아 `~/Applications`에 풀기. 공증(notarize)되지 않은 앱이라
다운로드에 격리 플래그가 붙는다 — 아래 명령으로 제거하거나

```sh
xattr -dr com.apple.quarantine ~/Applications/AIShot.app
```

한 번 실행한 뒤 시스템 설정 → 개인정보 보호 및 보안 → "그래도 열기"로 승인
(macOS 15부터는 우클릭 → 열기 우회가 더 이상 통하지 않는다).
다운로드한 앱 번들은 `build.sh`를 실행하지 않으므로, 승인 후 위의
`--menubar` 명령으로 현재 세션의 메뉴 호스트를 시작한다.

## 단축키

쓰고 있는 런처 아무거나 아래 명령에 연결:

```sh
open -gn "$HOME/Applications/AIShot.app" --args --capture
```

인자 없이 실행해도 같은 일회성 캡처이므로 기존 런처와 Karabiner 룰은 그대로
동작한다.

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

**서명과 권한 유지**: `build.sh`는 키체인에 유효한 코드 서명 ID
`TechJuice Local Code Signing`이 있으면 자동으로 사용한다. 이 인증서의 안정적인
designated requirement 덕분에 이후 재빌드에서도 화면 기록·손쉬운 사용 권한이
유지되며, 스크립트의 `codesign` 줄을 직접 바꿀 필요가 없다.

해당 인증서가 없으면 애드혹 서명으로 대체되어 업데이트 후 권한을 다시 승인해야
할 수 있다. 설치기는 새 앱과 기존 설치본의 designated requirement를 비교해,
같으면 TCC 권한을 보존하고 서명 ID가 달라졌을 때만
`tccutil reset All com.techjuicelab.aishot`을 실행한다. 이 경우 다음 캡처에서
권한을 깔끔하게 다시 요청한다.

## 플래그

```sh
open -gn "$HOME/Applications/AIShot.app" --args --mode image
```

| 플래그 | 설명 | 기본값 |
|---|---|---|
| `--capture` | 영역 캡처 한 번 실행 후 종료 (인자 없는 실행의 명시적 별칭) | 인자 없는 기본 동작 |
| `--menubar` | **Quit AIShot** 전까지 단일 상주 메뉴 호스트 실행 | 설치된 LaunchAgent가 사용 |
| `--mode auto\|path\|image` | 자동 감지 대신 붙여넣기 형식 강제 | `auto` |
| `--target 별칭\|번들ID` | 이번 실행은 무조건 이 앱으로 (저장된 목적지보다 우선) | — |
| `--out DIR` | 저장 폴더 (이번 실행만) | 위 저장 폴더 순서 참고 |
| `--choose-dir` | 폴더 선택창을 열어 앱 기본 저장 폴더로 저장 | — |
| `--settings` | 목적지·붙여넣기 형식·자동 실행·포커스 설정창 열기 | — |
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
launchctl bootout "gui/$UID/com.techjuicelab.aishot.menubar" 2>/dev/null || true
rm -f ~/Library/LaunchAgents/com.techjuicelab.aishot.menubar.plist
rm -rf ~/Applications/AIShot.app
tccutil reset All com.techjuicelab.aishot
defaults delete com.techjuicelab.aishot 2>/dev/null
# 런처/Karabiner에서 핫키 룰 제거
```

로그: `/tmp/aishot.log`

## 라이선스

[MIT](LICENSE) © TechJuiceLab
