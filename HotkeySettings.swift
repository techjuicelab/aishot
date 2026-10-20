// Native shortcut editing for the settings panel. Editing is a draft only;
// the caller validates and applies the configuration after Save is chosen.

import AppKit

private final class ShortcutRecorderButton: NSButton {
    override var acceptsFirstResponder: Bool { true }
}

final class HotkeySettingsView: NSView {
    static let preferredHeight: CGFloat = 194

    private(set) var configuration: HotkeyConfiguration
    var onValidationChanged: ((String?) -> Void)? {
        didSet { onValidationChanged?(validationMessage()) }
    }

    private var shortcutButtons: [HotkeyAction: ShortcutRecorderButton] = [:]
    private var recordingAction: HotkeyAction?
    private var eventMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var recordingHint: String?
    private var externalValidationError: String?
    private let statusLabel = NSTextField(wrappingLabelWithString: "")

    override var isFlipped: Bool { true }

    init(frame: NSRect, configuration: HotkeyConfiguration) {
        self.configuration = configuration
        super.init(frame: frame)
        buildControls()
        refresh()
    }

    convenience init(configuration: HotkeyConfiguration = NativeHotkeyPreferences.load()) {
        self.init(frame: NSRect(x: 0, y: 0, width: 520,
                                height: Self.preferredHeight),
                  configuration: configuration)
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { finishRecording() }
        super.viewWillMove(toWindow: newWindow)
    }

    /// The caller can use this both to disable Save and to recheck before apply.
    func validationMessage() -> String? {
        if let recordingAction {
            return t("\(title(for: recordingAction)) 단축키를 입력 중입니다. Esc로 취소할 수 있습니다.",
                     "Recording \(title(for: recordingAction)). Press Esc to cancel.")
        }
        return externalValidationError ?? configuration.validationIssue()?.message
    }

    /// A registration conflict discovered by the host can be shown in place.
    /// A subsequent edit clears it so the replacement can be validated again.
    func showValidationError(_ message: String) {
        stopRecording()
        externalValidationError = message
        refresh()
    }

    func finishRecording() {
        guard recordingAction != nil else { return }
        stopRecording()
        refresh()
    }

    private func title(for action: HotkeyAction) -> String {
        switch action {
        case .screenshot: return t("일반 스크린샷", "Screenshot")
        case .scroll: return t("스크롤 스크린샷", "Scrolling screenshot")
        case .ocr: return t("스크린샷 텍스트 복사", "Copy screenshot text")
        }
    }

    private func buildControls() {
        let heading = NSTextField(labelWithString: t("단축키", "Keyboard Shortcuts"))
        heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        heading.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        addSubview(heading)

        let restore = NSButton(title: t("기본값 복원", "Restore Defaults"),
                               target: self, action: #selector(restoreDefaults(_:)))
        restore.bezelStyle = .rounded
        restore.frame = NSRect(x: 360, y: -2, width: 160, height: 28)
        restore.autoresizingMask = [.minXMargin]
        addSubview(restore)

        for (index, action) in HotkeyAction.allCases.enumerated() {
            let y = CGFloat(34 + index * 34)
            let name = NSTextField(labelWithString: title(for: action))
            name.alignment = .right
            name.frame = NSRect(x: 0, y: y + 4, width: 180, height: 22)
            addSubview(name)

            let button = ShortcutRecorderButton(frame: NSRect(x: 190, y: y,
                                                              width: 230, height: 28))
            button.bezelStyle = .rounded
            button.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
            button.target = self
            button.action = #selector(recordShortcut(_:))
            button.setAccessibilityLabel(title(for: action))
            button.toolTip = t("클릭한 뒤 새 단축키를 누르세요. Esc 취소 · Delete 해제.",
                               "Click, then press a new shortcut. Esc cancels; Delete disables.")
            shortcutButtons[action] = button
            addSubview(button)
        }

        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.frame = NSRect(x: 0, y: 140, width: 520, height: 48)
        statusLabel.autoresizingMask = [.width]
        statusLabel.maximumNumberOfLines = 3
        addSubview(statusLabel)
    }

    private func refresh() {
        for action in HotkeyAction.allCases {
            let recording = recordingAction == action
            let button = shortcutButtons[action]
            button?.title = recording
                ? t("새 단축키를 누르세요…", "Press a shortcut…")
                : (configuration[action]?.displayString ?? t("없음", "None"))
            button?.contentTintColor = recording ? .controlAccentColor : nil
            button?.setAccessibilityValue(recording
                ? t("단축키 입력 중", "Recording shortcut") : button?.title ?? "")
        }

        if let recordingAction {
            statusLabel.stringValue = recordingHint ?? t(
                "\(title(for: recordingAction)): 새 조합을 누르세요. Esc 취소 · Delete 해제.",
                "\(title(for: recordingAction)): press the new shortcut. Esc cancels; Delete disables.")
            statusLabel.textColor = recordingHint == nil ? .secondaryLabelColor : .systemRed
        } else if let issue = validationMessage() {
            statusLabel.stringValue = issue
            statusLabel.textColor = .systemRed
        } else {
            statusLabel.stringValue = t(
                "버튼을 눌러 변경하세요. Esc 취소 · Delete 해제. 저장을 눌러야 적용됩니다.",
                "Click a shortcut to change it. Esc cancels; Delete disables. Changes apply when saved.")
            statusLabel.textColor = .secondaryLabelColor
        }
        onValidationChanged?(validationMessage())
    }

    @objc private func recordShortcut(_ sender: NSButton) {
        guard let action = shortcutButtons.first(where: { $0.value === sender })?.key else { return }
        if recordingAction == action {
            finishRecording()
            return
        }
        stopRecording()
        recordingAction = action
        window?.makeFirstResponder(sender)

        // A local monitor sees command combinations before menu key equivalents.
        // Consume every key while recording, including Tab, Return, and Space.
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) {
            [weak self] event in
            guard let self, self.recordingAction != nil,
                  event.window === self.window else { return event }
            if event.type == .leftMouseDown {
                if let action = self.recordingAction,
                   let button = self.shortcutButtons[action],
                   button.bounds.contains(button.convert(event.locationInWindow, from: nil)) {
                    return event
                }
                self.finishRecording()
                return event
            }
            self.receiveKey(event)
            return nil
        }
        if let window {
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: window, queue: .main
            ) { [weak self] _ in self?.finishRecording() }
        }
        refresh()
    }

    private func receiveKey(_ event: NSEvent) {
        guard !event.isARepeat, let action = recordingAction else { return }
        if event.keyCode == 53 {
            finishRecording()
            return
        }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if (event.keyCode == 51 || event.keyCode == 117), modifiers.isEmpty {
            configuration[action] = nil
            externalValidationError = nil
            stopRecording()
            refresh()
            return
        }

        // A global shortcut must not take over ordinary typing or navigation.
        // Function keys are independently validated by HotkeyConfiguration.
        let functionKeys: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109,
                                         103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
        if modifiers.intersection([.command, .control, .option]).isEmpty,
           !functionKeys.contains(event.keyCode) {
            recordingHint = t("Command 또는 Control을 함께 눌러주세요. Esc 취소 · Delete 해제.",
                              "Include Command or Control. Esc cancels; Delete disables.")
            refresh()
            return
        }

        configuration[action] = KeyboardShortcut(event: event)
        externalValidationError = nil
        stopRecording()
        refresh()
    }

    @objc private func restoreDefaults(_ sender: Any?) {
        stopRecording()
        configuration = .defaults
        externalValidationError = nil
        refresh()
    }

    private func stopRecording() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        eventMonitor = nil
        resignObserver = nil
        recordingAction = nil
        recordingHint = nil
    }
}
