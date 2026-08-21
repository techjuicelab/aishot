// AIShot — hotkey screenshot straight into the frontmost AI app.
//
// Flow: remember the frontmost app → interactive capture (screencapture -i;
// drag a region, Space for a window, Esc to cancel) → save the PNG into the
// user's screenshot folder (com.apple.screencapture location) → hand it to
// the configured destination (or, in Automatic mode, the app that was
// frontmost when the hotkey fired):
//   terminals / IDEs    → paste the escaped file path (like drag & drop);
//                         CLI agents (Claude Code, Codex) read images by path
//   AI apps / browsers  → paste the PNG itself (⌘V)
//   configured app      → launch/activate it and paste there every time
//   anything else       → clipboard only, no keystroke
// Capture workers exit immediately after each shot. A lightweight --menubar
// host provides quick destination switching and launches those workers.
// Log: /tmp/aishot.log

import AppKit
import ApplicationServices
import Darwin
import UniformTypeIdentifiers

// Sparkle is embedded by build.sh. Guarded so that a build without it — no
// network on a first build, or an explicitly stripped-down one — still
// compiles, just without update checking.
#if canImport(Sparkle)
import Sparkle
#endif

// MARK: - configuration

// Extra bundle IDs can be added per machine, without rebuilding:
//   defaults write space.techjuicelab.aishot extraPathApps  -array-add "com.example.terminal"
//   defaults write space.techjuicelab.aishot extraImageApps -array-add "com.example.chatapp"
func extraIDs(_ key: String) -> [String] {
    (CFPreferencesCopyAppValue(key as CFString, "space.techjuicelab.aishot" as CFString) as? [String]) ?? []
}

// AIShot moved off com.techjuicelab.aishot in 1.4. macOS can wedge a bundle ID
// so that its status item is created and reports isVisible, yet is never placed
// in the menu bar — a state that survives a reboot, LaunchServices
// re-registration and a ControlCenter restart. Carry the old settings over once
// so the rename is invisible to anyone upgrading.
func migrateLegacyPreferences() {
    let current = "space.techjuicelab.aishot" as CFString
    let legacy = "com.techjuicelab.aishot" as CFString
    var carried = false
    for key in ["saveDir", "targetApp", "targetPasteMode", "returnFocus",
                "autoLaunchTarget", "language", "extraPathApps", "extraImageApps"] {
        let name = key as CFString
        guard CFPreferencesCopyAppValue(name, current) == nil,
              let value = CFPreferencesCopyAppValue(name, legacy) else { continue }
        CFPreferencesSetAppValue(name, value, current)
        carried = true
    }
    if carried { CFPreferencesAppSynchronize(current) }
}
migrateLegacyPreferences()

// Frontmost apps that get the *file path* pasted as text.
let pathPasteIDs = Set([
    "com.mitchellh.ghostty",
    "com.apple.Terminal",
    "com.googlecode.iterm2",
    "net.kovidgoyal.kitty",
    "com.github.wez.wezterm",
    "dev.warp.Warp-Stable",
    "com.microsoft.VSCode",
    "com.google.antigravity",
    "com.google.antigravity-ide",
    "com.todesktop.230313mzl4w4u92", // Cursor
] + extraIDs("extraPathApps"))

// Frontmost apps that get the *image* pasted (⌘V with PNG on the clipboard).
let imagePasteIDs = Set([
    "com.anthropic.claudefordesktop", // Claude.app
    "com.openai.codex",               // Codex.app
    "com.openai.chat",                // ChatGPT.app
    "com.google.GeminiMacOS",         // Gemini.app
    "com.apple.Safari",
    "com.google.Chrome",
] + extraIDs("extraImageApps"))
// Designated target app — when set, every shot goes there regardless of which
// app was frontmost. Configure it in the settings panel or with a bundle ID:
//   defaults write space.techjuicelab.aishot targetApp claude
// Undo with:
//   defaults delete space.techjuicelab.aishot targetApp
// After pasting, focus stays in the target app; to hop back instead:
//   defaults write space.techjuicelab.aishot returnFocus -bool true
// Presets are grouped in the menu: the apps you paste *into* first, then the
// terminals, whose real destination is the CLI agent running inside them.
enum TargetKind {
    case app
    case terminal
}

struct TargetPreset {
    let alias: String
    let name: String
    let bundleID: String
    var kind: TargetKind = .app
}

let targetPresets = [
    TargetPreset(alias: "claude", name: "Claude", bundleID: "com.anthropic.claudefordesktop"),
    TargetPreset(alias: "antigravity", name: "Antigravity", bundleID: "com.google.antigravity"),
    TargetPreset(alias: "antigravity-ide", name: "Antigravity IDE", bundleID: "com.google.antigravity-ide"),
    TargetPreset(alias: "chatgpt", name: "ChatGPT", bundleID: "com.openai.chat"),
    TargetPreset(alias: "codex", name: "Codex", bundleID: "com.openai.codex"),
    TargetPreset(alias: "gemini", name: "Gemini", bundleID: "com.google.GeminiMacOS"),
    TargetPreset(alias: "cursor", name: "Cursor", bundleID: "com.todesktop.230313mzl4w4u92"),
    TargetPreset(alias: "vscode", name: "Visual Studio Code", bundleID: "com.microsoft.VSCode"),
    TargetPreset(alias: "safari", name: "Safari", bundleID: "com.apple.Safari"),
    TargetPreset(alias: "chrome", name: "Google Chrome", bundleID: "com.google.Chrome"),
    // Terminals. Pinning one routes every shot to the CLI agent you keep open
    // there — Claude Code, Codex CLI and Gemini CLI all take an image as a file
    // path in the prompt, which is exactly what path mode pastes. Which pane
    // receives it is the terminal's own business: activating the app restores
    // the window, tab and split you last worked in, and that is where ⌘V lands.
    TargetPreset(alias: "ghostty", name: "Ghostty", bundleID: "com.mitchellh.ghostty",
                 kind: .terminal),
    TargetPreset(alias: "iterm", name: "iTerm2", bundleID: "com.googlecode.iterm2",
                 kind: .terminal),
    TargetPreset(alias: "terminal", name: "Terminal", bundleID: "com.apple.Terminal",
                 kind: .terminal),
    TargetPreset(alias: "wezterm", name: "WezTerm", bundleID: "com.github.wez.wezterm",
                 kind: .terminal),
    TargetPreset(alias: "kitty", name: "kitty", bundleID: "net.kovidgoyal.kitty",
                 kind: .terminal),
    // Warp ships as dev.warp.Warp-Stable; the unsuffixed ID matches nothing, so
    // an entry using it is invisible in the menu and dead as a destination.
    TargetPreset(alias: "warp", name: "Warp", bundleID: "dev.warp.Warp-Stable",
                 kind: .terminal),
]
let targetAliases = Dictionary(uniqueKeysWithValues: targetPresets.map { ($0.alias, $0.bundleID) })

// Destinations where a pasted path is a shell/TUI prompt line, so pressing
// Return after it means "send this to the agent". Kept apart from pathPasteIDs,
// which also holds editors: a Return in VS Code is just a newline in a file.
// Add a terminal AIShot does not know with:
//   defaults write space.techjuicelab.aishot extraTerminalApps -array-add "com.example.term"
let terminalIDs = Set(targetPresets.filter { $0.kind == .terminal }.map(\.bundleID)
    + extraIDs("extraTerminalApps"))

// MARK: - interface language

// The menu bar and the settings panel follow the system language and can be
// pinned per machine:
//   defaults write space.techjuicelab.aishot language ko   # ko | en | auto
enum UILanguage: String {
    case korean = "ko"
    case english = "en"
}

func currentUILanguage() -> UILanguage {
    if let raw = CFPreferencesCopyAppValue("language" as CFString,
                                           "space.techjuicelab.aishot" as CFString) as? String,
       let pinned = UILanguage(rawValue: raw.lowercased()) {
        return pinned
    }
    return (Locale.preferredLanguages.first ?? "en").hasPrefix("ko") ? .korean : .english
}

// Mutable so the resident menu host can pick up a language change without a
// restart; capture workers read it once at launch.
var uiLanguage = currentUILanguage()

func t(_ korean: String, _ english: String) -> String {
    uiLanguage == .korean ? korean : english
}

let fm = FileManager.default
let logPath = "/tmp/aishot.log"

func log(_ msg: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(stamp)] \(msg)\n"
    if let h = FileHandle(forWritingAtPath: logPath) {
        h.seekToEndOfFile()
        h.write(line.data(using: .utf8)!)
        h.closeFile()
    } else {
        try? line.write(toFile: logPath, atomically: true, encoding: .utf8)
    }
    print(msg)
}

func fail(_ msg: String) -> Never {
    log("ERROR: \(msg)")
    exit(1)
}

// Keep the resident menu host singular and reject overlapping interactive
// captures. Advisory locks disappear automatically when their process exits;
// O_CLOEXEC prevents screencapture and destination apps from inheriting them.
func acquireProcessLock(_ name: String) -> Int32? {
    let path = NSTemporaryDirectory()
        + "space.techjuicelab.aishot.\(getuid()).\(name).lock"
    let fd = Darwin.open(path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
    guard fd >= 0 else {
        log("could not open \(name) lock: \(String(cString: strerror(errno)))")
        return nil
    }
    var lock = flock()
    lock.l_type = Int16(F_WRLCK)
    lock.l_whence = Int16(SEEK_SET)
    guard Darwin.fcntl(fd, F_SETLK, &lock) == 0 else {
        Darwin.close(fd)
        return nil
    }
    return fd
}

// MARK: - arguments

var outDir: String?
var mode = "auto" // auto | path | image
var paste = true
var timeout: Double = 300
var selfTest = false
var chooseDir = false
var showSettings = false
var showMenuBar = false
var scrollMode = false // --scroll: pick a window and capture it all the way down
var scrollWindowID: CGWindowID? // --window ID: skip the picker, scroll this window
var listWindows = false // --list-windows: print the IDs --window accepts
var scrollDebugDir: String? // --scroll-debug DIR: dump every raw frame and trace the run
var targetRaw: String? // --target alias|bundle-id: force the destination for this run
var assumeFrontRaw: String? // --assume-front bundle-id: the app the menu host saw
var installOnly = false // --install: wire this copy up and exit, installing nothing else
var announceInstall = false // --announce: confirm a GUI first run with an alert

var argIt = CommandLine.arguments.dropFirst().makeIterator()
while let arg = argIt.next() {
    switch arg {
    case "--out":
        guard let value = argIt.next() else { fail("--out requires a directory") }
        outDir = value
    case "--mode":
        guard let value = argIt.next() else { fail("--mode requires auto, path, or image") }
        mode = value
    case "--target":
        guard let value = argIt.next() else { fail("--target requires an alias or bundle ID") }
        targetRaw = value
    case "--assume-front":
        guard let value = argIt.next() else { fail("--assume-front requires a bundle ID") }
        assumeFrontRaw = value
    case "--no-paste":   paste = false
    case "--timeout":
        guard let value = argIt.next(), let seconds = Double(value), seconds > 0 else {
            fail("--timeout requires a positive number of seconds")
        }
        timeout = seconds
    case "--self-test":  selfTest = true
    case "--choose-dir": chooseDir = true
    case "--settings":   showSettings = true
    case "--menubar":    showMenuBar = true
    case "--scroll":     scrollMode = true
    case "--window":
        guard let value = argIt.next(), let id = UInt32(value) else {
            fail("--window requires a numeric window ID (see --list-windows)")
        }
        scrollWindowID = id
        scrollMode = true
    case "--list-windows": listWindows = true
    case "--scroll-debug":
        guard let value = argIt.next() else { fail("--scroll-debug requires a directory") }
        scrollDebugDir = value
        scrollMode = true
    case "--install":    installOnly = true
    case "--announce":   announceInstall = true
    case "--capture":    break // explicit alias for the default one-shot capture mode
    default:             fail("unknown flag: \(arg)")
    }
}
guard ["auto", "path", "image"].contains(mode) else { fail("--mode must be auto|path|image") }

// MARK: - updater relaunch

// Sparkle installs an update by replacing the bundle and then relaunching the
// app with no arguments at all. Nothing in that relaunch says "you were the menu
// bar host", so without a hint the new process takes the default path — a
// one-shot capture — and a finished update throws a capture crosshair over
// whatever the user was doing while the menu bar item stays gone until the next
// login (the LaunchAgent restarts the host only after an *unsuccessful* exit).
//
// The updater delegate therefore leaves a marker just before the relaunch. It
// goes in the preferences domain rather than anywhere inside the bundle,
// because the bundle is the thing about to be swapped out.
let relaunchMarkerDomain = "space.techjuicelab.aishot" as CFString
let relaunchMarkerKey = "menuBarRelaunchAt" as CFString
// One marker, one relaunch, and only for a couple of minutes. A marker that
// outlived its update would quietly turn every later hotkey capture into a
// second menu bar host — a worse failure than the one this fixes — so the
// timestamp, not just the presence of the key, is what makes it valid.
let relaunchMarkerWindow: TimeInterval = 180

func markMenuBarRelaunch() {
    CFPreferencesSetAppValue(relaunchMarkerKey,
                             NSNumber(value: Date().timeIntervalSince1970),
                             relaunchMarkerDomain)
    CFPreferencesAppSynchronize(relaunchMarkerDomain)
}

// Consumes the marker. It is removed whether or not it was still fresh, so a
// stale one cannot linger and be honoured by some later run.
func claimMenuBarRelaunchMarker() -> Bool {
    CFPreferencesAppSynchronize(relaunchMarkerDomain)
    guard let stamp = CFPreferencesCopyAppValue(relaunchMarkerKey,
                                                relaunchMarkerDomain) as? Double else {
        return false
    }
    CFPreferencesSetAppValue(relaunchMarkerKey, nil, relaunchMarkerDomain)
    CFPreferencesAppSynchronize(relaunchMarkerDomain)
    let age = Date().timeIntervalSince1970 - stamp
    guard age >= 0, age <= relaunchMarkerWindow else {
        log("discarded a stale menu bar relaunch marker (\(Int(age))s old)")
        return false
    }
    return true
}

// Only a run shaped exactly like Sparkle's relaunch — no arguments whatsoever —
// may claim the marker. Anything explicit (--capture, --settings, --choose-dir)
// stays what it was asked to be, and a hotkey capture with no marker present
// behaves exactly as it always has.
if !showMenuBar, CommandLine.arguments.count == 1, claimMenuBarRelaunchMarker() {
    showMenuBar = true
    log("relaunched by the updater — starting the menu bar host, not a capture")
}

// MARK: - installation

// Installing is the app's own job, so that a copy dragged out of a DMG, one
// unzipped by an install script and one built from source all end up wired the
// same way: a single registered bundle in /Applications and a LaunchAgent
// pointing at it. `--install` is the scripted entry point that build.sh and
// mac-setup use; a GUI first run does the same thing on its own and says so.
if installOnly {
    exit(Install.run(announce: announceInstall) ? 0 : 1)
}
// Diagnostic and utility runs are deliberately left out: --self-test or
// --list-windows against a build tree should report on that build tree, not
// quietly relocate the app to /Applications.
let mayAutoInstall = !showMenuBar && !selfTest && !listWindows && !chooseDir && !showSettings
if mayAutoInstall, Install.needsInstall() {
    if Install.needsRelocation() {
        // The copy that finishes the job is the one at the install location, and
        // it is the one that should be running afterwards — this process runs
        // out of a bundle that is about to be superseded, ejected or cleaned
        // away, so there is nothing sensible to continue with here.
        exit(Install.run(announce: true) ? 0 : 1)
    }
    // Already in the right place with only the LaunchAgent missing: wire it up
    // and carry on with whatever this run was asked to do.
    Install.run(announce: false)
}

// MARK: - environment

// Save-location priority: --out flag → app setting (saveDir, set with
// --choose-dir or `defaults write space.techjuicelab.aishot saveDir ...`) →
// the system screenshot folder (com.apple.screencapture) → ~/Desktop.
func screenshotFolder() -> String {
    if let d = outDir { return (d as NSString).expandingTildeInPath }
    if let d = CFPreferencesCopyAppValue("saveDir" as CFString,
                                         "space.techjuicelab.aishot" as CFString) as? String,
       !d.isEmpty {
        return (d as NSString).expandingTildeInPath
    }
    if let d = CFPreferencesCopyAppValue("location" as CFString,
                                         "com.apple.screencapture" as CFString) as? String,
       !d.isEmpty {
        return (d as NSString).expandingTildeInPath
    }
    return NSHomeDirectory() + "/Desktop"
}

// The explicitly pinned folder, if any. Nil means "follow the system location".
func storedSaveDir() -> String? {
    guard let d = CFPreferencesCopyAppValue("saveDir" as CFString,
                                            "space.techjuicelab.aishot" as CFString) as? String,
          !d.isEmpty else { return nil }
    return (d as NSString).expandingTildeInPath
}

// The system screenshot location, shown as the "follow the system" choice.
func systemScreenshotFolder() -> String {
    if let d = CFPreferencesCopyAppValue("location" as CFString,
                                         "com.apple.screencapture" as CFString) as? String,
       !d.isEmpty {
        return (d as NSString).expandingTildeInPath
    }
    return NSHomeDirectory() + "/Desktop"
}

// Snapshot the frontmost app first — this is the primary paste target. A
// capture started from the menu bar can observe AIShot itself in front, so the
// menu host forwards the app it saw before its menu opened; never route a
// capture (or a focus return) back into AIShot.
let front: NSRunningApplication? = {
    let observed = NSWorkspace.shared.frontmostApplication
    guard observed?.bundleIdentifier == "space.techjuicelab.aishot" else { return observed }
    guard let assumed = assumeFrontRaw, assumed != "space.techjuicelab.aishot" else { return nil }
    return NSRunningApplication.runningApplications(withBundleIdentifier: assumed)
        .first { !$0.isTerminated }
}()
let frontID = front?.bundleIdentifier ?? "?"
let frontName = front?.localizedName ?? "?"

// MARK: - target app

func resolveTarget(_ raw: String, source: String) -> String? {
    let key = raw.trimmingCharacters(in: .whitespaces)
    if let id = targetAliases[key.lowercased()] { return id }
    if key.contains(".") { return key } // taken as a literal bundle ID
    log("\(source) '\(raw)' is neither an alias (\(targetAliases.keys.sorted().joined(separator: ", "))) nor a bundle ID — ignored")
    return nil
}

// --target flag (this run only) beats the stored setting, mirroring --out/saveDir.
let flagTargetID: String? = {
    guard let raw = targetRaw else { return nil }
    guard let id = resolveTarget(raw, source: "--target") else { fail("bad --target value") }
    return id
}()
let storedTargetID: String? = {
    guard let raw = CFPreferencesCopyAppValue("targetApp" as CFString,
                                              "space.techjuicelab.aishot" as CFString) as? String,
          !raw.isEmpty else { return nil }
    return resolveTarget(raw, source: "targetApp setting")
}()
let storedTargetMode: String = {
    let value = (CFPreferencesCopyAppValue("targetPasteMode" as CFString,
                                          "space.techjuicelab.aishot" as CFString) as? String) ?? "auto"
    return ["auto", "path", "image"].contains(value) ? value : "auto"
}()
let returnFocus = (CFPreferencesCopyAppValue("returnFocus" as CFString,
                                             "space.techjuicelab.aishot" as CFString) as? Bool) ?? false
let autoLaunchTarget = (CFPreferencesCopyAppValue("autoLaunchTarget" as CFString,
                                                  "space.techjuicelab.aishot" as CFString) as? Bool) ?? true
// Press Return after pasting a path into a terminal, so the CLI agent receives
// the shot without a second keystroke. Off by default: the usual reason to send
// a screenshot to Claude Code is to ask something about it, and submitting a
// bare path costs a turn and the chance to type the question.
//   defaults write space.techjuicelab.aishot pasteSubmit -bool true
let pasteSubmit = (CFPreferencesCopyAppValue("pasteSubmit" as CFString,
                                             "space.techjuicelab.aishot" as CFString) as? Bool) ?? false

func runningApp(_ bundleID: String) -> NSRunningApplication? {
    NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        .first { !$0.isTerminated }
}

func pasteFormat(for bundleID: String) -> String {
    pathPasteIDs.contains(bundleID) ? "path" : "image"
}

func appDisplayName(bundleID: String) -> String {
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
       let bundle = Bundle(url: url) {
        return (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
    }
    if let preset = targetPresets.first(where: { $0.bundleID == bundleID }) {
        return preset.name
    }
    return bundleID
}

func destinationDisplayName(bundleID: String) -> String {
    let displayName = appDisplayName(bundleID: bundleID)
    guard let preset = targetPresets.first(where: { $0.bundleID == bundleID }),
          displayName.caseInsensitiveCompare(preset.name) != .orderedSame else {
        return displayName
    }
    return "\(preset.name) (\(displayName))"
}

func addTargetItem(to popup: NSPopUpButton, name: String, bundleID: String, select: Bool = false) {
    popup.addItem(withTitle: name)
    guard let item = popup.lastItem else { return }
    item.representedObject = bundleID
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 18, height: 18)
        item.image = icon
    }
    if select { popup.select(item) }
}

final class SettingsController: NSObject {
    let popup: NSPopUpButton
    let folderPopup: NSPopUpButton

    init(popup: NSPopUpButton, folderPopup: NSPopUpButton) {
        self.popup = popup
        self.folderPopup = folderPopup
    }

    @objc func chooseOtherApplication(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.title = t("목적지 앱 선택", "Choose a destination app")
        panel.prompt = t("선택", "Choose App")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier else { return }

        if let existing = popup.itemArray.first(where: { ($0.representedObject as? String) == bundleID }) {
            popup.select(existing)
            return
        }
        let name = (Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        addTargetItem(to: popup, name: name, bundleID: bundleID, select: true)
    }

    @objc func chooseSaveFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = t("이 폴더 사용", "Use This Folder")
        panel.message = t("AIShot: 스크린샷을 저장할 폴더를 고르세요",
                          "AIShot: choose where screenshots are saved")
        panel.directoryURL = URL(fileURLWithPath: screenshotFolder())
        guard panel.runModal() == .OK, let url = panel.url else { return }

        if let existing = folderPopup.itemArray.first(where: { ($0.representedObject as? String) == url.path }) {
            folderPopup.select(existing)
            return
        }
        folderPopup.addItem(withTitle: (url.path as NSString).abbreviatingWithTildeInPath)
        folderPopup.lastItem?.representedObject = url.path
        folderPopup.select(folderPopup.lastItem!)
    }
}

func presentSettings() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.activate()

    let destinationPopup = NSPopUpButton(frame: NSRect(x: 112, y: 284, width: 250, height: 26))
    destinationPopup.addItem(withTitle: t("자동 (최전면 앱)", "Automatic (frontmost app)"))
    destinationPopup.lastItem?.representedObject = ""
    for kind in [TargetKind.app, .terminal] {
        if kind == .terminal {
            destinationPopup.menu?.addItem(.separator())
            destinationPopup.menu?.addItem(.sectionHeader(title: t("터미널 — Claude Code · Codex CLI · Gemini CLI",
                                                                   "Terminal — Claude Code · Codex CLI · Gemini CLI")))
        }
        for preset in targetPresets where preset.kind == kind {
            let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: preset.bundleID) != nil
            let displayName = appDisplayName(bundleID: preset.bundleID)
            let name = !installed ? preset.name + t(" (미설치)", " (not installed)")
                : (displayName.caseInsensitiveCompare(preset.name) == .orderedSame
                    ? displayName : "\(preset.name) (\(displayName))")
            addTargetItem(to: destinationPopup, name: name,
                          bundleID: preset.bundleID, select: storedTargetID == preset.bundleID)
        }
    }
    if let current = storedTargetID,
       !destinationPopup.itemArray.contains(where: { ($0.representedObject as? String) == current }) {
        destinationPopup.menu?.addItem(.separator()) // out of the terminal section
        addTargetItem(to: destinationPopup, name: appDisplayName(bundleID: current),
                      bundleID: current, select: true)
    }
    if storedTargetID == nil { destinationPopup.selectItem(at: 0) }

    let formatPopup = NSPopUpButton(frame: NSRect(x: 112, y: 245, width: 250, height: 26))
    for (title, value) in [(t("자동", "Automatic"), "auto"),
                           (t("PNG 이미지", "PNG image"), "image"),
                           (t("파일 경로", "File path"), "path")] {
        formatPopup.addItem(withTitle: title)
        formatPopup.lastItem?.representedObject = value
        if value == storedTargetMode { formatPopup.select(formatPopup.lastItem!) }
    }

    // How a scrolling capture's recognized text is delivered. The image alone is
    // not enough there — see the scrollOcrMode notes at the capture site.
    let ocrPopup = NSPopUpButton(frame: NSRect(x: 112, y: 206, width: 250, height: 26))
    let currentOcrMode = storedScrollOcrMode()
    for (title, value) in [(t("안 함 — 이미지만 (빠름)", "Off — image only (fastest)"), "off"),
                           (t("텍스트 파일로 저장 (.txt)", "Save text file (.txt)"), "sidecar"),
                           (t("이미지+텍스트 둘 다 붙여넣기", "Paste image, then text"), "doublePaste"),
                           (t("텍스트만 붙여넣기", "Paste text only"), "textOnly"),
                           (t("자동 — 길면 텍스트", "Automatic — text when too tall"), "auto")] {
        ocrPopup.addItem(withTitle: title)
        ocrPopup.lastItem?.representedObject = value
        if value == currentOcrMode { ocrPopup.select(ocrPopup.lastItem!) }
    }

    let pinnedLanguage = (CFPreferencesCopyAppValue("language" as CFString,
                                                    "space.techjuicelab.aishot" as CFString) as? String)?
        .lowercased()
    let languagePopup = NSPopUpButton(frame: NSRect(x: 112, y: 167, width: 250, height: 26))
    for (title, value) in [(t("시스템 언어 따름", "Follow system language"), "auto"),
                           ("한국어", "ko"), ("English", "en")] {
        languagePopup.addItem(withTitle: title)
        languagePopup.lastItem?.representedObject = value
        if value == (pinnedLanguage == "ko" || pinnedLanguage == "en" ? pinnedLanguage : "auto") {
            languagePopup.select(languagePopup.lastItem!)
        }
    }

    let folderPopup = NSPopUpButton(frame: NSRect(x: 112, y: 128, width: 250, height: 26))
    let systemFolder = (systemScreenshotFolder() as NSString).abbreviatingWithTildeInPath
    folderPopup.addItem(withTitle: t("시스템 폴더 — \(systemFolder)", "System folder — \(systemFolder)"))
    folderPopup.lastItem?.representedObject = ""
    if let pinnedFolder = storedSaveDir() {
        folderPopup.addItem(withTitle: (pinnedFolder as NSString).abbreviatingWithTildeInPath)
        folderPopup.lastItem?.representedObject = pinnedFolder
        folderPopup.select(folderPopup.lastItem!)
    } else {
        folderPopup.selectItem(at: 0)
    }

    let controller = SettingsController(popup: destinationPopup, folderPopup: folderPopup)

    let chooseButton = NSButton(frame: NSRect(x: 372, y: 283, width: 148, height: 28))
    chooseButton.title = t("다른 앱 선택…", "Choose Other…")
    chooseButton.bezelStyle = .rounded
    chooseButton.target = controller
    chooseButton.action = #selector(SettingsController.chooseOtherApplication(_:))

    let folderButton = NSButton(frame: NSRect(x: 372, y: 127, width: 148, height: 28))
    folderButton.title = t("폴더 선택…", "Choose Folder…")
    folderButton.bezelStyle = .rounded
    folderButton.target = controller
    folderButton.action = #selector(SettingsController.chooseSaveFolder(_:))

    let launchCheckbox = NSButton(
        checkboxWithTitle: t("목적지 앱이 꺼져 있으면 실행하기",
                             "Open the destination app when it is not running"),
        target: nil, action: nil)
    launchCheckbox.frame = NSRect(x: 112, y: 96, width: 408, height: 24)
    launchCheckbox.state = autoLaunchTarget ? .on : .off

    let returnCheckbox = NSButton(
        checkboxWithTitle: t("붙여넣은 뒤 이전 앱으로 돌아가기",
                             "Return to the previous app after pasting"),
        target: nil, action: nil)
    returnCheckbox.frame = NSRect(x: 112, y: 68, width: 408, height: 24)
    returnCheckbox.state = returnFocus ? .on : .off

    let submitCheckbox = NSButton(
        checkboxWithTitle: t("터미널에 경로를 붙여넣은 뒤 Enter로 바로 보내기",
                             "Press Return after pasting a path into a terminal"),
        target: nil, action: nil)
    submitCheckbox.frame = NSRect(x: 112, y: 40, width: 408, height: 24)
    submitCheckbox.state = pasteSubmit ? .on : .off

    func label(_ text: String, y: CGFloat) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.frame = NSRect(x: 0, y: y, width: 102, height: 22)
        field.alignment = .right
        return field
    }
    let destinationLabel = label(t("목적지", "Destination"), y: 287)
    let formatLabel = label(t("붙여넣기 형식", "Paste as"), y: 248)
    let ocrLabel = label(t("스크롤 OCR", "Scroll OCR"), y: 209)
    let languageLabel = label(t("언어", "Language"), y: 170)
    let folderLabel = label(t("저장 폴더", "Save folder"), y: 131)

    let note = NSTextField(wrappingLabelWithString: t(
        "붙여넣은 뒤에도 이미지나 파일 경로는 클립보드에 그대로 남습니다. 언어를 바꾸면 메뉴 막대에는 바로, 이 창에는 다음에 열 때 반영됩니다.",
        "The copied image or file path remains on the clipboard after AIShot pastes it. A language change applies to the menu bar right away and to this panel the next time it opens."))
    note.frame = NSRect(x: 112, y: 0, width: 408, height: 34)
    note.textColor = .secondaryLabelColor
    note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

    let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 313))
    [destinationLabel, destinationPopup, chooseButton, formatLabel, formatPopup,
     ocrLabel, ocrPopup, languageLabel, languagePopup, folderLabel, folderPopup,
     folderButton, launchCheckbox, returnCheckbox, submitCheckbox,
     note].forEach(accessory.addSubview)

    let alert = NSAlert()
    alert.messageText = t("AIShot 설정", "AIShot Settings")
    alert.informativeText = t(
        "모든 캡처를 어디로 보낼지 고르세요. 자동은 기존처럼 최전면 앱을 따라갑니다.",
        "Choose where every capture should go. Automatic keeps the original frontmost-app behavior.")
    alert.accessoryView = accessory
    alert.addButton(withTitle: t("저장", "Save"))
    alert.addButton(withTitle: t("취소", "Cancel"))

    let response = withExtendedLifetime(controller) { alert.runModal() }
    guard response == .alertFirstButtonReturn else { return }
    let selectedID = (destinationPopup.selectedItem?.representedObject as? String) ?? ""
    let domain = "space.techjuicelab.aishot" as CFString
    if selectedID.isEmpty {
        CFPreferencesSetAppValue("targetApp" as CFString, nil, domain)
    } else {
        CFPreferencesSetAppValue("targetApp" as CFString, selectedID as CFString, domain)
    }
    let selectedMode = (formatPopup.selectedItem?.representedObject as? String) ?? "auto"
    CFPreferencesSetAppValue("targetPasteMode" as CFString, selectedMode as CFString, domain)
    let selectedOcrMode = (ocrPopup.selectedItem?.representedObject as? String) ?? "sidecar"
    CFPreferencesSetAppValue("scrollOcrMode" as CFString, selectedOcrMode as CFString, domain)
    let selectedLanguage = (languagePopup.selectedItem?.representedObject as? String) ?? "auto"
    CFPreferencesSetAppValue("language" as CFString,
                             selectedLanguage == "auto" ? nil : selectedLanguage as CFString, domain)
    let selectedFolder = (folderPopup.selectedItem?.representedObject as? String) ?? ""
    CFPreferencesSetAppValue("saveDir" as CFString,
                             selectedFolder.isEmpty ? nil : selectedFolder as CFString, domain)
    CFPreferencesSetAppValue("autoLaunchTarget" as CFString,
                             launchCheckbox.state == .on ? kCFBooleanTrue : kCFBooleanFalse, domain)
    CFPreferencesSetAppValue("returnFocus" as CFString,
                             returnCheckbox.state == .on ? kCFBooleanTrue : kCFBooleanFalse, domain)
    CFPreferencesSetAppValue("pasteSubmit" as CFString,
                             submitCheckbox.state == .on ? kCFBooleanTrue : kCFBooleanFalse, domain)
    CFPreferencesAppSynchronize(domain)
    log(selectedID.isEmpty
        ? "destination set to Automatic"
        : "destination set to \(destinationDisplayName(bundleID: selectedID)) (\(selectedID))")
    log("save folder: \(selectedFolder.isEmpty ? "system location" : selectedFolder)")
}

// MARK: - menu bar

#if canImport(Sparkle)
// Writes the marker the relaunched process looks for. This callback is the last
// moment at which the host still knows it is a host: it runs while the old
// process is alive and before the installer swaps the bundle, so anything
// recorded here survives into the new copy.
final class UpdaterRelaunchMarker: NSObject, SPUUpdaterDelegate {
    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        markMenuBarRelaunch()
        log("update installed — the relaunch will come back as the menu bar host")
    }
}
#endif

final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let destinationItem = NSMenuItem(title: "Destination", action: nil,
                                              keyEquivalent: "")
    private let hostLockFD: Int32
    private let preferencesDomain = "space.techjuicelab.aishot" as CFString

    #if canImport(Sparkle)
    // The menu bar host is the only long-lived AIShot process — capture workers
    // exit within seconds of doing their job — so it is the one that owns update
    // checking. Started in init rather than lazily: the scheduled background
    // check only runs while the updater is alive.
    private let updaterController: SPUStandardUpdaterController
    // SPUStandardUpdaterController references its updaterDelegate weakly (the
    // header says so outright), so the controller alone would let this go away
    // immediately and the relaunch would never be marked. Held strongly here for
    // the life of the host.
    private let updaterDelegate: UpdaterRelaunchMarker
    #endif

    // The app in front before the status menu opened. Clicking a status item
    // can make AIShot itself frontmost, which would strand an Automatic
    // capture, so track activations continuously rather than reading the
    // frontmost app at capture time.
    private var lastExternalFront: String?

    init(hostLockFD: Int32) {
        self.hostLockFD = hostLockFD
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        #if canImport(Sparkle)
        let relaunchMarker = UpdaterRelaunchMarker()
        self.updaterDelegate = relaunchMarker
        self.updaterController = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: relaunchMarker, userDriverDelegate: nil)
        #endif
        super.init()

        statusItem.autosaveName = "space.techjuicelab.aishot.status"
        statusItem.isVisible = true

        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "camera.viewfinder",
                                accessibilityDescription: "AIShot")
            image?.isTemplate = true
            button.image = image
            if image == nil { button.title = "AI" }
        }

        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if let front, front != "space.techjuicelab.aishot" { lastExternalFront = front }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(applicationActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)

        menu.autoenablesItems = false
        menu.delegate = self
        rebuildMenu()
        statusItem.menu = menu
        log("menu bar host started (status item visible: \(statusItem.isVisible))")
        // Asked for here rather than in a capture worker: authorization is
        // per-bundle, and only this long-lived process is registered as a
        // notification client. Once granted, the workers can post banners.
        requestNotificationAuthorization()
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        Darwin.close(hostLockFD)
    }

    // Menu titles are built for the current language; rebuilt when it changes.
    private func rebuildMenu() {
        menu.removeAllItems()

        let captureItem = NSMenuItem(title: t("스크린샷 찍기…", "Capture Screenshot…"),
                                     action: #selector(captureScreenshot(_:)), keyEquivalent: "")
        captureItem.target = self
        menu.addItem(captureItem)

        let scrollCaptureItem = NSMenuItem(
            title: t("스크롤 스크린샷 찍기…", "Capture Scrolling Screenshot…"),
            action: #selector(captureScrollingScreenshot(_:)), keyEquivalent: "")
        scrollCaptureItem.target = self
        menu.addItem(scrollCaptureItem)
        menu.addItem(.separator())

        if destinationItem.submenu == nil {
            destinationItem.submenu = NSMenu(title: "Destination")
        }
        menu.addItem(destinationItem)
        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: t("설정…", "Settings…"),
                                      action: #selector(openSettings(_:)), keyEquivalent: ",")
        settingsItem.keyEquivalentModifierMask = [.command]
        settingsItem.target = self
        menu.addItem(settingsItem)

        let folderItem = NSMenuItem(title: t("저장 폴더 열기", "Open Screenshot Folder"),
                                    action: #selector(openScreenshotFolder(_:)), keyEquivalent: "")
        folderItem.target = self
        menu.addItem(folderItem)

        let changeFolderItem = NSMenuItem(title: t("저장 폴더 변경…", "Change Screenshot Folder…"),
                                          action: #selector(changeScreenshotFolder(_:)),
                                          keyEquivalent: "")
        changeFolderItem.target = self
        menu.addItem(changeFolderItem)

        #if canImport(Sparkle)
        let updateItem = NSMenuItem(title: t("업데이트 확인…", "Check for Updates…"),
                                    action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)
        #endif

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: t("AIShot 종료", "Quit AIShot"),
                                  action: #selector(quit(_:)), keyEquivalent: "q")
        quitItem.keyEquivalentModifierMask = [.command]
        quitItem.target = self
        menu.addItem(quitItem)

        refreshDestinationMenu()
    }

    @objc private func applicationActivated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleID = app.bundleIdentifier,
              bundleID != "space.techjuicelab.aishot" else { return }
        lastExternalFront = bundleID
    }

    func menuWillOpen(_ menu: NSMenu) {
        CFPreferencesAppSynchronize(preferencesDomain)
        let latest = currentUILanguage()
        if latest != uiLanguage {
            uiLanguage = latest
            rebuildMenu()
            return
        }
        refreshDestinationMenu()
    }

    private func currentDestinationID() -> String? {
        CFPreferencesAppSynchronize(preferencesDomain)
        guard let raw = CFPreferencesCopyAppValue("targetApp" as CFString,
                                                  preferencesDomain) as? String,
              !raw.isEmpty else { return nil }
        return targetAliases[raw.lowercased()] ?? (raw.contains(".") ? raw : nil)
    }

    private func refreshDestinationMenu() {
        let currentID = currentDestinationID()
        let currentName = currentID.map { destinationDisplayName(bundleID: $0) }
            ?? t("자동", "Automatic")
        destinationItem.title = t("목적지: \(currentName)", "Destination: \(currentName)")
        statusItem.button?.toolTip = t("AIShot — 목적지: \(currentName)",
                                       "AIShot — Destination: \(currentName)")

        let submenu = destinationItem.submenu ?? NSMenu(title: "Destination")
        submenu.removeAllItems()

        addDestinationItem(title: t("자동 (최전면 앱)", "Automatic (Frontmost App)"), bundleID: nil,
                           selected: currentID == nil, to: submenu)
        submenu.addItem(.separator())

        // Apps first, then terminals under their own heading. A terminal is
        // listed as a destination in its own right because what the user is
        // aiming at is the CLI agent inside it, and that agent has no bundle ID
        // of its own to pick.
        for kind in [TargetKind.app, .terminal] {
            let visible = targetPresets.filter { preset in
                guard preset.kind == kind else { return false }
                let installed = NSWorkspace.shared.urlForApplication(
                    withBundleIdentifier: preset.bundleID) != nil
                return installed || currentID == preset.bundleID
            }
            guard !visible.isEmpty else { continue }
            if kind == .terminal {
                submenu.addItem(.separator())
                submenu.addItem(.sectionHeader(title: t("터미널 — Claude Code · Codex CLI · Gemini CLI",
                                                        "Terminal — Claude Code · Codex CLI · Gemini CLI")))
            }
            for preset in visible {
                addDestinationItem(title: destinationDisplayName(bundleID: preset.bundleID),
                                   bundleID: preset.bundleID,
                                   selected: currentID == preset.bundleID, to: submenu)
            }
        }

        // A section header groups everything after it until the next separator,
        // so an app picked with "Choose Other…" would otherwise be listed as a
        // terminal running a CLI agent. Close the group first.
        if let currentID,
           !targetPresets.contains(where: { $0.bundleID == currentID }) {
            submenu.addItem(.separator())
            addDestinationItem(title: appDisplayName(bundleID: currentID),
                               bundleID: currentID, selected: true, to: submenu)
        }

        submenu.addItem(.separator())
        let moreItem = NSMenuItem(title: t("설정에서 다른 앱 고르기…", "More Destinations in Settings…"),
                                  action: #selector(openSettings(_:)), keyEquivalent: "")
        moreItem.target = self
        submenu.addItem(moreItem)
        destinationItem.submenu = submenu
    }

    private func addDestinationItem(title: String, bundleID: String?, selected: Bool,
                                    to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: #selector(selectDestination(_:)),
                              keyEquivalent: "")
        item.target = self
        item.representedObject = bundleID ?? ""
        item.state = selected ? .on : .off
        menu.addItem(item)
    }

    private func launchSibling(arguments: [String], activates: Bool) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = arguments
        configuration.activates = activates
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL,
                                           configuration: configuration) { _, error in
            if let error { log("could not open AIShot \(arguments.joined(separator: " ")): \(error)") }
        }
    }

    @objc private func captureScreenshot(_ sender: Any?) {
        var arguments = ["--capture"]
        if let lastExternalFront { arguments += ["--assume-front", lastExternalFront] }
        launchSibling(arguments: arguments, activates: false)
    }

    @objc private func captureScrollingScreenshot(_ sender: Any?) {
        var arguments = ["--scroll"]
        if let lastExternalFront { arguments += ["--assume-front", lastExternalFront] }
        launchSibling(arguments: arguments, activates: false)
    }

    @objc private func selectDestination(_ sender: NSMenuItem) {
        let bundleID = (sender.representedObject as? String) ?? ""
        CFPreferencesSetAppValue("targetApp" as CFString,
                                 bundleID.isEmpty ? nil : bundleID as CFString,
                                 preferencesDomain)
        CFPreferencesAppSynchronize(preferencesDomain)
        log(bundleID.isEmpty
            ? "destination set to Automatic from menu bar"
            : "destination set to \(destinationDisplayName(bundleID: bundleID)) from menu bar")
        refreshDestinationMenu()
    }

    @objc private func openSettings(_ sender: Any?) {
        launchSibling(arguments: ["--settings"], activates: true)
    }

    @objc private func openScreenshotFolder(_ sender: Any?) {
        let folder = URL(fileURLWithPath: screenshotFolder(), isDirectory: true)
        NSWorkspace.shared.open(folder)
    }

    @objc private func changeScreenshotFolder(_ sender: Any?) {
        launchSibling(arguments: ["--choose-dir"], activates: true)
    }

    #if canImport(Sparkle)
    // AIShot is an accessory app, so Sparkle's progress and release-notes
    // windows would otherwise open behind whatever the user is working in.
    @objc private func checkForUpdates(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        updaterController.checkForUpdates(sender)
    }
    #endif


    // The LaunchAgent (KeepAlive SuccessfulExit=false) restarts the host after
    // a crash but not after a clean exit — restart-on-any-exit would race
    // launchd against Sparkle's installer over a bundle mid-replacement.
    // Terminating here is a clean exit, so launchd would already let it stick;
    // unload the agent as well so Quit means "gone for this session" no matter
    // how the exit is classified. The plist stays in place and the host
    // returns at the next login.
    @objc private func quit(_ sender: Any?) {
        let launchctl = Process()
        launchctl.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        launchctl.arguments = ["bootout", "gui/\(getuid())/space.techjuicelab.aishot.menubar"]
        do {
            try launchctl.run()
            launchctl.waitUntilExit()
        } catch {
            log("could not unload the menu bar agent: \(error)")
        }
        NSApp.terminate(nil)
    }
}

// A status item built before AppKit finishes launching the app never reaches
// the menu bar: the NSStatusItem exists and reports a size, but it is parked
// off-screen and stays invisible for the life of the process. Create it from
// applicationDidFinishLaunching instead.
final class MenuBarAppDelegate: NSObject, NSApplicationDelegate {
    private let hostLockFD: Int32
    private var controller: MenuBarController?

    init(hostLockFD: Int32) {
        self.hostLockFD = hostLockFD
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = MenuBarController(hostLockFD: hostLockFD)
    }
}

if showMenuBar {
    guard let hostLockFD = acquireProcessLock("menubar") else {
        log("menu bar is already running")
        exit(0)
    }
    // The host starts once per login and once per applied update, which makes it
    // the right place to notice that an update swapped a locally built, ad-hoc
    // signed copy for a release-signed one. Nothing else in the app would see
    // that transition, and macOS would go on showing permissions as granted
    // while silently refusing them.
    Install.reconcileSigningIdentity(verbose: false)
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = MenuBarAppDelegate(hostLockFD: hostLockFD) // NSApp.delegate is weak
    app.delegate = delegate
    app.run()
    withExtendedLifetime(delegate) {}
    exit(0)
}

// A second --settings run must not look like a dead click: hand focus to the
// instance that already owns the panel instead of exiting silently.
func activateExistingSettingsWindow() {
    let selfPID = ProcessInfo.processInfo.processIdentifier
    for peer in NSRunningApplication.runningApplications(
        withBundleIdentifier: "space.techjuicelab.aishot")
    where peer.processIdentifier != selfPID && !peer.isTerminated {
        peer.activate(options: [.activateAllWindows])
    }
}

if showSettings {
    guard acquireProcessLock("settings") != nil else {
        log("settings are already open — bringing the existing window forward")
        activateExistingSettingsWindow()
        exit(0)
    }
    presentSettings()
    exit(0)
}

struct RoutePlan {
    let bundleID: String?
    let app: NSRunningApplication?
    let launchURL: URL?
    let mode: String
    let autoPaste: Bool
}

// Routing: --target app for this run → stored destination app → frontmost
// supported app in Automatic mode → clipboard only. An explicit destination
// is unconditional and can be launched after the capture when needed.
func effectiveRoute() -> RoutePlan {
    if let id = flagTargetID ?? storedTargetID {
        let configuredMode = flagTargetID == nil ? storedTargetMode : "auto"
        let fmt = mode != "auto" ? mode
            : (configuredMode != "auto" ? configuredMode : pasteFormat(for: id))
        let app = runningApp(id)
        let launchURL = app == nil && autoLaunchTarget && paste
            ? NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) : nil
        return RoutePlan(bundleID: id, app: app, launchURL: launchURL,
                         mode: fmt, autoPaste: paste && (app != nil || launchURL != nil))
    }
    if mode != "auto" {
        return RoutePlan(bundleID: front?.bundleIdentifier, app: front, launchURL: nil,
                         mode: mode, autoPaste: paste && front != nil)
    }
    if pathPasteIDs.contains(frontID) {
        return RoutePlan(bundleID: frontID, app: front, launchURL: nil,
                         mode: storedTargetMode == "auto" ? "path" : storedTargetMode,
                         autoPaste: paste && front != nil)
    }
    if imagePasteIDs.contains(frontID) {
        return RoutePlan(bundleID: frontID, app: front, launchURL: nil,
                         mode: storedTargetMode == "auto" ? "image" : storedTargetMode,
                         autoPaste: paste && front != nil)
    }
    return RoutePlan(bundleID: nil, app: nil, launchURL: nil,
                     mode: storedTargetMode == "path" ? "path" : "image",
                     autoPaste: false)
}

func waitUntilFinishedLaunching(_ app: NSRunningApplication, attempts: Int = 100) -> Bool {
    for _ in 0..<attempts {
        if app.isTerminated { return false }
        if app.isFinishedLaunching { return true }
        usleep(100_000)
    }
    return false
}

func launchApplication(bundleID: String, at url: URL) -> NSRunningApplication? {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    configuration.addsToRecentItems = false
    NSWorkspace.shared.openApplication(at: url, configuration: configuration, completionHandler: nil)
    for _ in 0..<100 { // allow up to 10 seconds for a cold launch
        if let app = runningApp(bundleID) {
            if waitUntilFinishedLaunching(app) { return app }
            log("destination \(bundleID) did not finish launching — clipboard only")
            return nil
        }
        usleep(100_000)
    }
    log("could not launch destination \(bundleID) — clipboard only")
    return nil
}

struct AXActivationAttempt {
    let frontmost: AXError
    let raisedWindow: AXError?
}

// NSRunningApplication activation is only a request, and macOS can reject it
// when this background-only helper did not initiate the current interaction.
// Accessibility is already required for auto-paste, so use it to mark the
// destination frontmost and raise its last focused/main window as well.
func requestAccessibilityActivation(_ app: NSRunningApplication) -> AXActivationAttempt {
    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(axApp, 0.35)
    let frontmost = AXUIElementSetAttributeValue(
        axApp, kAXFrontmostAttribute as CFString, kCFBooleanTrue)

    var raisedWindow: AXError?
    for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
        var rawWindow: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            axApp, attribute as CFString, &rawWindow) == .success,
            let rawWindow,
            CFGetTypeID(rawWindow) == AXUIElementGetTypeID() else { continue }

        let window = unsafeBitCast(rawWindow, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(window, 0.35)
        var windowPID: pid_t = 0
        guard AXUIElementGetPid(window, &windowPID) == .success,
              windowPID == app.processIdentifier else { continue }
        raisedWindow = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        break
    }
    return AXActivationAttempt(frontmost: frontmost,
                               raisedWindow: raisedWindow)
}

// macOS restores focus to the source window asynchronously after the system
// screencapture UI closes. Electron apps can also ignore the first activation
// request during that hand-off. Retry through AppKit, Accessibility, and
// LaunchServices so the destination is visible before the paste whenever the
// system permits it.
func activateDestination(_ app: NSRunningApplication) -> Bool {
    let workspace = NSWorkspace.shared
    let destinationPID = app.processIdentifier
    let destinationBundleID = app.bundleIdentifier
    var lastAXAttempt: AXActivationAttempt?

    func isDestinationFrontmost() -> Bool {
        guard let actual = workspace.frontmostApplication else { return false }
        return actual.processIdentifier == destinationPID
            && actual.bundleIdentifier == destinationBundleID
    }

    // NSWorkspace updates frontmostApplication through its run loop. Sleeping
    // the worker thread leaves that value stale even after activation succeeds,
    // which used to make AIShot abort a valid paste.
    func waitForDestinationFrontmost(seconds: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: seconds)
        repeat {
            if isDestinationFrontmost() { return true }
            let sliceEnd = min(deadline, Date(timeIntervalSinceNow: 0.1))
            _ = RunLoop.current.run(mode: .default, before: sliceEnd)
        } while Date() < deadline
        return isDestinationFrontmost()
    }

    for attempt in 0..<8 { // up to about three seconds total
        if app.isTerminated { return false }
        if isDestinationFrontmost() { return true }

        if app.isHidden { _ = app.unhide() }
        _ = app.activate(options: [.activateAllWindows])
        // Keep AX IPC bounded and use it only as a fallback; an unresponsive
        // Electron app must not hold the capture worker indefinitely.
        if attempt == 2 || attempt == 5 {
            lastAXAttempt = requestAccessibilityActivation(app)
        }

        if attempt == 2 || attempt == 5, let url = app.bundleURL {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.addsToRecentItems = false
            workspace.openApplication(at: url, configuration: configuration,
                                      completionHandler: nil)
        }

        if waitForDestinationFrontmost(seconds: 0.4) { return true }
    }

    let actual = workspace.frontmostApplication
    log("could not activate \(app.localizedName ?? app.bundleIdentifier ?? "destination"); "
        + "frontmost stayed \(actual?.localizedName ?? "unknown") "
        + "(\(actual?.bundleIdentifier ?? "?")); "
        + "AX frontmost=\(lastAXAttempt?.frontmost.rawValue ?? 0), "
        + "raise=\(lastAXAttempt?.raisedWindow?.rawValue ?? 0)")
    return false
}

func axString(_ element: AXUIElement, attribute: CFString) -> String? {
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &raw) == .success else {
        return nil
    }
    return raw as? String
}

func isClaudePrompt(_ element: AXUIElement) -> Bool {
    guard let role = axString(element, attribute: kAXRoleAttribute as CFString),
          role == (kAXTextAreaRole as String) || role == (kAXTextFieldRole as String) else {
        return false
    }
    let description = axString(element, attribute: kAXDescriptionAttribute as CFString)
    let placeholder = axString(element, attribute: kAXPlaceholderValueAttribute as CFString)
    return description?.caseInsensitiveCompare("Prompt") == .orderedSame
        || placeholder?.caseInsensitiveCompare("Prompt") == .orderedSame
}

// Claude's Electron window frequently activates with its web content focused
// instead of the composer. In that state ⌘V is accepted by the process but
// discarded. Locate only Claude's explicitly-labelled Prompt field, focus it,
// and leave every other app's existing focus untouched.
func focusDestinationComposer(_ app: NSRunningApplication) -> Bool {
    guard app.bundleIdentifier == "com.anthropic.claudefordesktop" else { return true }

    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(axApp, 0.2)
    var rawFocused: CFTypeRef?
    if AXUIElementCopyAttributeValue(
        axApp, kAXFocusedUIElementAttribute as CFString, &rawFocused) == .success,
       let rawFocused,
       CFGetTypeID(rawFocused) == AXUIElementGetTypeID(),
       isClaudePrompt(unsafeBitCast(rawFocused, to: AXUIElement.self)) {
        return true
    }

    var roots: [AXUIElement] = []
    for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
        var rawWindow: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            axApp, attribute as CFString, &rawWindow) == .success,
           let rawWindow,
           CFGetTypeID(rawWindow) == AXUIElementGetTypeID() {
            roots.append(unsafeBitCast(rawWindow, to: AXUIElement.self))
        }
    }
    if roots.isEmpty { roots.append(axApp) }

    var stack = roots
    var visited = Set<CFHashCode>()
    var inspected = 0
    let searchDeadline = Date(timeIntervalSinceNow: 1.5)
    while let element = stack.popLast(), inspected < 500, Date() < searchDeadline {
        let identity = CFHash(element)
        guard visited.insert(identity).inserted else { continue }
        inspected += 1
        AXUIElementSetMessagingTimeout(element, 0.2)

        if isClaudePrompt(element) {
            var elementPID: pid_t = 0
            guard AXUIElementGetPid(element, &elementPID) == .success,
                  elementPID == app.processIdentifier else { return false }
            let focusError = AXUIElementSetAttributeValue(
                element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            if focusError == .success { return true }
            log("could not focus Claude prompt (AX \(focusError.rawValue))")
            return false
        }

        var rawChildren: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            element, kAXChildrenAttribute as CFString, &rawChildren) == .success,
           let children = rawChildren as? [AXUIElement] {
            // Stack order intentionally visits the visually/later composer
            // branch before the long chat history in Electron's AX tree.
            stack.append(contentsOf: children)
        }
    }
    log("could not find Claude prompt in accessibility tree")
    return false
}

@discardableResult
func postPasteShortcut(to app: NSRunningApplication) -> Bool {
    guard !app.isTerminated,
          let source = CGEventSource(stateID: .combinedSessionState),
          let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
          let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
        return false
    }
    keyDown.flags = .maskCommand
    keyUp.flags = .maskCommand
    keyDown.postToPid(app.processIdentifier)
    keyUp.postToPid(app.processIdentifier)
    usleep(150_000)
    return true
}

/// Return, for a terminal destination with pasteSubmit on: the path is sitting
/// on the prompt line and this is what hands it to the CLI agent.
@discardableResult
func postReturnKey(to app: NSRunningApplication) -> Bool {
    guard !app.isTerminated,
          let source = CGEventSource(stateID: .combinedSessionState),
          let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true),
          let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false) else {
        return false
    }
    // .combinedSessionState seeds a new event with the modifiers the user is
    // physically holding, and this fires about a second after the capture
    // gesture — long enough that a Shift-constrained drag or an Option-click on
    // a window is often still down. postPasteShortcut is immune only because it
    // overwrites flags with ⌘; here an inherited ⇧ or ⌥ would turn Return into
    // "newline, do not send" in exactly the CLI agents this is meant to reach.
    keyDown.flags = []
    keyUp.flags = []
    keyDown.postToPid(app.processIdentifier)
    keyUp.postToPid(app.processIdentifier)
    usleep(80_000)
    return true
}

if selfTest {
    let r = effectiveRoute()
    log("dir:            \(screenshotFolder())")
    log("frontmost:      \(frontName) (\(frontID))")
    if let id = r.bundleID, flagTargetID != nil || storedTargetID != nil {
        let state = r.app != nil ? "running"
            : (r.launchURL != nil ? "will open" : "not running / auto-open unavailable")
        log("target app:     \(destinationDisplayName(bundleID: id)) (\(id), \(state))")
    } else {
        log("target app:     Automatic")
    }
    log("language:       \(uiLanguage.rawValue)")
    log("screen-record:  \(CGPreflightScreenCaptureAccess() ? "granted" : "NOT granted")")
    log("accessibility:  \(AXIsProcessTrusted() ? "granted" : "NOT granted")")
    if r.autoPaste, let id = r.bundleID {
        let submits = pasteSubmit && r.mode == "path" && terminalIDs.contains(id)
        log("would paste as: \(r.mode) into \(destinationDisplayName(bundleID: id))"
            + (submits ? " and press Return" : ""))
    } else {
        log("would paste as: \(r.mode) (clipboard only)")
    }
    exit(0)
}

// The window IDs --window accepts, in the same front-to-back order the picker
// hit-tests. Titles are only populated once Screen Recording is granted.
if listWindows {
    for window in onScreenWindows(excluding: getpid()) {
        let b = window.displayBounds
        log(String(format: "%8u  %5.0fx%-5.0f at %5.0f,%-5.0f  %@",
                   window.id, b.width, b.height, b.origin.x, b.origin.y, window.label))
    }
    exit(0)
}

// Settings: a folder picker that stores the choice in the app's defaults.
// Run with:  open -na AIShot --args --choose-dir
if chooseDir {
    guard acquireProcessLock("settings") != nil else {
        log("settings are already open — bringing the existing window forward")
        activateExistingSettingsWindow()
        exit(0)
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.prompt = t("이 폴더 사용", "Use This Folder")
    panel.message = t("AIShot: 스크린샷을 저장할 폴더를 고르세요",
                      "AIShot: choose where screenshots are saved")
    panel.directoryURL = URL(fileURLWithPath: screenshotFolder())
    panel.level = .modalPanel
    app.activate()
    if panel.runModal() == .OK, let url = panel.url {
        CFPreferencesSetAppValue("saveDir" as CFString, url.path as CFString,
                                 "space.techjuicelab.aishot" as CFString)
        CFPreferencesAppSynchronize("space.techjuicelab.aishot" as CFString)
        log("save folder set: \(url.path)")
    } else {
        log("save folder unchanged: \(screenshotFolder())")
    }
    exit(0)
}

// MARK: - capture

guard acquireProcessLock("capture") != nil else {
    log("capture already in progress — ignored duplicate trigger")
    exit(0)
}

// Without Screen Recording the shot would silently miss window contents and
// the capture UI would race the permission dialog — prompt and bail instead;
// the next hotkey press runs a fresh process with the grant in effect.
if !CGPreflightScreenCaptureAccess() {
    log("screen-recording not granted — requesting; allow in System Settings, then press the hotkey again")
    _ = CGRequestScreenCaptureAccess()
    exit(0)
}

let dir = screenshotFolder()
try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)

// Probe writability up front: surfaces the Files & Folders (iCloud Drive /
// Desktop) prompt before the capture UI, and unmasks a denied grant that
// would otherwise look like an Esc-cancelled capture.
let probe = dir + "/.aishot-write-test"
if !fm.createFile(atPath: probe, contents: Data()) {
    fail("cannot write to \(dir) — allow AIShot under System Settings → Privacy & Security → Files and Folders")
}
try? fm.removeItem(atPath: probe)

let df = DateFormatter()
df.locale = Locale(identifier: "en_US_POSIX")
df.dateFormat = "yyyy-MM-dd 'at' h.mm.ss a"
let stamp = df.string(from: Date())
var savePath = "\(dir)/Screenshot \(stamp).png"
var serial = 2
while fm.fileExists(atPath: savePath) {
    savePath = "\(dir)/Screenshot \(stamp) (\(serial)).png"
    serial += 1
}

// What a scrolling capture puts on the clipboard, decided by the scrollOcrMode
// preference. A stitched page is routinely 30,000+ px tall, and Claude
// downscales image input to 2576 px on the long edge — the picture alone
// arrives unreadable, so the recognized text is the part that carries the
// content. Set inside the scroll block, consumed by the clipboard/paste
// pipeline at the bottom of the file; nil for ordinary region captures.
//
//   scrollClipboardText  — replaces the image on the clipboard (textOnly/auto)
//   scrollFollowUpText   — pasted as a second ⌘V after the image (doublePaste)
var scrollClipboardText: String?
var scrollFollowUpText: String?
/// A bounded copy of the capture for the clipboard, when the full-resolution one
/// is too large to hand another app. The saved PNG is always the full one.
var scrollClipboardImagePath: String?

// Whether a finished scrolling capture announces itself. On by default: the run
// takes tens of seconds with nothing on screen after the overlay closes, so
// silence is indistinguishable from a capture that died. Turn off with:
//   defaults write space.techjuicelab.aishot scrollNotify -bool false
func scrollNotifyEnabled() -> Bool {
    guard let value = CFPreferencesCopyAppValue("scrollNotify" as CFString,
                                                "space.techjuicelab.aishot" as CFString)
    else { return true }
    return (value as? Bool) ?? true
}

// off | sidecar | doublePaste | textOnly | auto — how a scrolling capture's
// OCR text is delivered. Change with:
//   defaults write space.techjuicelab.aishot scrollOcrMode doublePaste
func storedScrollOcrMode() -> String {
    let raw = CFPreferencesCopyAppValue("scrollOcrMode" as CFString,
                                        "space.techjuicelab.aishot" as CFString) as? String
    let known = ["off", "sidecar", "doublePaste", "textOnly", "auto"]
    // Off by default: a scrolling capture is first of all a screenshot, and
    // recognition is the slowest part of the run by a wide margin — on a
    // 16,000-px page it costs more time than the capture itself. The modes that
    // send text are there for the case that motivated them, which is handing a
    // long page to a model: Claude scales image input to 2576 px on the long
    // edge, so a tall capture's body text arrives illegible and only the
    // recognized text carries the content. Turn it on when that is the job.
    guard let raw, known.contains(raw) else { return "off" }
    return raw
}

// Two ways to produce the PNG at savePath: screencapture(1) for the interactive
// region shot, or the scrolling engine, which drives a window itself. From here
// on the two are indistinguishable — save, clipboard, routing and ⌘V are shared.
if scrollMode {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    let maxFrames: Int = {
        let raw = CFPreferencesCopyAppValue("scrollMaxFrames" as CFString,
                                            "space.techjuicelab.aishot" as CFString)
        // `defaults write … 8` stores a string while `defaults write … -int 8`
        // stores a number, and the two are indistinguishable to the user typing
        // the command. Reading only one of them fails silently back to the
        // default, which looks like the setting being ignored.
        let stored = (raw as? Int) ?? (raw as? String).flatMap(Int.init)
        guard let stored, stored >= 2 else { return ScrollTuning.defaultMaxFrames }
        return min(stored, 400)
    }()

    // A failed scrolling capture has to say so on screen. The region capture can
    // stay silent because Esc-to-cancel looks the same as a failure and the user
    // just pressed it; here the user picked a window and waited, so silence
    // reads as the app being broken.
    func reportFailure(_ message: String) -> Never {
        log("scrolling capture failed: \(message)")
        // --scroll-debug is a diagnostic run, usually scripted and often
        // repeated: the trace is the output, and a modal alert per attempt is
        // just something to dismiss.
        if scrollDebugDir != nil { exit(0) }
        // A distinct sound before the modal: the failure is often noticed by ear
        // first, since the user has looked away during a long capture.
        if scrollNotifyEnabled() { playSound(atPath: "/System/Library/Sounds/Basso.aiff") }
        let alert = NSAlert()
        alert.messageText = t("스크롤 캡처 실패", "Scrolling capture failed")
        alert.informativeText = message
        alert.alertStyle = .warning
        app.activate()
        alert.runModal()
        exit(0)
    }

    // Raising the target window and posting wheel events both go through
    // Accessibility, so without it the window never moves and the run ends with
    // "this window did not scroll" — a confident, wrong diagnosis of a
    // permission problem. Check before capturing and say what is actually wrong.
    //
    // The usual cause of a surprising denial is launching the executable
    // directly: TCC attributes the check to the responsible process, so
    // `AIShot.app/Contents/MacOS/AIShot` run from a terminal is judged as the
    // terminal, not as AIShot, and AIShot's own grant does not apply.
    guard AXIsProcessTrusted() else {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        reportFailure(t("""
            손쉬운 사용 권한이 없어 스크롤 캡처를 할 수 없습니다. 시스템 설정 → \
            개인정보 보호 및 보안 → 손쉬운 사용에서 AIShot을 허용하세요.

            터미널에서 실행 중이라면 앱으로 실행해야 AIShot의 권한이 적용됩니다:
            open -gnb space.techjuicelab.aishot --args --scroll
            """, """
            Scrolling capture needs Accessibility. Allow AIShot under System \
            Settings → Privacy & Security → Accessibility.

            If you launched the executable from a terminal, run it as an app \
            instead so AIShot's own grant applies:
            open -gnb space.techjuicelab.aishot --args --scroll
            """))
    }

    let onProgress: (Int) -> Void = { count in
        if count % 5 == 0 { log("scrolling capture: \(count) frames so far") }
    }

    // --window addresses a window directly, which is what makes this scriptable
    // and testable; without it the user points at one.
    if let debugDirectory = scrollDebugDir {
        try? fm.createDirectory(atPath: debugDirectory, withIntermediateDirectories: true)
    }

    let attempt: Result<ScrollCaptureOutcome, ScrollCaptureError>?
    if let requested = scrollWindowID {
        guard let target = onScreenWindows(excluding: getpid()).first(where: { $0.id == requested }) else {
            reportFailure(t("화면에 창 ID \(requested)가 없습니다. --list-windows로 확인하세요.",
                            "No on-screen window with ID \(requested) — check --list-windows."))
        }
        attempt = runScrollCapture(window: target, maxFrames: maxFrames,
                                   debugDirectory: scrollDebugDir, progress: onProgress)
    } else {
        attempt = pickAndScrollCapture(maxFrames: maxFrames,
                                       debugDirectory: scrollDebugDir, progress: onProgress)
    }

    guard let outcome = attempt else {
        log("scrolling capture cancelled")
        exit(0)
    }

    switch outcome {
    case .failure(.didNotScroll):
        reportFailure(t("이 창은 스크롤되지 않았습니다. 스크롤할 내용이 있는 창인지, 손쉬운 사용 권한이 허용돼 있는지 확인하세요.",
                        "That window did not scroll. Check that it has scrollable content and that Accessibility is granted."))
    case .failure(.windowUnavailable):
        reportFailure(t("창을 캡처할 수 없습니다. 창이 닫혔거나 화면에서 벗어났을 수 있습니다.",
                        "That window could not be captured — it may have closed or moved off screen."))
    case .failure(let error):
        reportFailure(t("캡처에 실패했습니다 (\(error)).", "Capture failed (\(error))."))
    case .success(let result):
        guard writePNG(result.image, to: savePath) else { fail("could not write \(savePath)") }
        log("scrolling capture: \(result.frameCount) frames → \(result.image.width)×\(result.image.height)")
        if let warning = result.warning { log("scrolling capture warning: \(warning)") }

        let ocrMode = storedScrollOcrMode()
        if ocrMode != "off" {
            let text = recognizeText(in: result.image) { done, total in
                if done % 4 == 0 || done == total { log("ocr: tile \(done)/\(total)") }
            }
            if text.isEmpty {
                log("ocr: no text recognized — delivering the image only")
            } else {
                // The text always lands next to the PNG, whatever the delivery
                // mode: the file is the durable copy, the clipboard is transient.
                let textPath = (savePath as NSString).deletingPathExtension + ".txt"
                try? text.write(toFile: textPath, atomically: true, encoding: .utf8)
                log("ocr: \(text.count) chars → \(textPath)")

                // Claude keeps image input under 2576 px on the long edge; past
                // roughly three times that, body text has shrunk below
                // legibility and the image is only good for layout.
                let unreadablyTall = result.image.height > 8000
                switch ocrMode {
                case "textOnly":
                    scrollClipboardText = text
                case "auto" where unreadablyTall:
                    log("ocr: \(result.image.height) px tall — sending text instead of the image")
                    scrollClipboardText = text
                case "auto", "doublePaste":
                    scrollFollowUpText = text
                default:
                    break // sidecar: the .txt beside the PNG is the delivery
                }
            }
        }

        // Bound what goes on the clipboard — but only when an image is going
        // there at all, since the text modes make the copy dead weight. A
        // full-page capture reaches hundreds of megapixels, and handing that to
        // another app is not merely wasteful: a 267-megapixel capture
        // terminated TextEdit on the paste. The file keeps every pixel.
        if scrollClipboardText == nil,
           let bounded = downscaled(result.image, maxPixels: 40_000_000) {
            // Kept out of the screenshot folder: this copy exists only to be
            // handed to another app, and leaving it beside the real capture
            // would put two files in the user's folder for every shot.
            let boundedPath = NSTemporaryDirectory()
                + "space.techjuicelab.aishot.clipboard.\(getpid()).png"
            if writePNG(bounded, to: boundedPath) {
                scrollClipboardImagePath = boundedPath
                log("clipboard copy scaled to \(bounded.width)×\(bounded.height) — full size kept on disk")
            }
        }

        // Announce the finish. The capture is done and saved at this point; the
        // clipboard and paste that follow are near-instant and log for
        // themselves, so this is the moment worth telling the user about.
        if scrollNotifyEnabled() {
            playCompletionChime()
            let size = "\(result.image.width)×\(result.image.height)"
            let file = (savePath as NSString).lastPathComponent
            postNotificationIfAllowed(
                title: t("스크롤 캡처 완료", "Scrolling capture complete"),
                body: t("\(result.frameCount)개 프레임 · \(size)\n\(file)",
                        "\(result.frameCount) frames · \(size)\n\(file)"))
            showHUD(t("✓  스크롤 캡처 완료 — \(result.frameCount)개 프레임 · \(size)",
                      "✓  Scrolling capture complete — \(result.frameCount) frames · \(size)"))
        }
    }
} else {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    proc.arguments = ["-i", savePath]
    do { try proc.run() } catch { fail("cannot run screencapture: \(error)") }

    let watchdog = DispatchWorkItem { proc.terminate() }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
    proc.waitUntilExit()
    watchdog.cancel()

    guard fm.fileExists(atPath: savePath) else {
        log("nothing captured (screencapture exit \(proc.terminationStatus)) — Esc pressed, or capture failed")
        exit(0)
    }
}

// screencapture can report completion just before WindowServer restores focus
// to the source app. Let that hand-off finish before routing to a destination.
usleep(300_000)

// MARK: - clipboard

// Backslash-escape shell specials, exactly like dragging a file into a terminal.
func shellEscape(_ path: String) -> String {
    let specials: Set<Character> = [
        " ", "(", ")", "[", "]", "{", "}", "<", ">",
        "'", "\"", "`", "\\", "$", "&", ";", "|", "*", "?", "!", "#", "=",
    ]
    var out = ""
    for ch in path {
        if specials.contains(ch) { out.append("\\") }
        out.append(ch)
    }
    return out
}

let route = effectiveRoute()
let pasteMode = route.mode
let pb = NSPasteboard.general

// What is actually being delivered, for the log. A scrolling capture in
// textOnly — or auto on a page too tall to stay legible — sends recognized text
// even though the route's paste mode still says "image".
let deliveredKind = scrollClipboardText != nil ? "ocr text" : pasteMode

@discardableResult
func copyCaptureToPasteboard() -> Int {
    pb.clearContents()
    if pasteMode == "path" {
        pb.setString(shellEscape(savePath) + " ", forType: .string)
    } else if let text = scrollClipboardText {
        // textOnly / auto-tall scrolling capture: the recognized text stands in
        // for an image the destination model could not have read anyway.
        pb.setString(text, forType: .string)
    } else {
        let item = NSPasteboardItem()
        // The image bytes may come from a bounded copy; the file URL always
        // points at the full-resolution capture, so anything resolving the
        // reference rather than the data still gets everything.
        if let png = fm.contents(atPath: scrollClipboardImagePath ?? savePath) {
            item.setData(png, forType: .png)
            // The TIFF flavor exists for picky receivers, but it is uncompressed
            // — a stitched full-page capture decodes to a gigabyte-class buffer
            // that the pasteboard server refuses, and the failed set aborts
            // nothing while wasting seconds. PNG + file URL cover every
            // destination we route to, so past a sane size TIFF is skipped.
            if png.count < 24_000_000, let tiff = NSImage(data: png)?.tiffRepresentation {
                item.setData(tiff, forType: .tiff)
            }
        }
        item.setString(URL(fileURLWithPath: savePath).absoluteString, forType: .fileURL)
        pb.writeObjects([item])
    }
    return pb.changeCount
}

/// Second ⌘V of a doublePaste scrolling capture: the image is already in the
/// destination's composer; swap the clipboard to the recognized text and paste
/// again so the content arrives readable next to the layout.
func pasteFollowUpText(_ text: String, into dest: NSRunningApplication) {
    // Let the destination finish ingesting the image paste before the clipboard
    // changes under it. Reading the pasteboard is asynchronous in Electron apps
    // like Claude, and swapping too early turns the *first* paste into text —
    // the user would get the OCR twice and no picture. Scale the wait with the
    // payload, because a stitched full-page capture is tens of megabytes and
    // takes proportionally longer to decode than an ordinary screenshot.
    let megabytes = Double((try? fm.attributesOfItem(atPath: savePath)[.size] as? Int)
        .flatMap { $0 } ?? 0) / 1_000_000
    let settle = min(3.0, 0.7 + megabytes * 0.04)
    log(String(format: "waiting %.1fs for the image paste to land before the text", settle))
    usleep(useconds_t(settle * 1_000_000))
    pb.clearContents()
    pb.setString(text, forType: .string)
    usleep(120_000)
    if postPasteShortcut(to: dest) {
        log("pasted ocr text after the image (doublePaste)")
    } else {
        log("could not deliver the ocr text paste — it stays on the clipboard")
    }
}

// MARK: - paste

guard route.autoPaste else {
    copyCaptureToPasteboard()
    log("copied \(deliveredKind) to clipboard — paste with ⌘V")
    log("saved \(savePath)")
    exit(0)
}

guard AXIsProcessTrusted() else {
    copyCaptureToPasteboard()
    // Trigger the one-time system prompt; this run stays clipboard-only.
    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(opts)
    log("accessibility not granted — copied to clipboard, paste with ⌘V (auto-paste once granted)")
    log("saved \(savePath)")
    exit(0)
}

var destination = route.app
if destination == nil, let bundleID = route.bundleID, let launchURL = route.launchURL {
    destination = launchApplication(bundleID: bundleID, at: launchURL)
}

guard let dest = destination else {
    copyCaptureToPasteboard()
    log("destination is unavailable — copied \(deliveredKind) to clipboard")
    log("saved \(savePath)")
    exit(0)
}

guard waitUntilFinishedLaunching(dest) else {
    copyCaptureToPasteboard()
    log("destination did not finish launching — skipped ⌘V; capture remains on clipboard")
    log("saved \(savePath)")
    exit(0)
}

// Bring the destination forward, then focus its composer when an app-specific
// target (currently Claude) needs help restoring the correct input field.
// Neither step is a precondition for the paste: ⌘V is delivered straight to the
// destination's process, so a refused activation or an accessibility tree that
// is too large to walk must not cost the user the paste — only the visual
// hand-off. Both used to abort the run, which is why long Claude conversations
// silently ended as clipboard-only.
if !activateDestination(dest) {
    log("destination did not become frontmost — sending ⌘V to it directly")
}
if !focusDestinationComposer(dest) {
    log("could not focus the destination composer — pasting into its current focus")
}

usleep(route.app == nil ? 500_000 : 120_000) // extra time after a cold launch
var captureChangeCount = copyCaptureToPasteboard()
usleep(80_000) // let the pasteboard settle

// A user copy or another AIShot invocation must never be mistaken for this
// capture. Clipboard managers, however, routinely touch the pasteboard right
// after a write, so rewrite once and only give up if it keeps changing.
if pb.changeCount != captureChangeCount {
    log("clipboard changed right after the copy — rewriting the capture")
    captureChangeCount = copyCaptureToPasteboard()
    usleep(120_000)
}
guard pb.changeCount == captureChangeCount else {
    log("clipboard kept changing — skipped ⌘V; the capture is saved and copied")
    log("saved \(savePath)")
    exit(0)
}

let expectedBundleID = route.bundleID ?? dest.bundleIdentifier
let destinationIdentityMatches = expectedBundleID.map { bundleID in
    dest.bundleIdentifier == bundleID
        && NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .contains { !$0.isTerminated && $0.processIdentifier == dest.processIdentifier }
} ?? false

guard !dest.isTerminated, destinationIdentityMatches else {
    log("destination or keyboard event source became unavailable — skipped ⌘V")
    log("saved \(savePath)")
    exit(0)
}
let destinationIsFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
    == dest.processIdentifier
guard postPasteShortcut(to: dest) else {
    log("destination or keyboard event source became unavailable — skipped ⌘V")
    log("saved \(savePath)")
    exit(0)
}
let targetName = dest.localizedName ?? dest.bundleIdentifier ?? "?"
if destinationIsFrontmost {
    log("pasted \(deliveredKind) into \(targetName)")
} else {
    log("sent \(deliveredKind) paste directly to \(targetName) after focus moved away")
}
// doublePaste only makes sense on top of an image paste — in path mode the
// destination is a terminal that got the file path, and the sidecar .txt sits
// next to the PNG for anything that wants the text.
if let followUp = scrollFollowUpText, pasteMode == "image" {
    pasteFollowUpText(followUp, into: dest)
}

// pasteSubmit: hand the path to the CLI agent on the prompt line. Gated on a
// terminal destination in path mode — a Return anywhere else is a newline in
// whatever the user was writing, and after an image paste it would submit an
// unfinished message. The wait covers the terminal's bracketed-paste round trip
// into the TUI; submitting before the path is on the line sends an empty turn.
if pasteSubmit, pasteMode == "path",
   let destinationID = dest.bundleIdentifier, terminalIDs.contains(destinationID) {
    usleep(250_000)
    if postReturnKey(to: dest) {
        log("pressed Return in \(targetName) (pasteSubmit)")
    } else {
        log("could not press Return in \(targetName) — the path is on the prompt line")
    }
}
if returnFocus, let front, front.processIdentifier != dest.processIdentifier {
    usleep(500_000) // let the app ingest the paste before it loses focus
    front.activate(options: [.activateAllWindows])
    usleep(150_000)
}
log("saved \(savePath)")
