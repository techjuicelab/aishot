// AIShot self-installation.
//
// Everything that used to live in the second half of build.sh — retiring the
// pre-1.4 LaunchAgent, stopping the previous menu bar host, keeping exactly one
// registered copy of the bundle, writing and bootstrapping the LaunchAgent, and
// noticing when the signing identity changed — is here instead, so that it runs
// no matter how the app arrived: built from source, unzipped by mac-setup, or
// dragged out of a DMG. `build.sh` and any download installer now do the same
// thing: put the bundle somewhere and run `AIShot --install`.
//
// A DMG or a ~/Downloads copy relocates itself to the install directory first,
// because a LaunchAgent may only ever point at a bundle that will still be
// there after the volume is ejected.

import AppKit
import Darwin

enum Install {
    static let bundleID = "space.techjuicelab.aishot"
    static let agentLabel = "space.techjuicelab.aishot.menubar"
    // Retired in 1.4. Its agent would keep restarting a host whose status item
    // macOS refuses to place in the menu bar, and both hosts would then fight
    // over the same lock.
    static let legacyAgentLabel = "com.techjuicelab.aishot.menubar"
    static let appName = "AIShot.app"

    static let lsregister = "/System/Library/Frameworks/CoreServices.framework"
        + "/Frameworks/LaunchServices.framework/Support/lsregister"

    private static let home = NSHomeDirectory()
    private static let requirementKey = "installedRequirement" as CFString
    private static let installDirKey = "installDir" as CFString
    private static let domain = bundleID as CFString

    static var agentPlistPath: String { "\(home)/Library/LaunchAgents/\(agentLabel).plist" }
    static var legacyAgentPlistPath: String { "\(home)/Library/LaunchAgents/\(legacyAgentLabel).plist" }

    // MARK: - locations

    /// The bundle this process is running out of, or nil for a bare binary —
    /// a case worth refusing rather than guessing about, since a LaunchAgent
    /// pointing into a build tree is exactly the breakage this file prevents.
    static var bundlePath: String? {
        let path = Bundle.main.bundleURL.standardizedFileURL.path
        return path.hasSuffix(".app") ? path : nil
    }

    /// The two places a Mac app is expected to live. `/Applications` is
    /// group-writable for admin users, so no sudo is needed on a normal Mac;
    /// `~/Applications` is the fallback on a locked-down managed machine.
    static var installLocations: [String] { ["/Applications", "\(home)/Applications"] }

    static var installDir: String {
        if let override = ProcessInfo.processInfo.environment["AISHOT_INSTALL_DIR"],
           !override.isEmpty {
            return (override as NSString).expandingTildeInPath
                .trimmingTrailingSlash()
        }
        // A copy that already sits in a recognised location stays there. Without
        // this, someone who deliberately installed into ~/Applications on a Mac
        // where /Applications happens to be writable would be relocated back on
        // every launch.
        if let bundle = bundlePath {
            let parent = (bundle as NSString).deletingLastPathComponent
            if installLocations.contains(parent) { return parent }
        }
        if let remembered = CFPreferencesCopyAppValue(installDirKey, domain) as? String,
           installLocations.contains(remembered) {
            return remembered
        }
        return fm.isWritableFile(atPath: "/Applications") ? "/Applications" : "\(home)/Applications"
    }

    static var installedPath: String { "\(installDir)/\(appName)" }
    static var installedBinary: String { "\(installedPath)/Contents/MacOS/AIShot" }

    // MARK: - state

    /// Cheap enough for the capture hot path: two small file reads, no
    /// subprocesses.
    static func needsInstall() -> Bool {
        guard let bundle = bundlePath else { return false }
        if bundle != installedPath { return true }
        return !agentPointsAt(installedBinary)
    }

    static func needsRelocation() -> Bool {
        guard let bundle = bundlePath else { return false }
        return bundle != installedPath
    }

    static func agentPointsAt(_ binary: String) -> Bool {
        guard let data = fm.contents(atPath: agentPlistPath),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil) as? [String: Any],
              let arguments = plist["ProgramArguments"] as? [String],
              let program = arguments.first else { return false }
        return program == binary
    }

    static func designatedRequirement(of path: String) -> String? {
        let result = tool("/usr/bin/codesign", ["-d", "-r-", path])
        for line in result.output.components(separatedBy: "\n") {
            if let range = line.range(of: "designated => ") {
                return String(line[range.upperBound...])
            }
        }
        return nil
    }

    // MARK: - the install itself

    /// Returns false having explained why, rather than throwing: every caller
    /// either exits with a status or carries on with the run that was asked for.
    @discardableResult
    static func run(announce: Bool) -> Bool {
        // build.sh and mac-setup read this over a pipe, where stdout would
        // otherwise be block-buffered and the caller's lines would arrive after
        // those of the copy that finished the job.
        setvbuf(stdout, nil, _IOLBF, 0)
        guard let bundle = bundlePath else {
            log("error:     not running from an app bundle — nothing to install")
            return false
        }
        if bundle != installedPath { return relocate(from: bundle, announce: announce) }

        retireLegacyAgent()
        guard stopRunningHosts() else { return false }
        removeCopiesElsewhere()
        guard writeAndStartAgent() else { return false }

        CFPreferencesSetAppValue(installDirKey, installDir as CFString, domain)
        CFPreferencesAppSynchronize(domain)

        log("installed: \(installedPath)")
        log("menu bar:  running now and automatically after login")
        if installDir != "/Applications" {
            log("note:      /Applications was not writable — installed to \(installDir) instead")
        }
        reconcileSigningIdentity()
        if announce { announceInstall() }
        return true
    }

    /// Copies the bundle to the install directory and hands the rest of the work
    /// to that copy. The work has to happen over there: a LaunchAgent pointing
    /// at a DMG mount point or a build tree is a host that disappears the moment
    /// the volume is ejected or the tree is cleaned.
    private static func relocate(from bundle: String, announce: Bool) -> Bool {
        guard fm.isWritableFile(atPath: installDir) || createInstallDir() else {
            log("error:     \(installDir) is not writable — set AISHOT_INSTALL_DIR to a writable folder")
            return false
        }
        // The copy being replaced may be the one currently serving the menu bar.
        guard stopRunningHosts() else { return false }
        if fm.fileExists(atPath: installedPath) {
            do { try fm.removeItem(atPath: installedPath) } catch {
                log("error:     could not replace \(installedPath): \(error.localizedDescription)")
                return false
            }
        }
        // ditto rather than FileManager.copyItem: it is what preserves the
        // signed bundle's metadata across a copy off a read-only DMG.
        let copied = tool("/usr/bin/ditto", [bundle, installedPath])
        guard copied.status == 0 else {
            log("error:     could not copy the app to \(installedPath): \(copied.output)")
            return false
        }
        tool(lsregister, ["-f", installedPath])
        log("copied:    \(bundle) → \(installedPath)")

        var arguments = ["--install"]
        if announce { arguments.append("--announce") }
        if announce {
            // A GUI first run — double-clicked out of a DMG or ~/Downloads. Start
            // the installed copy through LaunchServices so that its alert belongs
            // to an app macOS considers launched, then get out of the way.
            let opened = tool("/usr/bin/open", ["-na", installedPath, "--args"] + arguments)
            if opened.status != 0 {
                log("error:     could not start the installed copy: \(opened.output)")
                return false
            }
            return true
        }
        // A scripted install (build.sh, mac-setup). Run the installed copy as a
        // child so the caller gets its output and its exit status.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: installedBinary)
        proc.arguments = arguments
        do { try proc.run() } catch {
            log("error:     could not run the installed copy: \(error.localizedDescription)")
            return false
        }
        proc.waitUntilExit()
        return proc.terminationStatus == 0
    }

    private static func createInstallDir() -> Bool {
        (try? fm.createDirectory(atPath: installDir, withIntermediateDirectories: true)) != nil
    }

    private static func retireLegacyAgent() {
        let loaded = tool("/bin/launchctl", ["print", "gui/\(getuid())/\(legacyAgentLabel)"]).status == 0
        guard loaded || fm.fileExists(atPath: legacyAgentPlistPath) else { return }
        tool("/bin/launchctl", ["bootout", "gui/\(getuid())/\(legacyAgentLabel)"])
        try? fm.removeItem(atPath: legacyAgentPlistPath)
        log("cleanup:   retired the com.techjuicelab.aishot menu bar agent")
    }

    /// Stops the resident host — the LaunchAgent one and any copy started by
    /// hand — so the bundle underneath it can be replaced. Captures are separate
    /// short-lived processes and are left alone.
    private static func stopRunningHosts() -> Bool {
        tool("/bin/launchctl", ["bootout", "gui/\(getuid())/\(agentLabel)"])
        for _ in 0..<40 {
            if tool("/bin/launchctl", ["print", "gui/\(getuid())/\(agentLabel)"]).status != 0 { break }
            usleep(50_000)
        }
        if tool("/bin/launchctl", ["print", "gui/\(getuid())/\(agentLabel)"]).status == 0 {
            log("error:     previous menu bar LaunchAgent did not stop")
            return false
        }

        let mine = getpid()
        for line in tool("/bin/ps", ["ax", "-o", "pid=,command="]).output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(of: " "),
                  let pid = Int32(trimmed[trimmed.startIndex..<space]), pid != mine else { continue }
            let command = String(trimmed[trimmed.index(after: space)...])
            guard command.hasSuffix("/\(appName)/Contents/MacOS/AIShot --menubar") else { continue }
            kill(pid, SIGTERM)
            for _ in 0..<20 {
                if kill(pid, 0) != 0 { break }
                usleep(50_000)
            }
            if kill(pid, 0) == 0 {
                log("error:     previous manual menu bar host did not stop")
                return false
            }
        }
        return true
    }

    /// Keep exactly one registered copy: two bundles sharing a bundle ID make
    /// `open -a AIShot`, the TCC identity and the menu bar item all resolve
    /// ambiguously.
    private static func removeCopiesElsewhere() {
        for other in installLocations where other != installDir {
            let path = "\(other)/\(appName)"
            guard fm.fileExists(atPath: path) else { continue }
            tool(lsregister, ["-f", "-u", path])
            guard (try? fm.removeItem(atPath: path)) != nil else {
                log("warning:   could not remove the earlier install at \(path)")
                continue
            }
            log("cleanup:   removed the earlier install at \(path)")
        }
    }

    private static func writeAndStartAgent() -> Bool {
        // KeepAlive: restart the host after a crash, but not after it exits
        // cleanly. A host that dies unexpectedly must not leave the user without
        // a menu bar item; a deliberate exit must be allowed to stick. That
        // distinction matters for auto-updates too — Sparkle terminates the app
        // to swap the bundle and relaunches it itself, and a restart-on-any-exit
        // agent would race launchd against the installer over a bundle that is
        // mid-replacement.
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key><string>\(agentLabel)</string>
          <key>ProgramArguments</key>
          <array>
            <string>\(installedBinary)</string>
            <string>--menubar</string>
          </array>
          <key>RunAtLoad</key><true/>
          <key>KeepAlive</key>
          <dict><key>SuccessfulExit</key><false/></dict>
          <key>LimitLoadToSessionType</key><string>Aqua</string>
          <key>ProcessType</key><string>Interactive</string>
        </dict>
        </plist>

        """
        do {
            try fm.createDirectory(atPath: (agentPlistPath as NSString).deletingLastPathComponent,
                                   withIntermediateDirectories: true)
            try plist.write(toFile: agentPlistPath, atomically: true, encoding: .utf8)
        } catch {
            log("error:     could not write \(agentPlistPath): \(error.localizedDescription)")
            return false
        }
        guard tool("/usr/bin/plutil", ["-lint", agentPlistPath]).status == 0 else {
            log("error:     the menu bar LaunchAgent plist is malformed")
            return false
        }
        let bootstrapped = tool("/bin/launchctl", ["bootstrap", "gui/\(getuid())", agentPlistPath])
        guard bootstrapped.status == 0 else {
            log("error:     could not register the menu bar LaunchAgent: \(bootstrapped.output)")
            return false
        }
        for _ in 0..<40 {
            let state = tool("/bin/launchctl", ["print", "gui/\(getuid())/\(agentLabel)"])
            if state.output.contains("state = running") { return true }
            usleep(50_000)
        }
        log("error:     menu bar LaunchAgent registered but its host is not running")
        return false
    }

    // MARK: - signing identity

    /// macOS ties screen recording and accessibility grants to the code
    /// signature, and a changed one leaves grants that System Settings still
    /// shows as enabled while they no longer apply. Reset only on that
    /// transition — a stable signing certificate keeps permissions valid across
    /// updates, and a first sighting is not a change.
    /// `verbose` is what an install run wants — a line either way, like every
    /// other install step. The menu bar host calls it on every start and only
    /// wants to hear about a change.
    static func reconcileSigningIdentity(verbose: Bool = true) {
        guard let current = designatedRequirement(of: installedPath) else {
            log("warning:   could not read the installed app's signing requirement")
            return
        }
        let stored = CFPreferencesCopyAppValue(requirementKey, domain) as? String
        defer {
            CFPreferencesSetAppValue(requirementKey, current as CFString, domain)
            CFPreferencesAppSynchronize(domain)
        }
        guard let stored else {
            // First run of a version that records this. Whatever permissions are
            // already granted belong to this very signature, so leave them be.
            if verbose { log("note:      recorded the current signing identity") }
            return
        }
        guard stored != current else {
            if verbose { log("note:      signing identity unchanged — existing permissions kept") }
            return
        }
        if tool("/usr/bin/tccutil", ["reset", "All", bundleID]).status == 0 {
            log("note:      signing identity changed — permissions were reset once")
        } else {
            log("warning:   signing identity changed but the TCC reset failed;"
                + " re-add AIShot under Screen Recording and Accessibility")
        }
    }

    // MARK: - first-run alert

    /// Shown only for a GUI first run. A double-click out of a DMG otherwise
    /// installs in silence and then throws a capture crosshair over whatever the
    /// user was doing, which reads as a bug rather than as an installed app.
    private static func announceInstall() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = t("AIShot 설치 완료", "AIShot is installed")
        alert.informativeText = t(
            """
            메뉴 막대에 아이콘이 나타납니다. 거기서 목적지를 고르고 캡처를 시작할 수 있습니다.

            첫 캡처 때 화면 기록·손쉬운 사용 권한을 한 번 허용해 주세요.
            """,
            """
            The icon is in the menu bar. Pick a destination and start a capture from there.

            The first capture asks once for Screen Recording and Accessibility.
            """)
        alert.addButton(withTitle: t("확인", "OK"))
        alert.runModal()
    }

    // MARK: - process helper

    @discardableResult
    static func tool(_ path: String, _ arguments: [String]) -> (status: Int32, output: String) {
        guard fm.isExecutableFile(atPath: path) else { return (127, "") }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = arguments
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do { try proc.run() } catch { return (127, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return (proc.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}

private extension String {
    func trimmingTrailingSlash() -> String {
        var value = self
        while value.count > 1, value.hasSuffix("/") { value.removeLast() }
        return value
    }
}
