// AIShot — hotkey screenshot straight into the frontmost AI app.
//
// Flow: remember the frontmost app → interactive capture (screencapture -i;
// drag a region, Space for a window, Esc to cancel) → save the PNG into the
// user's screenshot folder (com.apple.screencapture location) → hand it to
// the app that was frontmost when the hotkey fired:
//   terminals / IDEs    → paste the escaped file path (like drag & drop);
//                         CLI agents (Claude Code, Codex) read images by path
//   AI apps / browsers  → paste the PNG itself (⌘V)
//   anything else       → clipboard only, no keystroke
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
// Any other frontmost app: clipboard only — paste manually with ⌘V.

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

var argIt = CommandLine.arguments.dropFirst().makeIterator()
while let arg = argIt.next() {
    switch arg {
    case "--out":        outDir = argIt.next()
    case "--mode":       mode = argIt.next() ?? "auto"
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

// Snapshot the frontmost app first — this is the paste target.
let front = NSWorkspace.shared.frontmostApplication
let frontID = front?.bundleIdentifier ?? "?"
let frontName = front?.localizedName ?? "?"

func effectiveMode() -> (mode: String, autoPaste: Bool) {
    switch mode {
    case "path", "image":
        return (mode, paste)
    default:
        if pathPasteIDs.contains(frontID) { return ("path", paste) }
        if imagePasteIDs.contains(frontID) { return ("image", paste) }
        return ("image", false) // unknown app: copy only, never inject keys
    }
}

if selfTest {
    let m = effectiveMode()
    log("dir:            \(screenshotFolder())")
    log("frontmost:      \(frontName) (\(frontID))")
    log("screen-record:  \(CGPreflightScreenCaptureAccess() ? "granted" : "NOT granted")")
    log("accessibility:  \(AXIsProcessTrusted() ? "granted" : "NOT granted")")
    log("would paste as: \(m.mode)\(m.autoPaste ? "" : " (clipboard only)")")
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
    NSRunningApplication.current.activate(options: .activateIgnoringOtherApps)
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

let (pasteMode, autoPaste) = effectiveMode()
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

if autoPaste {
    if !AXIsProcessTrusted() {
        // Trigger the one-time system prompt; this run stays clipboard-only.
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        log("accessibility not granted — copied to clipboard, paste with ⌘V (auto-paste once granted)")
    } else {
        if let front,
           NSWorkspace.shared.frontmostApplication?.processIdentifier != front.processIdentifier {
            front.activate(options: [])
            usleep(250_000)
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
        log("pasted \(pasteMode) into \(frontName)")
    }
} else {
    log("copied \(pasteMode) to clipboard — paste with ⌘V")
}
log("saved \(savePath)")
