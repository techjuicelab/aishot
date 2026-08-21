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
| 터미널 — Ghostty, iTerm2, Terminal, WezTerm, kitty, Warp | 그 안에 띄워 둔 CLI 에이전트 — Claude Code, Codex CLI, Gemini CLI. 터미널이 마지막으로 포커스하고 있던 창·탭·스플릿 | 이스케이프된 **파일 경로** + 자동 ⌘V, 원하면 이어서 <kbd>Enter</kbd> |
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
open -nb space.techjuicelab.aishot --args --choose-dir
```

전체 우선순위: `--out DIR` 플래그 → 앱 자체 폴더(`--choose-dir` 또는
`defaults write space.techjuicelab.aishot saveDir ...`) → 시스템 스크린샷 폴더
→ `~/Desktop`(macOS 순정 기본값).

AIShot은 제어와 캡처를 분리한다. 가벼운 **메뉴 막대 호스트** 하나가 목적지
전환을 위해 대기하고, 실제 캡처는 매번 별도의 단기 프로세스에서 실행되어
저장·붙여넣기가 끝나는 즉시 종료된다.

## 스크롤 캡처 — 창 전체를 한 장으로

<kbd>⌘⇧6</kbd>을 누르면 화면이 어두워지고 커서 아래 창이 밝게 표시된다. 캡처할
창을 클릭하면(<kbd>Esc</kbd> 취소) AIShot이 그 창을 맨 위로 되감은 뒤 바닥까지
스크롤하며 촬영하고, 겹치는 부분을 맞춰 **한 장의 긴 PNG**로 이어붙인다. 결과는
일반 캡처와 똑같이 저장되고 지정한 목적지로 간다.

브라우저만이 아니라 **스크롤되는 창이면 대체로 동작한다** — Safari, Chrome,
Firefox, 네이티브 앱 모두. 창 안의 스크롤 위치를 밖에서는 알 수 없기 때문에
스크롤 양을 픽셀 단위로 맞춰보며 이음새를 찾는 방식이고, 그래서 다음 두 가지는
한계로 남는다:

- **좌우로 고정된 사이드바**(예: Wikipedia 목차)는 세로로 반복해서 나타난다.
  내용은 온전하지만 여백에 잔상이 남는다.
- 재생 중인 영상이나 무한 스크롤 페이지는 이음새를 찾지 못해 도중에 멈출 수 있다.
  이때도 그 지점까지는 정확한 이미지가 남는다.

### 끝났다는 신호

캡처가 시작되면 시스템 스크린샷과 같은 셔터 소리가 나고, 끝나면 짧은 알림음과
함께 화면 위쪽에 `✓ 스크롤 캡처 완료 — 4개 프레임 · 2560×2027` 같은 패널이 잠깐
떴다 사라진다. 스크롤 캡처는 페이지에 따라 수십 초가 걸리고 그동안 화면에는
아무것도 없어서, 신호가 없으면 끝난 건지 멈춘 건지 알 수가 없다. 실패하면 다른
소리와 함께 이유를 설명하는 창이 뜬다.

알림 센터 배너도 권한이 허용돼 있으면 함께 뜬다. 다만 로컬 서명으로 빌드한
AIShot에는 macOS가 알림을 허용하지 않는 경우가 많아, 화면 패널 쪽이 실질적인
신호다.

```sh
defaults write space.techjuicelab.aishot scrollNotify -bool false   # 소리·알림 끄기
```

### 문자 인식 — 기본은 꺼져 있다

기본 동작은 스크린샷 그대로다: 전체 해상도 PNG를 저장하고 클립보드에 올린다.
문자 인식은 하지 않는다 — 긴 페이지에서는 캡처보다 인식이 더 오래 걸린다.

켜야 할 이유는 하나뿐이지만 중요하다. 이어붙인 페이지는 세로 3만 픽셀을 넘기기
일쑤인데 **Claude는 이미지를 긴 변 2576px로 줄여서 받는다.** 그림만 보내면 본문
글씨는 읽을 수 없는 크기로 도착한다. 긴 문서를 AI에게 읽히는 것이 목적이라면
**설정 → 스크롤 OCR**을 켜면 macOS Vision이 텍스트를 뽑아 함께 보낸다 — 이미지가
배치를, 텍스트가 내용을 담당한다. 한국어와 영어를 함께 인식하고, 네트워크도 API
키도 쓰지 않는다.

| 값 | 동작 |
|---|---|
| `off` (기본) | 문자 인식을 하지 않는다. 가장 빠르다 |
| `sidecar` | 이미지만 붙여넣고, 텍스트는 PNG 옆에 같은 이름의 `.txt`로 저장 |
| `doublePaste` | 이미지를 붙여넣은 뒤 클립보드를 텍스트로 바꿔 한 번 더 붙여넣는다 |
| `textOnly` | 텍스트만 붙여넣는다 |
| `auto` | 세로 8000px이 넘으면 텍스트만, 그보다 짧으면 이미지와 텍스트 둘 다 |

인식을 켜면 텍스트는 어느 방식이든 항상 `.txt`로도 저장된다. 클립보드는 사라지지만
파일은 남는다. **PNG는 어느 설정에서도 항상 전체 해상도로 저장된다** — 설정이
바꾸는 것은 클립보드로 무엇이 가느냐뿐이다.

```sh
defaults write space.techjuicelab.aishot scrollOcrMode doublePaste   # 기본 off
defaults write space.techjuicelab.aishot scrollMaxFrames -int 120   # 기본 60
```

`scrollMaxFrames`는 무한 스크롤 페이지에서 멈추지 않는 것을 막는 안전장치다.

## 메뉴 막대

`build.sh`는 메뉴 막대 호스트 하나를 설치해 즉시 시작하고, 사용자 LaunchAgent로
등록해 로그인할 때마다 다시 띄운다. 뷰파인더 아이콘을 누르면 다음 항목이 나온다:

- **Capture Screenshot…** — 단축키와 같은 일회성 영역 캡처를 시작.
- **Capture Scrolling Screenshot…** — 창을 골라 전체를 이어붙이는 캡처를 시작.
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
open -gnb space.techjuicelab.aishot --args --menubar
```

## 지정 앱 — 어디서 찍든 한 곳으로

**AIShot 메뉴 막대 → Settings…**를 연다. Claude, Antigravity, ChatGPT,
Codex, Gemini 같은 프리셋을 고르거나
**Choose Other…**로 설치된 어떤 `.app`이든 선택할 수 있다. 목적지를 지정하면
**어떤 앱이 최전면이었는지와 무관하게 모든 캡처가 그곳으로 간다**.

### 터미널 안의 CLI 에이전트

목적지 목록에는 터미널 구역이 따로 있다 — Ghostty, iTerm2, Terminal, WezTerm,
kitty, Warp. 여기서 실제로 겨냥하는 것은 그 안에서 돌고 있는 에이전트다.
**Claude Code, Codex CLI, Gemini CLI는 모두 프롬프트에 적힌 파일 경로로 이미지를
읽는데**, 경로 모드가 붙여넣는 것이 정확히 그것이다. Ghostty를 목적지로 지정해
두면 브라우저든 Figma든 어디서 찍어도 Ghostty로 전환한 뒤 에이전트의 프롬프트
줄에 경로가 떨어진다.

CLI 에이전트에는 자기 번들 ID가 없으므로 주소 역할은 터미널이 한다. AIShot은
창·탭·스플릿을 고르지 않는다 — 터미널을 활성화하면 마지막으로 작업하던 화면이
돌아오고 붙여넣기는 거기로 간다. 에이전트를 여러 개 띄워 뒀다면 원하는 쪽으로
먼저 전환하거나, 목적지를 **Automatic**으로 두고 그 터미널을 앞에 둔 채 찍으면
된다.

기본값은 경로만 넣고 커서를 그 뒤에 남기는 것이라, 질문을 이어 쓴 뒤 함께 보낼
수 있다. 바로 넘기고 싶으면 설정에서 **터미널에 경로를 붙여넣은 뒤 Enter로
바로 보내기**를 켠다. 경로 모드의 터미널에만 적용된다 — VS Code 같은 편집기에서
Enter는 그냥 파일 안의 줄바꿈이기 때문이다.

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
open -nb space.techjuicelab.aishot --args --settings

# 목적지 지정
defaults write space.techjuicelab.aishot targetApp claude

# auto | image | path
defaults write space.techjuicelab.aishot targetPasteMode image

# 선택: 꺼진 목적지를 실행하지 않기, 붙여넣은 뒤 원래 앱으로 돌아오기
defaults write space.techjuicelab.aishot autoLaunchTarget -bool false
defaults write space.techjuicelab.aishot returnFocus -bool true

# 선택: 터미널에 경로를 붙여넣은 뒤 Enter를 눌러 CLI 에이전트에 바로 넘기기
defaults write space.techjuicelab.aishot pasteSubmit -bool true

# 목적지를 Automatic으로 복원
defaults delete space.techjuicelab.aishot targetApp
```

목적지 별칭: `claude` · `codex` · `chatgpt` · `gemini` · `antigravity` ·
`antigravity-ide` · `cursor` · `vscode` · `safari` · `chrome` · `ghostty` ·
`iterm` · `terminal` · `wezterm` · `kitty` · `warp`. 그 외 앱은
선택창에서 고르거나 번들 ID로 지정한다
(`osascript -e 'id of app "SomeApp"'`).

포커스와 무관하게 이번 실행만 특정 앱으로 보내는 핫키도 만들 수 있다.
`--target`은 이번 실행에만 적용되고 저장된 목적지보다 우선한다:

```sh
open -gnb space.techjuicelab.aishot --args --target codex
```

현재 설정으로 어떻게 동작할지는 `--self-test`로 미리 확인할 수 있다.

## 설치

macOS 14 이상 (Apple Silicon / Intel).

**다운로드** — 툴체인도, 빌드도 필요 없다:

1. 최신 릴리스에서
   [**AIShot.dmg**](https://github.com/techjuicelab/aishot/releases/latest/download/AIShot.dmg)를
   받는다.
2. `AIShot.app`을 `/Applications`로 드래그한다.
3. 한 번 실행한다. AIShot이 스스로 메뉴 막대 LaunchAgent를 설치하고 그 사실을
   알린다. 아이콘이 메뉴 막대에 나타나고, 이후 로그인 때마다 다시 뜬다.

공증(notarize)되지 않은 앱이라 브라우저로 받은 파일에는 격리 플래그가 붙고 첫
실행이 거부된다. 시스템 설정 → 개인정보 보호 및 보안 → **그래도 열기**로
승인하거나(macOS 15부터는 우클릭 → 열기 우회가 더 이상 통하지 않는다), 실행 전에
플래그를 지운다:

```sh
xattr -dr com.apple.quarantine /Applications/AIShot.app
```

**소스에서 빌드** (Xcode Command Line Tools 필요):

```sh
git clone https://github.com/techjuicelab/aishot.git
cd aishot && ./build.sh   # 빌드·서명·설치 후 메뉴 막대 호스트 시작
```

두 경로의 결과는 같다. 같은 설치기를 쓰기 때문이다 — `build.sh`는 번들을
빌드·서명한 뒤 `AIShot --install`을 호출하고, 이는 DMG에서 드래그해 온 복사본이
첫 실행 때 스스로 실행하는 것과 같은 코드다. 이 설치기는 `/Applications`에
등록된 복사본을 하나만 남기고,
`~/Library/LaunchAgents/space.techjuicelab.aishot.menubar.plist`를 만든 뒤 메뉴
호스트를 즉시 시작한다. 실제 캡처는 계속 별도의 일회성 프로세스로 실행된다.
`/Applications`는 관리자 계정에 쓰기 권한이 있어 sudo가 필요 없다. 잠긴 관리형
Mac이면 `~/Applications`로 물러나며, 설치 위치는
`AISHOT_INSTALL_DIR=~/Applications`로 지정할 수도 있다. 어느 쪽이든 다른 위치에
남은 이전 설치본은 자동으로 제거된다 — 같은 번들 ID의 앱이 두 곳에 있으면
`open -a`, TCC 신원, 메뉴 막대 항목이 모두 모호해진다.

그 밖의 위치에서 실행된 복사본 — 마운트된 DMG 안, `~/Downloads` — 은 다른 일을
하기 전에 스스로 설치 위치로 옮겨 간다. LaunchAgent는 볼륨을 꺼낸 뒤에도 남아
있는 번들만 가리킬 수 있기 때문이다.

**기존 설치본에서 올라오는 경우**: 번들 ID가 `com.techjuicelab.aishot`에서
`space.techjuicelab.aishot`으로 바뀌었다. macOS가 옛 ID를 붙잡아 메뉴 막대
아이콘을 만들어놓고도 배치하지 않는 상태에 빠질 수 있고, 재부팅이나
LaunchServices 재등록으로 풀리지 않기 때문이다. 저장된 설정은 첫 실행 때
새 도메인으로 자동 이전되고 옛 LaunchAgent는 설치기가 정리한다. 다만
macOS에게는 새 앱이므로 **화면 기록·손쉬운 사용 권한은 한 번 다시 허용**해야
한다.

## 자동 업데이트

1.4부터 AIShot은 [Sparkle](https://sparkle-project.org)로 스스로 업데이트한다.
메뉴 막대 호스트가 하루에 한 번 새 버전을 확인하고, 있으면 알려준 뒤 설치한다.
직접 확인하려면 메뉴 막대 → **업데이트 확인…**.

내려받은 업데이트는 EdDSA 서명으로 검증한 뒤에만 설치된다. 서명이 맞지 않으면
설치되지 않으므로, 배포 경로가 오염되더라도 임의의 코드가 설치되지는 않는다.
검증에 쓰이는 공개키는 앱 번들에 들어 있다.

**소스에서 빌드해 쓰고 있었다면**, 첫 자동 업데이트에서 서명 신원이 로컬
ad-hoc에서 배포용 인증서로 바뀐다. macOS는 권한을 서명 신원에 묶어두므로
**화면 기록·손쉬운 사용 권한을 한 번 다시 허용**해야 한다. 그 다음부터는
인증서가 고정이라 업데이트해도 다시 묻지 않는다.

업데이트를 원하지 않으면 끌 수 있다:

```sh
defaults write space.techjuicelab.aishot SUEnableAutomaticChecks -bool false
```

## 단축키

쓰고 있는 런처 아무거나 아래 명령에 연결:

```sh
open -gnb space.techjuicelab.aishot --args --capture
```

인자 없이 실행해도 같은 일회성 캡처이므로 기존 런처와 Karabiner 룰은 그대로
동작한다.

- **Karabiner-Elements**:

  ```sh
  mkdir -p ~/.config/karabiner/assets/complex_modifications
  cp karabiner/aishot.json ~/.config/karabiner/assets/complex_modifications/
  ```

  그다음 Karabiner-Elements → Complex Modifications → Add predefined rule에서
  "AIShot" 활성화. 기본 키는 영역 캡처 <kbd>⌘⇧2</kbd>, 스크롤 캡처
  <kbd>⌘⇧6</kbd> — 시스템 ⌘⇧3/4/5 스크린샷 패밀리 옆자리. **양쪽
  <kbd>⇧</kbd> 동시 누르기** 룰(Codex 스타일)도 같이 들어 있으니 원하면 추가로
  활성화.

  <kbd>⌘⇧6</kbd>은 macOS가 Touch Bar 캡처용으로 예약해 둔 자리지만, Karabiner는
  시스템 단축키 계층보다 아래에서 이벤트를 가로채므로 충돌하지 않는다. 대신
  Raycast·Alfred·단축어 앱으로 옮길 때는 시스템 설정 → 키보드 → 키보드 단축키 →
  스크린샷에서 Touch Bar 항목을 꺼야 한다.
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
`tccutil reset All space.techjuicelab.aishot`을 실행한다. 이 경우 다음 캡처에서
권한을 깔끔하게 다시 요청한다.

## 플래그

```sh
open -gnb space.techjuicelab.aishot --args --mode image
```

| 플래그 | 설명 | 기본값 |
|---|---|---|
| `--capture` | 영역 캡처 한 번 실행 후 종료 (인자 없는 실행의 명시적 별칭) | 인자 없는 기본 동작 |
| `--scroll` | 창을 골라 스크롤 캡처 (전체 페이지를 한 장으로) | — |
| `--window ID` | 선택 UI 없이 지정한 창을 스크롤 캡처 (스크립트용) | — |
| `--list-windows` | `--window`에 넣을 창 ID 목록 출력 | — |
| `--scroll-debug DIR` | 원본 프레임을 전부 DIR에 저장하고 상세 로그 출력 | — |
| `--menubar` | **Quit AIShot** 전까지 단일 상주 메뉴 호스트 실행 | 설치된 LaunchAgent가 사용 |
| `--mode auto\|path\|image` | 자동 감지 대신 붙여넣기 형식 강제 | `auto` |
| `--target 별칭\|번들ID` | 이번 실행은 무조건 이 앱으로 (저장된 목적지보다 우선) | — |
| `--out DIR` | 저장 폴더 (이번 실행만) | 위 저장 폴더 순서 참고 |
| `--choose-dir` | 폴더 선택창을 열어 앱 기본 저장 폴더로 저장 | — |
| `--settings` | 목적지·붙여넣기 형식·자동 실행·포커스 설정창 열기 | — |
| `--no-paste` | 클립보드 복사까지만, 자동 ⌘V 안 함 | — |
| `--timeout SEC` | 선택 UI 대기 시간 | `300` |
| `--self-test` | 폴더·최전면 앱·권한 상태만 출력하고 종료 | — |
| `--install` | 이 복사본을 설치 위치로 배선 — 설치·LaunchAgent 등록·호스트 시작 후 종료 | `build.sh`와 설치 스크립트가 호출 |

## 커스터마이즈

**재빌드 없이** 앱 분류 추가 — AIShot은 실행 시 `defaults` 배열 세 개를 읽는다:

```sh
# 앱의 번들 ID 확인
osascript -e 'id of app "SomeTerm"'

defaults write space.techjuicelab.aishot extraPathApps  -array-add "com.example.someterm"
defaults write space.techjuicelab.aishot extraImageApps -array-add "com.example.chatapp"

# AIShot이 모르는 터미널 — pasteSubmit의 Enter가 여기에도 적용되게 한다
defaults write space.techjuicelab.aishot extraTerminalApps -array-add "com.example.someterm"
```

또는 [`main.swift`](main.swift) 상단의 `pathPasteIDs` / `imagePasteIDs`를
수정하고 `./build.sh` 재실행.

## 제거

```sh
launchctl bootout "gui/$UID/space.techjuicelab.aishot.menubar" 2>/dev/null || true
rm -f ~/Library/LaunchAgents/space.techjuicelab.aishot.menubar.plist
rm -rf /Applications/AIShot.app
tccutil reset All space.techjuicelab.aishot
defaults delete space.techjuicelab.aishot 2>/dev/null
# 런처/Karabiner에서 핫키 룰 제거
```

로그: `/tmp/aishot.log`

## 라이선스

[MIT](LICENSE) © TechJuiceLab
