import AppKit

struct PhonePhotoSettings {
    enum PasteQuality: String, CaseIterable { case saved, ai, custom }

    var saveQuality: PhonePhoto.Quality = .original
    var saveCustom: PhonePhoto.JPEGOptions = .customDefault
    var pasteQuality: PasteQuality = .saved
    var pasteCustom: PhonePhoto.JPEGOptions = .customDefault

    private static let domain = "space.techjuicelab.aishot" as CFString
    private static let key = "iphonePhotoSettings" as CFString

    static func load() -> Self {
        CFPreferencesAppSynchronize(domain)
        guard let values = CFPreferencesCopyAppValue(key, domain) as? [String: Any],
              let saveQuality = (values["saveQuality"] as? String).flatMap(PhonePhoto.Quality.init(rawValue:)),
              let pasteQuality = (values["pasteQuality"] as? String).flatMap(PasteQuality.init(rawValue:)),
              let saveCustom = options(longEdge: values["saveLongEdge"] as? Int,
                                       compression: values["saveCompression"] as? Int),
              let pasteCustom = options(longEdge: values["pasteLongEdge"] as? Int,
                                        compression: values["pasteCompression"] as? Int) else { return Self() }
        return Self(saveQuality: saveQuality, saveCustom: saveCustom,
                    pasteQuality: pasteQuality, pasteCustom: pasteCustom)
    }

    func save() {
        let values: [String: Any] = [
            "saveQuality": saveQuality.rawValue,
            "saveLongEdge": saveCustom.maxLongEdge,
            "saveCompression": saveCustom.compression,
            "pasteQuality": pasteQuality.rawValue,
            "pasteLongEdge": pasteCustom.maxLongEdge,
            "pasteCompression": pasteCustom.compression
        ]
        CFPreferencesSetAppValue(Self.key, values as CFDictionary, Self.domain)
        CFPreferencesAppSynchronize(Self.domain)
    }

    fileprivate static func options(longEdge: Int?, compression: Int?) -> PhonePhoto.JPEGOptions? {
        guard let longEdge, PhonePhoto.JPEGOptions.pixelRange.contains(longEdge),
              let compression, PhonePhoto.JPEGOptions.compressionRange.contains(compression) else { return nil }
        return PhonePhoto.JPEGOptions(maxLongEdge: longEdge, compression: compression)
    }
}

final class PhonePhotoSettingsView: NSView, NSTextFieldDelegate {
    private struct QualityControls {
        let preset: NSPopUpButton
        let longEdge: NSTextField
        let compression: NSTextField

        var selected: String? { preset.selectedItem?.representedObject as? String }

        var customOptions: PhonePhoto.JPEGOptions? {
            func integer(in field: NSTextField) -> Int? {
                let text = field.currentEditor()?.string ?? field.stringValue
                return Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return PhonePhotoSettings.options(longEdge: integer(in: longEdge), compression: integer(in: compression))
        }

        func enableCustomFields(_ enabled: Bool) {
            longEdge.isEnabled = enabled
            compression.isEnabled = enabled
        }
    }

    private let initialSettings: PhonePhotoSettings
    private var saveControls: QualityControls!
    private var pasteControls: QualityControls!
    private let status = NSTextField(wrappingLabelWithString: "")

    var onValidationChanged: (() -> Void)? {
        didSet { onValidationChanged?() }
    }

    override var isFlipped: Bool { true }

    init(frame: NSRect, settings: PhonePhotoSettings = .load()) {
        initialSettings = settings
        super.init(frame: frame)

        saveControls = addGroup(t("저장할 사진", "Saved photo"), y: 8, presets: [
            ("original", t("원본 크기", "Original size")),
            ("high", t("고화질", "High")),
            ("compact", t("용량 절약", "Save space")),
            ("custom", t("직접 설정", "Custom"))
        ], selected: settings.saveQuality.rawValue, options: settings.saveCustom, note: t(
            "고화질은 긴 변을 최대 2,560 px로, 용량 절약은 최대 1,600 px로 저장합니다.",
            "High limits the long edge to 2,560 px. Save space limits it to 1,600 px."))

        let divider = NSBox(frame: NSRect(x: 0, y: 143, width: 520, height: 1))
        divider.boxType = .separator
        addSubview(divider)

        pasteControls = addGroup(t("붙여넣을 이미지", "Pasted image"), y: 156, presets: [
            ("saved", t("저장한 사진 사용", "Use saved photo")),
            ("ai", t("AI용 최적화", "Optimize for AI")),
            ("custom", t("직접 설정", "Custom"))
        ], selected: settings.pasteQuality.rawValue, options: settings.pasteCustom, note: t(
            "AI용 최적화는 읽히는 작은 글자를 기준으로 크기를 조절합니다. 터미널에는 이 JPEG의 경로를 붙여넣습니다.",
            "Optimize for AI adjusts size to preserve recognized small text. Terminals get the JPEG path."))

        status.frame = NSRect(x: 0, y: 301, width: 520, height: 32)
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.textColor = .systemRed
        addSubview(status)
        presetChanged()
    }

    required init?(coder: NSCoder) { nil }

    func validationMessage() -> String? {
        if saveControls.selected == "custom", saveControls.customOptions == nil {
            return customRangeMessage(for: t("저장할 사진", "Saved photo"))
        }
        if pasteControls.selected == "custom", pasteControls.customOptions == nil {
            return customRangeMessage(for: t("붙여넣을 이미지", "Pasted image"))
        }
        return nil
    }

    func selectedSettings() -> PhonePhotoSettings? {
        guard validationMessage() == nil,
              let saveQuality = saveControls.selected.flatMap(PhonePhoto.Quality.init(rawValue:)),
              let pasteQuality = pasteControls.selected.flatMap(PhonePhotoSettings.PasteQuality.init(rawValue:))
        else { return nil }
        return PhonePhotoSettings(saveQuality: saveQuality,
                                  saveCustom: saveControls.customOptions ?? initialSettings.saveCustom,
                                  pasteQuality: pasteQuality,
                                  pasteCustom: pasteControls.customOptions ?? initialSettings.pasteCustom)
    }

    func controlTextDidChange(_ notification: Notification) {
        refreshValidation()
    }

    private func customRangeMessage(for group: String) -> String {
        let pixels = PhonePhoto.JPEGOptions.pixelRange
        let compression = PhonePhoto.JPEGOptions.compressionRange
        return t("‘\(group)’에서 긴 변은 \(pixels.lowerBound)–\(pixels.upperBound) px, JPEG 품질은 \(compression.lowerBound)–\(compression.upperBound)%로 입력하세요.",
                 "Enter a long edge of \(pixels.lowerBound)–\(pixels.upperBound) px and JPEG quality of \(compression.lowerBound)–\(compression.upperBound)% under \(group).")
    }

    @objc private func presetChanged() {
        saveControls.enableCustomFields(saveControls.selected == "custom")
        pasteControls.enableCustomFields(pasteControls.selected == "custom")
        refreshValidation()
    }

    private func refreshValidation() {
        status.stringValue = validationMessage() ?? ""
        onValidationChanged?()
    }

    private func addGroup(_ title: String, y: CGFloat, presets: [(value: String, title: String)],
                          selected: String, options: PhonePhoto.JPEGOptions, note: String) -> QualityControls {
        @discardableResult
        func label(_ text: String, x: CGFloat, row: CGFloat, width: CGFloat) -> NSTextField {
            let field = NSTextField(labelWithString: text)
            field.frame = NSRect(x: x, y: y + row, width: width, height: 20)
            addSubview(field)
            return field
        }

        func numberField(_ number: Int, label: String, x: CGFloat) -> NSTextField {
            let field = NSTextField(string: String(number))
            field.frame = NSRect(x: x, y: y + 69, width: 70, height: 24)
            field.alignment = .right
            field.delegate = self
            field.setAccessibilityLabel("\(title), \(label)")
            addSubview(field)
            return field
        }

        label(title, x: 0, row: 0, width: 260).font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let presetLabel = t("품질", "Quality")
        label(presetLabel, x: 0, row: 35, width: 105)
        let preset = NSPopUpButton(frame: NSRect(x: 110, y: y + 31, width: 270, height: 26))
        for choice in presets {
            preset.addItem(withTitle: choice.title)
            preset.lastItem?.representedObject = choice.value
            if choice.value == selected { preset.select(preset.lastItem) }
        }
        preset.target = self
        preset.action = #selector(presetChanged)
        preset.setAccessibilityLabel("\(title), \(presetLabel)")
        addSubview(preset)

        let sizeLabel = t("긴 변 최대", "Max long edge")
        label(sizeLabel, x: 0, row: 72, width: 106)
        let longEdge = numberField(options.maxLongEdge, label: "\(sizeLabel) (px)", x: 110)
        label("px", x: 185, row: 72, width: 28)
        let compressionLabel = t("JPEG 품질", "JPEG quality")
        label(compressionLabel, x: 228, row: 72, width: 124)
        let compression = numberField(options.compression, label: "\(compressionLabel) (%)", x: 350)
        label("%", x: 425, row: 72, width: 30)

        let help = NSTextField(wrappingLabelWithString: note)
        help.frame = NSRect(x: 0, y: y + 101, width: 520, height: 31)
        help.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        help.textColor = .secondaryLabelColor
        addSubview(help)
        return QualityControls(preset: preset, longEdge: longEdge, compression: compression)
    }
}
