// AIShot — hotkey screenshot straight into the frontmost AI app.
//
// Flow: remember the frontmost app → interactive capture (screencapture -i;
// drag a region, Space for a window, Esc to cancel) → save the PNG into the
// user's screenshot folder (com.apple.screencapture location) → hand it to
// the app that was frontmost when the hotkey fired:
//   terminals / IDEs    → paste the escaped file path (like drag & drop);
//                         CLI agents (Claude Code, Codex) read images by path
//   AI apps / browsers  → paste the PNG itself (⌘V)
//   anything else       → switch to the designated target app (defaults
//                         targetApp / --target) and paste there; with no
//                         target configured, clipboard only, no keystroke
// Runs only while invoked, exits immediately after. Log: /tmp/aishot.log

import AppKit
import ApplicationServices

// MARK: - configuration

// Extra bundle IDs can be added per machine, without rebuilding:
//   defaults write com.techjuicelab.aishot extraPathApps  -array-add "com.example.terminal"
//   defaults write com.techjuicelab.aishot extraImageApps -array-add "com.example.chatapp"
func extraIDs(_ key: String) -> [String] {
    (CFPreferencesCopyAppValue(key as CFString, "com.techjuicelab.aishot" as CFString) as? [String]) ?? []
}

// Frontmost apps that get the *file path* pasted as text.
let pathPasteIDs = Set([
    "com.mitchellh.ghostty",
    "com.apple.Terminal",
    "com.googlecode.iterm2",
    "net.kovidgoyal.kitty",
    "com.github.wez.wezterm",
    "dev.warp.Warp",
    "com.microsoft.VSCode",
    "com.google.antigravity",
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
// Any other frontmost app: the shot is routed to the designated target app
// below, if one is configured and running — otherwise clipboard only.

// Designated target app — where shots go when the frontmost app is not a
// known paste target. Set once with an alias or a bundle ID:
//   defaults write com.techjuicelab.aishot targetApp claude
// Undo with:
//   defaults delete com.techjuicelab.aishot targetApp
// After pasting, focus stays in the target app; to hop back instead:
//   defaults write com.techjuicelab.aishot returnFocus -bool true
let targetAliases: [String: String] = [
    "claude":      "com.anthropic.claudefordesktop",
    "codex":       "com.openai.codex",
    "chatgpt":     "com.openai.chat",
    "gemini":      "com.google.GeminiMacOS",
    "antigravity": "com.google.antigravity",
    "cursor":      "com.todesktop.230313mzl4w4u92",
    "vscode":      "com.microsoft.VSCode",
    "safari":      "com.apple.Safari",
    "chrome":      "com.google.Chrome",
]

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

// MARK: - arguments

var outDir: String?
var mode = "auto" // auto | path | image
var paste = true
var timeout: Double = 300
var selfTest = false
var chooseDir = false
var targetRaw: String? // --target alias|bundle-id: force the destination for this run

var argIt = CommandLine.arguments.dropFirst().makeIterator()
while let arg = argIt.next() {
    switch arg {
    case "--out":        outDir = argIt.next()
    case "--mode":       mode = argIt.next() ?? "auto"
    case "--target":     targetRaw = argIt.next()
    case "--no-paste":   paste = false
    case "--timeout":    timeout = Double(argIt.next() ?? "") ?? 300
    case "--self-test":  selfTest = true
    case "--choose-dir": chooseDir = true
    default:             fail("unknown flag: \(arg)")
    }
}
guard ["auto", "path", "image"].contains(mode) else { fail("--mode must be auto|path|image") }

// MARK: - environment

// Save-location priority: --out flag → app setting (saveDir, set with
// --choose-dir or `defaults write com.techjuicelab.aishot saveDir ...`) →
// the system screenshot folder (com.apple.screencapture) → ~/Desktop.
func screenshotFolder() -> String {
    if let d = outDir { return (d as NSString).expandingTildeInPath }
    if let d = CFPreferencesCopyAppValue("saveDir" as CFString,
                                         "com.techjuicelab.aishot" as CFString) as? String,
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

// Snapshot the frontmost app first — this is the primary paste target.
let front = NSWorkspace.shared.frontmostApplication
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
                                              "com.techjuicelab.aishot" as CFString) as? String,
          !raw.isEmpty else { return nil }
    return resolveTarget(raw, source: "targetApp setting")
}()
let returnFocus = (CFPreferencesCopyAppValue("returnFocus" as CFString,
                                             "com.techjuicelab.aishot" as CFString) as? Bool) ?? false

func runningApp(_ bundleID: String) -> NSRunningApplication? {
    NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        .first { !$0.isTerminated }
}

func pasteFormat(for bundleID: String) -> String {
    pathPasteIDs.contains(bundleID) ? "path" : "image"
}

// Routing: --target app for this run → frontmost app when it's a known paste
// target (a forced --mode keeps the old "paste into frontmost" behavior) →
// the stored target app → clipboard only. Target apps are never launched:
// when the target isn't running, the shot stays on the clipboard.
func effectiveRoute() -> (app: NSRunningApplication?, mode: String, autoPaste: Bool) {
    if let id = flagTargetID {
        let fmt = mode == "auto" ? pasteFormat(for: id) : mode
        if let app = runningApp(id) { return (app, fmt, paste) }
        log("target \(id) is not running — clipboard only, paste with ⌘V")
        return (nil, fmt, false)
    }
    if mode != "auto" { return (front, mode, paste) }
    if pathPasteIDs.contains(frontID) { return (front, "path", paste) }
    if imagePasteIDs.contains(frontID) { return (front, "image", paste) }
    if let id = storedTargetID {
        if let app = runningApp(id) { return (app, pasteFormat(for: id), paste) }
        log("target \(id) is not running — clipboard only, paste with ⌘V")
        return (nil, pasteFormat(for: id), false)
    }
    return (nil, "image", false) // unknown app, no target: copy only, never inject keys
}

if selfTest {
    let r = effectiveRoute()
    log("dir:            \(screenshotFolder())")
    log("frontmost:      \(frontName) (\(frontID))")
    if let id = flagTargetID ?? storedTargetID {
        log("target app:     \(id) (\(runningApp(id) != nil ? "running" : "NOT running"))")
    } else {
        log("target app:     none configured")
    }
    log("screen-record:  \(CGPreflightScreenCaptureAccess() ? "granted" : "NOT granted")")
    log("accessibility:  \(AXIsProcessTrusted() ? "granted" : "NOT granted")")
    if r.autoPaste, let dest = r.app {
        log("would paste as: \(r.mode) into \(dest.localizedName ?? dest.bundleIdentifier ?? "?")")
    } else {
        log("would paste as: \(r.mode) (clipboard only)")
    }
    exit(0)
}

// Settings: a folder picker that stores the choice in the app's defaults.
// Run with:  open -na AIShot --args --choose-dir
if chooseDir {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.prompt = "Use This Folder"
    panel.message = "AIShot: choose where screenshots are saved"
    panel.directoryURL = URL(fileURLWithPath: screenshotFolder())
    panel.level = .modalPanel
    app.activate()
    if panel.runModal() == .OK, let url = panel.url {
        CFPreferencesSetAppValue("saveDir" as CFString, url.path as CFString,
                                 "com.techjuicelab.aishot" as CFString)
        CFPreferencesAppSynchronize("com.techjuicelab.aishot" as CFString)
        log("save folder set: \(url.path)")
    } else {
        log("save folder unchanged: \(screenshotFolder())")
    }
    exit(0)
}

// MARK: - capture

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

let (routedApp, pasteMode, autoPaste) = effectiveRoute()
let pb = NSPasteboard.general
pb.clearContents()

if pasteMode == "path" {
    pb.setString(shellEscape(savePath) + " ", forType: .string)
} else {
    let item = NSPasteboardItem()
    if let png = fm.contents(atPath: savePath) {
        item.setData(png, forType: .png)
        if let tiff = NSImage(data: png)?.tiffRepresentation {
            item.setData(tiff, forType: .tiff)
        }
    }
    item.setString(URL(fileURLWithPath: savePath).absoluteString, forType: .fileURL)
    pb.writeObjects([item])
}

// MARK: - paste

if autoPaste, let dest = routedApp {
    if !AXIsProcessTrusted() {
        // Trigger the one-time system prompt; this run stays clipboard-only.
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        log("accessibility not granted — copied to clipboard, paste with ⌘V (auto-paste once granted)")
    } else {
        // ⌘V lands in the frontmost app, so the destination must come forward.
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != dest.processIdentifier {
            dest.activate(options: [])
            var waited = 0 // up to 2 s for the switch to take effect
            while NSWorkspace.shared.frontmostApplication?.processIdentifier != dest.processIdentifier,
                  waited < 20 {
                usleep(100_000)
                waited += 1
            }
        }
        usleep(120_000) // let the pasteboard settle
        let src = CGEventSource(stateID: .combinedSessionState)
        let vDown = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true) // kVK_ANSI_V
        vDown?.flags = .maskCommand
        let vUp = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
        vUp?.flags = .maskCommand
        vDown?.post(tap: .cghidEventTap)
        vUp?.post(tap: .cghidEventTap)
        usleep(150_000) // let the events flush before exiting
        log("pasted \(pasteMode) into \(dest.localizedName ?? dest.bundleIdentifier ?? "?")")
        if returnFocus, let front, front.processIdentifier != dest.processIdentifier {
            usleep(500_000) // let the app ingest the paste before it loses focus
            front.activate(options: [])
            usleep(150_000)
        }
    }
} else {
    log("copied \(pasteMode) to clipboard — paste with ⌘V")
}
log("saved \(savePath)")
