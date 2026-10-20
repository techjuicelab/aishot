// AIShot — native global shortcuts and their transactional preferences.
import AppKit
import Carbon

// Modifiers use Carbon's portable command/option/control/shift bit masks.
enum HotkeyAction: String, CaseIterable, Codable, Hashable {
    case screenshot, scroll, ocr

    var displayName: String {
        switch self {
        case .screenshot: return t("스크린샷", "Screenshot")
        case .scroll: return t("스크롤 스크린샷", "Scrolling Screenshot")
        case .ocr: return t("텍스트 복사", "Copy Text")
        }
    }
}

struct KeyboardShortcut: Codable, Equatable, Hashable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let allowedModifiers = UInt32(cmdKey | optionKey | controlKey | shiftKey)
    private static let functionKeys: [UInt32: Int] = [
        122: 1, 120: 2, 99: 3, 118: 4, 96: 5, 97: 6, 98: 7, 100: 8, 101: 9, 109: 10,
        103: 11, 111: 12, 105: 13, 107: 14, 113: 15, 106: 16, 64: 17, 79: 18, 80: 19, 90: 20
    ]

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init(event: NSEvent) {
        keyCode = UInt32(event.keyCode)
        let flags = event.modifierFlags
        modifiers = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
    }

    var displayString: String {
        var prefix = ""
        if modifiers & UInt32(controlKey) != 0 { prefix += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { prefix += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { prefix += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { prefix += "⌘" }
        return prefix + keyDisplayString
    }

    private var keyDisplayString: String {
        if let number = Self.functionKeys[keyCode] { return "F\(number)" }
        let special: [UInt32: String] = [
            36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 71: "Clear", 76: "⌤",
            114: "Help", 115: "↖", 116: "⇞", 117: "⌦", 119: "↘", 121: "⇟",
            123: "←", 124: "→", 125: "↓", 126: "↑",
            65: "Keypad .", 67: "Keypad *", 69: "Keypad +", 75: "Keypad /",
            78: "Keypad −", 81: "Keypad =", 82: "Keypad 0", 83: "Keypad 1",
            84: "Keypad 2", 85: "Keypad 3", 86: "Keypad 4", 87: "Keypad 5",
            88: "Keypad 6", 89: "Keypad 7", 91: "Keypad 8", 92: "Keypad 9", 95: "Keypad ,"
        ]
        if let label = special[keyCode] { return label }
        // A non-Roman input method may not expose a layout; its ASCII-capable
        // layout still labels physical shortcuts correctly without switching it.
        if let virtualKey = UInt16(exactly: keyCode),
           let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
           let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) {
            let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
            if let bytes = CFDataGetBytePtr(data) {
                let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
                var deadKeyState: UInt32 = 0
                var characters = [UniChar](repeating: 0, count: 8)
                var count = 0
                let status = UCKeyTranslate(layout, virtualKey, UInt16(kUCKeyActionDisplay), 0,
                    UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                    &deadKeyState, characters.count, &count, &characters)
                if status == noErr, count > 0 {
                    let text = String(utf16CodeUnits: characters, count: count)
                        .trimmingCharacters(in: .controlCharacters)
                    if !text.isEmpty { return text.uppercased() }
                }
            }
        }
        return "Key \(keyCode)"
    }

    fileprivate var permitsTextInput: Bool {
        modifiers & UInt32(cmdKey | controlKey) == 0 && Self.functionKeys[keyCode] == nil
    }
}

struct HotkeyConfiguration: Codable, Equatable {
    var screenshot: KeyboardShortcut?
    var scroll: KeyboardShortcut?
    var ocr: KeyboardShortcut?

    // macOS can reserve shift-command-3 through 7 for screenshots. Keep
    // scrolling capture outside that range and validate current system settings.
    static let defaults = HotkeyConfiguration(
        screenshot: KeyboardShortcut(keyCode: 19, modifiers: UInt32(cmdKey | shiftKey)),
        scroll: KeyboardShortcut(keyCode: 28, modifiers: UInt32(cmdKey | shiftKey)),
        ocr: KeyboardShortcut(keyCode: 18, modifiers: UInt32(cmdKey | shiftKey)))
    static let disabled = HotkeyConfiguration(screenshot: nil, scroll: nil, ocr: nil)

    subscript(action: HotkeyAction) -> KeyboardShortcut? {
        get {
            switch action {
            case .screenshot: return screenshot
            case .scroll: return scroll
            case .ocr: return ocr
            }
        }
        set {
            switch action {
            case .screenshot: screenshot = newValue
            case .scroll: scroll = newValue
            case .ocr: ocr = newValue
            }
        }
    }

    func validationIssue() -> HotkeyValidationIssue? {
        precondition(Thread.isMainThread)
        var seen: [KeyboardShortcut: HotkeyAction] = [:]
        for action in HotkeyAction.allCases {
            guard let shortcut = self[action] else { continue }
            if shortcut.keyCode > 127 || [54, 55, 56, 57, 58, 59, 60, 61, 62, 63].contains(shortcut.keyCode) {
                return HotkeyValidationIssue(action: action, message: "\(action.displayName): " + t("사용할 수 없는 키입니다.", "This key cannot be used."))
            }
            if shortcut.modifiers & ~KeyboardShortcut.allowedModifiers != 0 {
                return HotkeyValidationIssue(action: action, message: "\(action.displayName): " + t("지원하지 않는 보조 키입니다.", "This modifier is not supported."))
            }
            if shortcut.permitsTextInput {
                return HotkeyValidationIssue(action: action,
                    message: "\(action.displayName): " + t("일반 문자 입력과 겹치지 않도록 ⌘ 또는 ⌃ 키를 함께 누르세요.", "Use ⌘ or ⌃ to avoid replacing ordinary text input."))
            }
            if let other = seen[shortcut] {
                return HotkeyValidationIssue(action: action,
                    message: t("\(action.displayName): \(other.displayName)과 같은 단축키를 사용할 수 없습니다.", "\(action.displayName): This shortcut is already assigned to \(other.displayName)."))
            }
            seen[shortcut] = action
        }
        var raw: Unmanaged<CFArray>?
        let status = CopySymbolicHotKeys(&raw)
        guard status == noErr, let raw else {
            return HotkeyValidationIssue(action: nil, message: t("macOS 단축키를 확인하지 못했습니다. 다시 시도하세요.", "Could not check macOS shortcuts. Try again."), status: status)
        }
        let symbolic = raw.takeRetainedValue() as NSArray
        for case let item as [String: Any] in symbolic {
            guard (item[kHISymbolicHotKeyEnabled as String] as? Bool) == true,
                  let key = item[kHISymbolicHotKeyCode as String] as? NSNumber,
                  let modifiers = item[kHISymbolicHotKeyModifiers as String] as? NSNumber else { continue }
            let reserved = KeyboardShortcut(keyCode: key.uint32Value,
                modifiers: modifiers.uint32Value & KeyboardShortcut.allowedModifiers)
            for action in HotkeyAction.allCases where self[action] == reserved {
                return .conflict(action)
            }
        }
        // The application switcher is not reported consistently by the
        // symbolic-hotkey API, but must keep working in every foreground app.
        for action in HotkeyAction.allCases {
            if let shortcut = self[action], shortcut.keyCode == 48,
               shortcut.modifiers & UInt32(cmdKey) != 0 { return .conflict(action) }
        }
        return nil
    }
}

struct HotkeyValidationIssue: Error, Equatable, LocalizedError {
    let action: HotkeyAction?
    let message: String
    var status: OSStatus = OSStatus(paramErr)
    var errorDescription: String? { message }

    fileprivate static func conflict(_ action: HotkeyAction, status: OSStatus = OSStatus(eventHotKeyExistsErr)) -> Self {
        Self(action: action, message: "\(action.displayName): " + t("macOS 또는 다른 앱에서 사용하는 단축키입니다.", "This shortcut is used by macOS or another app."), status: status)
    }
}

enum NativeHotkeyPreferences {
    static let domain = "space.techjuicelab.aishot"
    static let key = "hotkeys"

    static func load(domain: String = NativeHotkeyPreferences.domain) -> HotkeyConfiguration {
        CFPreferencesAppSynchronize(domain as CFString)
        guard let data = CFPreferencesCopyAppValue(key as CFString, domain as CFString) as? Data,
              let configuration = try? JSONDecoder().decode(HotkeyConfiguration.self, from: data)
        else { return .defaults }
        return configuration
    }

    fileprivate static func save(_ configuration: HotkeyConfiguration, domain: String) throws {
        // One value commits all three actions together. An encoded nil means
        // disabled, whereas an absent preference means use the defaults.
        let previous = CFPreferencesCopyAppValue(key as CFString, domain as CFString)
        let data = try JSONEncoder().encode(configuration)
        CFPreferencesSetAppValue(key as CFString, data as CFData, domain as CFString)
        guard CFPreferencesAppSynchronize(domain as CFString) else {
            CFPreferencesSetAppValue(key as CFString, previous, domain as CFString)
            CFPreferencesAppSynchronize(domain as CFString)
            throw HotkeyValidationIssue(action: nil, message: t("단축키를 저장하지 못했습니다. 다시 시도하세요.", "Could not save shortcuts. Try again."))
        }
    }
}

private func nativeHotkeyEventHandler(_ next: EventHandlerCallRef?, _ event: EventRef?,
                                     _ context: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let context else { return OSStatus(eventNotHandledErr) }
    return Unmanaged<NativeHotkeyManager>.fromOpaque(context).takeUnretainedValue().handle(event)
}

// Every method, including construction and destruction, belongs to the main
// thread: Carbon's registration and symbolic-hotkey APIs are not thread safe.
final class NativeHotkeyManager {
    private let preferencesDomain: String
    private let onAction: (HotkeyAction) -> Void
    private let eventSignature: OSType
    private var eventHandler: EventHandlerRef?
    private var registrations: [HotkeyAction: EventHotKeyRef] = [:]
    private var held = Set<HotkeyAction>()
    private var started = false
    private(set) var configuration: HotkeyConfiguration
    private(set) var registrationFailures: [HotkeyAction: OSStatus] = [:]
    private(set) var registrationIssues: [HotkeyAction: HotkeyValidationIssue] = [:]
    private(set) var isSuspended = false

    init(preferencesDomain: String = NativeHotkeyPreferences.domain,
         eventSignature: OSType = UInt32.random(in: 1 ... UInt32.max),
         onAction: @escaping (HotkeyAction) -> Void) {
        precondition(Thread.isMainThread)
        self.preferencesDomain = preferencesDomain
        self.eventSignature = eventSignature
        self.onAction = onAction
        configuration = NativeHotkeyPreferences.load(domain: preferencesDomain)
    }

    deinit {
        precondition(Thread.isMainThread)
        unregisterAll()
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    func start() {
        precondition(Thread.isMainThread)
        guard !started else { return }
        started = true
        if !isSuspended { registerAvailable() }
    }

    func reload() {
        precondition(Thread.isMainThread)
        unregisterAll()
        configuration = NativeHotkeyPreferences.load(domain: preferencesDomain)
        registrationFailures.removeAll()
        registrationIssues.removeAll()
        if started && !isSuspended { registerAvailable() }
    }

    func suspend() {
        precondition(Thread.isMainThread)
        guard !isSuspended else { return }
        isSuspended = true
        unregisterAll()
    }

    func resume() {
        precondition(Thread.isMainThread)
        guard isSuspended else { return }
        isSuspended = false
        held.removeAll()
        if started && registrations.isEmpty { registerAvailable() }
    }

    func apply(_ next: HotkeyConfiguration) throws {
        precondition(Thread.isMainThread)
        if let issue = next.validationIssue() { throw issue }
        try ensureEventHandler()
        let previous = configuration
        let restoreRegistrations = !registrations.isEmpty
        unregisterAll()
        do {
            var prospective: [HotkeyAction: EventHotKeyRef] = [:]
            do {
                for action in HotkeyAction.allCases {
                    if let shortcut = next[action] { prospective[action] = try register(shortcut, for: action) }
                }
                try NativeHotkeyPreferences.save(next, domain: preferencesDomain)
            } catch {
                for reference in prospective.values { UnregisterEventHotKey(reference) }
                throw error
            }
            configuration = next
            registrations = prospective
            registrationFailures.removeAll()
            registrationIssues.removeAll()
            started = true
            // Keep successfully validated registrations while the settings
            // window closes. resume only enables callbacks, avoiding a second
            // registration attempt and a conflict race after preferences save.
        } catch {
            configuration = previous
            if restoreRegistrations { registerAvailable() }
            throw error
        }
    }

    private func ensureEventHandler() throws {
        guard eventHandler == nil else { return }
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let status = InstallEventHandler(GetApplicationEventTarget(), nativeHotkeyEventHandler,
            types.count, &types, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        guard status == noErr else {
            throw HotkeyValidationIssue(action: nil, message: t("단축키를 시작하지 못했습니다. 앱을 다시 실행하세요.", "Could not start shortcuts. Relaunch the app."), status: status)
        }
    }

    private func register(_ shortcut: KeyboardShortcut, for action: HotkeyAction) throws -> EventHotKeyRef {
        let id = UInt32(HotkeyAction.allCases.firstIndex(of: action)! + 1)
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers,
            EventHotKeyID(signature: eventSignature, id: id), GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive), &reference)
        guard status == noErr, let reference else { throw HotkeyValidationIssue.conflict(action, status: status) }
        return reference
    }

    private func registerAvailable() {
        registrationFailures.removeAll()
        registrationIssues.removeAll()
        do { try ensureEventHandler() } catch let issue as HotkeyValidationIssue {
            for action in HotkeyAction.allCases where configuration[action] != nil {
                registrationFailures[action] = issue.status
                registrationIssues[action] = issue
            }
            return
        } catch { return }
        var seen = Set<KeyboardShortcut>()
        for action in HotkeyAction.allCases {
            guard let shortcut = configuration[action] else { continue }
            var single = HotkeyConfiguration.disabled
            single[action] = shortcut
            do {
                if let issue = single.validationIssue() { throw issue }
                guard seen.insert(shortcut).inserted else { throw HotkeyValidationIssue.conflict(action) }
                registrations[action] = try register(shortcut, for: action)
            } catch let issue as HotkeyValidationIssue {
                registrationFailures[action] = issue.status
                registrationIssues[action] = issue
            } catch { registrationFailures[action] = OSStatus(paramErr) }
        }
    }

    private func unregisterAll() {
        for reference in registrations.values { UnregisterEventHotKey(reference) }
        registrations.removeAll()
        held.removeAll()
    }

    fileprivate func handle(_ event: EventRef) -> OSStatus {
        var id = EventHotKeyID()
        let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
        guard status == noErr, id.signature == eventSignature, id.id > 0,
              id.id <= HotkeyAction.allCases.count else { return OSStatus(eventNotHandledErr) }
        let action = HotkeyAction.allCases[Int(id.id) - 1]
        switch GetEventKind(event) {
        case UInt32(kEventHotKeyReleased): held.remove(action)
        case UInt32(kEventHotKeyPressed):
            guard !isSuspended, registrations[action] != nil, held.insert(action).inserted else { return noErr }
            onAction(action)
        default: return OSStatus(eventNotHandledErr)
        }
        return noErr
    }
}
