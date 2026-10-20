// Retire only AIShot's original default launcher bindings after native hotkeys
// become available. Custom bindings and every unrelated Karabiner setting stay.

import Foundation
import Darwin

enum LegacyHotkeyMigration {
    static let markerKey = "legacyHotkeysMigrated_v1_10"
    static let defaultDomain = "space.techjuicelab.aishot"

    struct Transformation {
        let data: Data
        let removedManipulatorCount: Int
        let removedRuleCount: Int
    }

    private enum MigrationError: Error, CustomStringConvertible {
        case invalidRoot
        case invalidProfiles
        case unsupportedFile
        case sourceChanged

        var description: String {
            switch self {
            case .invalidRoot: return "Karabiner configuration is not a JSON object"
            case .invalidProfiles: return "Karabiner profiles are not an array"
            case .unsupportedFile: return "Karabiner configuration is not a regular user-owned file"
            case .sourceChanged: return "Karabiner configuration changed during migration"
            }
        }
    }

    // Pure transformation: a returned zero count also returns the original
    // bytes, so an unrelated configuration does not get reformatted.
    static func transform(_ data: Data) throws -> Transformation {
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MigrationError.invalidRoot
        }
        guard var profiles = root["profiles"] as? [Any] else {
            throw MigrationError.invalidProfiles
        }
        var removedManipulators = 0
        var removedRules = 0
        for index in profiles.indices {
            guard var profile = profiles[index] as? [String: Any],
                  var modifications = profile["complex_modifications"] as? [String: Any],
                  let rules = modifications["rules"] as? [Any] else { continue }
            var keptRules: [Any] = []
            for rawRule in rules {
                guard var rule = rawRule as? [String: Any],
                      let manipulators = rule["manipulators"] as? [Any] else {
                    keptRules.append(rawRule)
                    continue
                }
                let kept = manipulators.filter { raw in
                    guard let manipulator = raw as? [String: Any], isDefaultBinding(manipulator) else {
                        return true
                    }
                    removedManipulators += 1
                    return false
                }
                if kept.count == manipulators.count {
                    keptRules.append(rawRule)
                } else if kept.isEmpty {
                    removedRules += 1
                } else {
                    rule["manipulators"] = kept
                    keptRules.append(rule)
                }
            }
            modifications["rules"] = keptRules
            profile["complex_modifications"] = modifications
            profiles[index] = profile
        }
        guard removedManipulators > 0 else {
            return Transformation(data: data, removedManipulatorCount: 0, removedRuleCount: 0)
        }
        root["profiles"] = profiles
        let rewritten = try JSONSerialization.data(withJSONObject: root,
                                                   options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return Transformation(data: rewritten, removedManipulatorCount: removedManipulators,
                              removedRuleCount: removedRules)
    }

    private static func isDefaultBinding(_ manipulator: [String: Any]) -> Bool {
        guard Set(manipulator.keys) == Set(["type", "from", "to"]),
              manipulator["type"] as? String == "basic",
              let from = manipulator["from"] as? [String: Any],
              Set(from.keys) == Set(["key_code", "modifiers"]),
              let key = from["key_code"] as? String,
              let modifiers = from["modifiers"] as? [String: Any],
              Set(modifiers.keys) == Set(["mandatory"]),
              let mandatory = modifiers["mandatory"] as? [String],
              mandatory.count == 2, Set(mandatory) == Set(["command", "shift"]),
              let actions = manipulator["to"] as? [[String: Any]], actions.count == 1,
              Set(actions[0].keys) == Set(["shell_command"]),
              let command = actions[0]["shell_command"] as? String else { return false }
        let words = command.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        let prefix = ["open", "-gnb", "space.techjuicelab.aishot"]
        switch key {
        case "2": return words == prefix || words == prefix + ["--args", "--capture"]
        case "1": return words == prefix + ["--args", "--ocr"]
        case "6":
            return words == prefix + ["--args", "--scroll"]
                || words == ["open", "-nb", "space.techjuicelab.aishot", "--args", "--scroll"]
        default: return false
        }
    }

    // The installer calls this only after the old host has stopped. Explicit
    // locations/domain keep filesystem tests isolated from the user's config.
    static func runIfNeeded(configurationPath: String? = nil, backupDirectory: String? = nil,
                            preferencesDomain: String = defaultDomain) {
        let domain = preferencesDomain as CFString
        CFPreferencesAppSynchronize(domain)
        if (CFPreferencesCopyAppValue(markerKey as CFString, domain) as? Bool) == true { return }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let source = configurationPath.map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".config/karabiner/karabiner.json")
        let backups = backupDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appendingPathComponent("Library/Application Support/AIShot/Backups", isDirectory: true)
        do {
            var originalStat = stat()
            if Darwin.lstat(source.path, &originalStat) != 0 {
                guard errno == ENOENT else { throw currentPOSIXError() }
                markComplete(domain)
                return
            }
            guard originalStat.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  originalStat.st_uid == geteuid() else { throw MigrationError.unsupportedFile }
            let original = try Data(contentsOf: source)
            let result = try transform(original)
            guard result.removedManipulatorCount > 0 else {
                markComplete(domain)
                return
            }

            let fm = FileManager.default
            try fm.createDirectory(at: backups, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            var directoryStat = stat()
            guard Darwin.lstat(backups.path, &directoryStat) == 0,
                  directoryStat.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                  directoryStat.st_uid == geteuid() else { throw MigrationError.unsupportedFile }
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: backups.path)
            let backup = backups.appendingPathComponent("karabiner-\(UUID().uuidString).json")
            try writeNewFile(original, at: backup, permissions: 0o600)
            guard try Data(contentsOf: backup) == original else { throw MigrationError.sourceChanged }

            let temporary = source.deletingLastPathComponent()
                .appendingPathComponent(".aishot-karabiner-\(UUID().uuidString).json")
            defer { try? fm.removeItem(at: temporary) }
            try writeNewFile(result.data, at: temporary, permissions: originalStat.st_mode & 0o7777,
                             ownership: (originalStat.st_uid, originalStat.st_gid))

            // Re-read immediately before the atomic replacement. Karabiner's
            // own settings window may have saved while the backup was written.
            var latestStat = stat()
            guard Darwin.lstat(source.path, &latestStat) == 0,
                  latestStat.st_dev == originalStat.st_dev,
                  latestStat.st_ino == originalStat.st_ino,
                  latestStat.st_uid == originalStat.st_uid,
                  latestStat.st_gid == originalStat.st_gid,
                  latestStat.st_mode == originalStat.st_mode,
                  try Data(contentsOf: source) == original else { throw MigrationError.sourceChanged }
            guard Darwin.rename(temporary.path, source.path) == 0 else { throw currentPOSIXError() }
            markComplete(domain)
            log("hotkeys: retired \(result.removedManipulatorCount) legacy default binding(s); backup: \(backup.path)")
        } catch {
            // No marker on failure: a later explicit install can safely retry.
            log("warning: could not retire legacy AIShot hotkeys: \(error)")
        }
    }

    private static func markComplete(_ domain: CFString) {
        let previous = CFPreferencesCopyAppValue(markerKey as CFString, domain)
        CFPreferencesSetAppValue(markerKey as CFString, kCFBooleanTrue, domain)
        if !CFPreferencesAppSynchronize(domain) {
            CFPreferencesSetAppValue(markerKey as CFString, previous, domain)
            CFPreferencesAppSynchronize(domain)
            log("warning: could not record legacy hotkey migration completion")
        }
    }

    private static func currentPOSIXError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }

    private static func writeNewFile(_ data: Data, at url: URL, permissions: mode_t,
                                     ownership: (uid_t, gid_t)? = nil) throws {
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                                     mode_t(0o600))
        guard descriptor >= 0 else { throw currentPOSIXError() }
        var succeeded = false
        defer {
            Darwin.close(descriptor)
            if !succeeded { Darwin.unlink(url.path) }
        }
        try data.withUnsafeBytes { bytes in
            guard var cursor = bytes.baseAddress else { return }
            var remaining = bytes.count
            while remaining > 0 {
                let written = Darwin.write(descriptor, cursor, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw currentPOSIXError()
                }
                guard written > 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)) }
                cursor = cursor.advanced(by: written)
                remaining -= written
            }
        }
        if let ownership {
            guard Darwin.fchown(descriptor, ownership.0, ownership.1) == 0 else { throw currentPOSIXError() }
        }
        guard Darwin.fchmod(descriptor, permissions) == 0 else { throw currentPOSIXError() }
        guard Darwin.fsync(descriptor) == 0 else { throw currentPOSIXError() }
        succeeded = true
    }
}
