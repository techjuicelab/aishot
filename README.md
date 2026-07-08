<p align="center">
  <img src="icon.png" width="180" alt="AIShot icon">
</p>

<h1 align="center">AIShot</h1>

<p align="center">
  One hotkey: screenshot → <b>straight into the AI app you're talking to</b>.<br>
  <i>No Finder digging · no drag &amp; drop · no resident process</i>
</p>

<p align="center"><a href="README.ko.md">한국어</a></p>

---

Press a hotkey → drag a region (or hit <kbd>Space</kbd> for a window, <kbd>Esc</kbd>
to cancel) → the PNG is saved into your usual screenshot folder **and** lands in
the app that was frontmost when you pressed the hotkey:

| Frontmost app | What gets pasted | Why |
|---|---|---|
| Terminals & IDEs — Ghostty, Terminal, iTerm2, kitty, WezTerm, Warp, VS Code, Antigravity, Cursor | escaped **file path** + auto ⌘V | CLI agents (Claude Code, Codex CLI) read images from a path — same format as drag & drop |
| AI apps & browsers — Claude, Codex, ChatGPT, Gemini, Safari, Chrome | the **PNG itself** + auto ⌘V | attaches as an image in the chat input |
| Anything else | clipboard only, no keystroke | never pastes into the wrong place — hit ⌘V yourself wherever you want |

Every capture is also **saved as a file** with the native macOS naming
(`Screenshot 2026-07-08 at 11.09.27 AM.png`), so pasting and archiving happen
in one motion.

**No setup needed**: AIShot saves to the same folder macOS uses for
⌘⇧3/4/5 screenshots. If you've moved that folder (System Settings /
`defaults write com.apple.screencapture location`), AIShot follows
automatically. You only ever configure something if you want AIShot captures
in a *different* folder than regular screenshots — run the built-in folder
chooser once:

```sh
open -na AIShot --args --choose-dir
```

Full resolution order: `--out DIR` flag → the app's own folder (set by
`--choose-dir`, or `defaults write com.techjuicelab.aishot saveDir ...`) →
the system screenshot folder → `~/Desktop` (the macOS stock default).

AIShot runs **only while invoked** — it captures, pastes, and exits.
No menu bar item, no daemon, zero idle footprint.

## Install

Requires macOS 14 or later (Apple Silicon or Intel).

**Build from source** (requires Xcode Command Line Tools) — recommended,
no Gatekeeper friction:

```sh
git clone https://github.com/techjuicelab/aishot.git
cd aishot && ./build.sh   # builds, signs (ad-hoc), installs to ~/Applications
```

**Or download** `AIShot.app.zip` from
[Releases](https://github.com/techjuicelab/aishot/releases) and unzip into
`~/Applications`. The app is not notarized, so macOS quarantines the
download — clear it with

```sh
xattr -dr com.apple.quarantine ~/Applications/AIShot.app
```

or launch it once and approve it under System Settings → Privacy & Security
→ "Open Anyway" (on macOS 15+ right-click → Open no longer bypasses this).

## Hotkey

Bind any launcher you already use to:

```sh
open -gn "$HOME/Applications/AIShot.app"
```

- **Karabiner-Elements**:

  ```sh
  mkdir -p ~/.config/karabiner/assets/complex_modifications
  cp karabiner/aishot.json ~/.config/karabiner/assets/complex_modifications/
  ```

  then enable the "AIShot" rule in Karabiner-Elements → Complex
  Modifications → Add predefined rule. Ships as <kbd>⌘⇧2</kbd> — right next
  to the system's ⌘⇧3/4/5 screenshot family.
- **Alfred / Raycast / Shortcuts.app**: point a hotkey at the same `open` command.

## First-run permissions (one-time)

1. First hotkey press → **Screen Recording** prompt appears and the app exits
   (System Settings → Privacy & Security → Screen & System Audio Recording → allow AIShot).
2. Press again → capture UI appears. On save, a **Files and Folders** prompt
   may appear for your screenshot folder (iCloud Drive / Desktop) — allow it,
   or nothing can be saved.
3. After the first completed capture → **Accessibility** prompt (for the
   synthesized ⌘V). Until granted, AIShot still copies to the clipboard;
   once granted, pasting is automatic from the next shot on.

**Rebuild caveat**: the app is ad-hoc signed, so rebuilding changes its code
hash and silently invalidates existing TCC grants — System Settings still
shows the toggles ON, but captures come back as wallpaper-only. `build.sh`
therefore runs `tccutil reset All com.techjuicelab.aishot` after installing,
so the next launch re-prompts cleanly. If you rebuild often, create a
self-signed code-signing certificate once (Keychain Access → Certificate
Assistant) and change the `codesign` line — grants then survive rebuilds.

## Flags

```sh
open -gn "$HOME/Applications/AIShot.app" --args --mode image
```

| Flag | Description | Default |
|---|---|---|
| `--mode auto\|path\|image` | force the paste format instead of auto-detecting | `auto` |
| `--out DIR` | destination folder (this run only) | see save-location order above |
| `--choose-dir` | open a folder picker and save the choice as the app's default | — |
| `--no-paste` | copy to clipboard only, never synthesize ⌘V | — |
| `--timeout SEC` | how long the selection UI may wait | `300` |
| `--self-test` | print folder / frontmost app / permission state and exit | — |

## Customize

Add apps to either category **without rebuilding** — AIShot reads two
`defaults` arrays at launch:

```sh
# find an app's bundle ID
osascript -e 'id of app "SomeTerm"'

defaults write com.techjuicelab.aishot extraPathApps  -array-add "com.example.someterm"
defaults write com.techjuicelab.aishot extraImageApps -array-add "com.example.chatapp"
```

Or edit `pathPasteIDs` / `imagePasteIDs` at the top of
[`main.swift`](main.swift) and re-run `./build.sh`.

## Uninstall

```sh
rm -rf ~/Applications/AIShot.app
tccutil reset All com.techjuicelab.aishot
defaults delete com.techjuicelab.aishot 2>/dev/null
# and remove the hotkey rule from your launcher / Karabiner
```

Log: `/tmp/aishot.log`

## License

[MIT](LICENSE) © TechJuiceLab
