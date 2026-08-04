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
//   defaults write com.techjuicelab.aishot targetApp claude
// Undo with:
//   defaults delete com.techjuicelab.aishot targetApp
// After pasting, focus stays in the target app; to hop back instead:
//   defaults write com.techjuicelab.aishot returnFocus -bool true
struct TargetPreset {
    let alias: String
    let name: String
    let bundleID: String
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
]
let targetAliases = Dictionary(uniqueKeysWithValues: targetPresets.map { ($0.alias, $0.bundleID) })

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
        + "com.techjuicelab.aishot.\(getuid()).\(name).lock"
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
var targetRaw: String? // --target alias|bundle-id: force the destination for this run

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
    case "--capture":    break // explicit alias for the default one-shot capture mode
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
let storedTargetMode: String = {
    let value = (CFPreferencesCopyAppValue("targetPasteMode" as CFString,
                                          "com.techjuicelab.aishot" as CFString) as? String) ?? "auto"
    return ["auto", "path", "image"].contains(value) ? value : "auto"
}()
let returnFocus = (CFPreferencesCopyAppValue("returnFocus" as CFString,
                                             "com.techjuicelab.aishot" as CFString) as? Bool) ?? false
let autoLaunchTarget = (CFPreferencesCopyAppValue("autoLaunchTarget" as CFString,
                                                  "com.techjuicelab.aishot" as CFString) as? Bool) ?? true

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

final class TargetPickerController: NSObject {
    let popup: NSPopUpButton

    init(popup: NSPopUpButton) {
        self.popup = popup
    }

    @objc func chooseOtherApplication(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.title = "Choose a destination app"
        panel.prompt = "Choose App"
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
}

func presentSettings() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.activate()

    let destinationPopup = NSPopUpButton(frame: NSRect(x: 112, y: 150, width: 250, height: 26))
    destinationPopup.addItem(withTitle: "Automatic (frontmost app)")
    destinationPopup.lastItem?.representedObject = ""
    for preset in targetPresets {
        let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: preset.bundleID) != nil
        let displayName = appDisplayName(bundleID: preset.bundleID)
        let name = !installed ? preset.name + " (not installed)"
            : (displayName.caseInsensitiveCompare(preset.name) == .orderedSame
                ? displayName : "\(preset.name) (\(displayName))")
        addTargetItem(to: destinationPopup, name: name,
                      bundleID: preset.bundleID, select: storedTargetID == preset.bundleID)
    }
    if let current = storedTargetID,
       !destinationPopup.itemArray.contains(where: { ($0.representedObject as? String) == current }) {
        addTargetItem(to: destinationPopup, name: appDisplayName(bundleID: current),
                      bundleID: current, select: true)
    }
    if storedTargetID == nil { destinationPopup.selectItem(at: 0) }

    let chooseButton = NSButton(frame: NSRect(x: 372, y: 149, width: 148, height: 28))
    chooseButton.title = "Choose Other…"
    chooseButton.bezelStyle = .rounded
    let picker = TargetPickerController(popup: destinationPopup)
    chooseButton.target = picker
    chooseButton.action = #selector(TargetPickerController.chooseOtherApplication(_:))

    let formatPopup = NSPopUpButton(frame: NSRect(x: 112, y: 111, width: 250, height: 26))
    for (title, value) in [("Automatic", "auto"), ("PNG image", "image"), ("File path", "path")] {
        formatPopup.addItem(withTitle: title)
        formatPopup.lastItem?.representedObject = value
        if value == storedTargetMode { formatPopup.select(formatPopup.lastItem!) }
    }

    let launchCheckbox = NSButton(checkboxWithTitle: "Open the destination app when it is not running",
                                  target: nil, action: nil)
    launchCheckbox.frame = NSRect(x: 112, y: 75, width: 408, height: 24)
    launchCheckbox.state = autoLaunchTarget ? .on : .off

    let returnCheckbox = NSButton(checkboxWithTitle: "Return to the previous app after pasting",
                                  target: nil, action: nil)
    returnCheckbox.frame = NSRect(x: 112, y: 43, width: 408, height: 24)
    returnCheckbox.state = returnFocus ? .on : .off

    let destinationLabel = NSTextField(labelWithString: "Destination")
    destinationLabel.frame = NSRect(x: 0, y: 153, width: 102, height: 22)
    destinationLabel.alignment = .right
    let formatLabel = NSTextField(labelWithString: "Paste as")
    formatLabel.frame = NSRect(x: 0, y: 114, width: 102, height: 22)
    formatLabel.alignment = .right
    let note = NSTextField(wrappingLabelWithString:
        "The copied image or file path remains on the clipboard after AIShot pastes it.")
    note.frame = NSRect(x: 112, y: 0, width: 408, height: 32)
    note.textColor = .secondaryLabelColor

    let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 184))
    [destinationLabel, destinationPopup, chooseButton, formatLabel, formatPopup,
     launchCheckbox, returnCheckbox, note].forEach(accessory.addSubview)

    let alert = NSAlert()
    alert.messageText = "AIShot Settings"
    alert.informativeText = "Choose where every capture should go. Automatic keeps the original frontmost-app behavior."
    alert.accessoryView = accessory
    alert.addButton(withTitle: "Save")
    alert.addButton(withTitle: "Cancel")

    let response = withExtendedLifetime(picker) { alert.runModal() }
    guard response == .alertFirstButtonReturn else { return }
    let selectedID = (destinationPopup.selectedItem?.representedObject as? String) ?? ""
    let domain = "com.techjuicelab.aishot" as CFString
    if selectedID.isEmpty {
        CFPreferencesSetAppValue("targetApp" as CFString, nil, domain)
    } else {
        CFPreferencesSetAppValue("targetApp" as CFString, selectedID as CFString, domain)
    }
    let selectedMode = (formatPopup.selectedItem?.representedObject as? String) ?? "auto"
    CFPreferencesSetAppValue("targetPasteMode" as CFString, selectedMode as CFString, domain)
    CFPreferencesSetAppValue("autoLaunchTarget" as CFString,
                             launchCheckbox.state == .on ? kCFBooleanTrue : kCFBooleanFalse, domain)
    CFPreferencesSetAppValue("returnFocus" as CFString,
                             returnCheckbox.state == .on ? kCFBooleanTrue : kCFBooleanFalse, domain)
    CFPreferencesAppSynchronize(domain)
    log(selectedID.isEmpty
        ? "destination set to Automatic"
        : "destination set to \(destinationDisplayName(bundleID: selectedID)) (\(selectedID))")
}

// MARK: - menu bar

final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let destinationItem = NSMenuItem(title: "Destination", action: nil,
                                              keyEquivalent: "")
    private let hostLockFD: Int32
    private let preferencesDomain = "com.techjuicelab.aishot" as CFString

    init(hostLockFD: Int32) {
        self.hostLockFD = hostLockFD
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "camera.viewfinder",
                                accessibilityDescription: "AIShot")
            image?.isTemplate = true
            button.image = image
            if image == nil { button.title = "AI" }
        }

        menu.autoenablesItems = false
        menu.delegate = self

        let captureItem = NSMenuItem(title: "Capture Screenshot…",
                                     action: #selector(captureScreenshot(_:)), keyEquivalent: "")
        captureItem.target = self
        menu.addItem(captureItem)
        menu.addItem(.separator())

        destinationItem.submenu = NSMenu(title: "Destination")
        menu.addItem(destinationItem)
        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…",
                                      action: #selector(openSettings(_:)), keyEquivalent: ",")
        settingsItem.keyEquivalentModifierMask = [.command]
        settingsItem.target = self
        menu.addItem(settingsItem)

        let folderItem = NSMenuItem(title: "Open Screenshot Folder",
                                    action: #selector(openScreenshotFolder(_:)), keyEquivalent: "")
        folderItem.target = self
        menu.addItem(folderItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit AIShot",
                                  action: #selector(quit(_:)), keyEquivalent: "q")
        quitItem.keyEquivalentModifierMask = [.command]
        quitItem.target = self
        menu.addItem(quitItem)

        refreshDestinationMenu()
        statusItem.menu = menu
    }

    deinit {
        Darwin.close(hostLockFD)
    }

    func menuWillOpen(_ menu: NSMenu) {
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
        let currentName = currentID.map { destinationDisplayName(bundleID: $0) } ?? "Automatic"
        destinationItem.title = "Destination: \(currentName)"
        statusItem.button?.toolTip = "AIShot — Destination: \(currentName)"

        let submenu = destinationItem.submenu ?? NSMenu(title: "Destination")
        submenu.removeAllItems()

        addDestinationItem(title: "Automatic (Frontmost App)", bundleID: nil,
                           selected: currentID == nil, to: submenu)
        submenu.addItem(.separator())

        for preset in targetPresets {
            let installed = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: preset.bundleID) != nil
            guard installed || currentID == preset.bundleID else { continue }
            addDestinationItem(title: destinationDisplayName(bundleID: preset.bundleID),
                               bundleID: preset.bundleID,
                               selected: currentID == preset.bundleID, to: submenu)
        }

        if let currentID,
           !targetPresets.contains(where: { $0.bundleID == currentID }) {
            addDestinationItem(title: appDisplayName(bundleID: currentID),
                               bundleID: currentID, selected: true, to: submenu)
        }

        submenu.addItem(.separator())
        let moreItem = NSMenuItem(title: "More Destinations in Settings…",
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
        launchSibling(arguments: ["--capture"], activates: false)
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

    @objc private func quit(_ sender: Any?) {
        NSApp.terminate(nil)
    }
}

if showMenuBar {
    guard let hostLockFD = acquireProcessLock("menubar") else {
        log("menu bar is already running")
        exit(0)
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let controller = MenuBarController(hostLockFD: hostLockFD)
    app.run()
    withExtendedLifetime(controller) {}
    exit(0)
}

if showSettings {
    guard acquireProcessLock("settings") != nil else {
        log("settings are already open")
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
    log("screen-record:  \(CGPreflightScreenCaptureAccess() ? "granted" : "NOT granted")")
    log("accessibility:  \(AXIsProcessTrusted() ? "granted" : "NOT granted")")
    if r.autoPaste, let id = r.bundleID {
        log("would paste as: \(r.mode) into \(destinationDisplayName(bundleID: id))")
    } else {
        log("would paste as: \(r.mode) (clipboard only)")
    }
    exit(0)
}

// Settings: a folder picker that stores the choice in the app's defaults.
// Run with:  open -na AIShot --args --choose-dir
if chooseDir {
    guard acquireProcessLock("settings") != nil else {
        log("settings are already open")
        exit(0)
    }
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

@discardableResult
func copyCaptureToPasteboard() -> Int {
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
    return pb.changeCount
}

// MARK: - paste

guard route.autoPaste else {
    copyCaptureToPasteboard()
    log("copied \(pasteMode) to clipboard — paste with ⌘V")
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
    log("destination is unavailable — copied \(pasteMode) to clipboard")
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
guard activateDestination(dest) else {
    copyCaptureToPasteboard()
    log("destination did not become frontmost — skipped ⌘V; capture remains on clipboard")
    log("saved \(savePath)")
    exit(0)
}

guard focusDestinationComposer(dest) else {
    copyCaptureToPasteboard()
    log("destination composer was unavailable — copied \(pasteMode) to clipboard")
    log("saved \(savePath)")
    exit(0)
}

usleep(route.app == nil ? 500_000 : 120_000) // extra time after a cold launch
let captureChangeCount = copyCaptureToPasteboard()
usleep(80_000) // let the pasteboard settle

// A user copy or another AIShot invocation must never be mistaken for this
// capture. A targeted event is used if focus did not move or drifted away.
guard pb.changeCount == captureChangeCount else {
    log("clipboard changed before paste — skipped ⌘V")
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
    log("pasted \(pasteMode) into \(targetName)")
} else {
    log("sent \(pasteMode) paste directly to \(targetName) after focus moved away")
}
if returnFocus, let front, front.processIdentifier != dest.processIdentifier {
    usleep(500_000) // let the app ingest the paste before it loses focus
    front.activate(options: [.activateAllWindows])
    usleep(150_000)
}
log("saved \(savePath)")
