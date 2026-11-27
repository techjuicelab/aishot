import AppKit
import Carbon
import ImageIO
import ObjectiveC
import UniformTypeIdentifiers
import Vision

enum PhonePhoto {
    enum Quality: String, CaseIterable {
        case original, high, compact, custom
    }

    struct JPEGOptions: Codable, Equatable {
        var maxLongEdge: Int
        var compression: Int

        static let pixelRange = 320...12000
        static let compressionRange = 40...100
        static let customDefault = JPEGOptions(maxLongEdge: 2560, compression: 90)
        static let aiDefault = JPEGOptions(maxLongEdge: 2048, compression: 82)
    }

    static func isSupportedImage(_ data: Data) -> Bool {
        imageSource(from: data) != nil
    }

    private static func imageSource(from data: Data) -> CGImageSource? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetCount(source) > 0,
              let identifier = CGImageSourceGetType(source),
              let type = UTType(identifier as String), type.conforms(to: .image) else { return nil }
        return source
    }

    static func jpeg(from data: Data, quality: Quality = .original,
                     custom: JPEGOptions = .customDefault) -> Data? {
        switch quality {
        case .original:
            guard let source = imageSource(from: data) else { return nil }
            if CGImageSourceGetType(source) as String? == UTType.jpeg.identifier { return data }
            return encode(source, as: .jpeg, jpegCompression: 0.95)
        case .high:
            return jpeg(from: data, options: .customDefault)
        case .compact:
            return jpeg(from: data, options: JPEGOptions(maxLongEdge: 1600, compression: 78))
        case .custom:
            return jpeg(from: data, options: custom)
        }
    }

    static func jpeg(from data: Data, options: JPEGOptions) -> Data? {
        guard JPEGOptions.pixelRange.contains(options.maxLongEdge),
              JPEGOptions.compressionRange.contains(options.compression),
              let source = imageSource(from: data) else { return nil }
        return encode(source, as: .jpeg, maximumLongEdge: options.maxLongEdge,
                      jpegCompression: Double(options.compression) / 100)
    }

    static func aiJPEG(from data: Data, recognize: (Data) -> [String]? = recognizedTextLines) -> Data? {
        guard let original = jpeg(from: data) else { return nil }
        // Continuity often already delivers a compact JPEG. Avoid recompression
        // and OCR for these photos: pasting JPEG still avoids the larger PNG.
        if original == data, original.count <= 1_000_000,
           let source = imageSource(from: data),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Int,
           let height = properties[kCGImagePropertyPixelHeight] as? Int,
           max(width, height) <= JPEGOptions.aiDefault.maxLongEdge { return original }

        guard let sourceLines = recognize(data) else { return original }
        let requiredLines = lineCounts(sourceLines)

        var smallest = original
        let candidates: [JPEGOptions] = [.aiDefault, JPEGOptions(maxLongEdge: 2560, compression: 88)]
        for options in candidates {
            guard let candidate = jpeg(from: data, options: options), candidate.count < smallest.count else { continue }
            if !requiredLines.isEmpty {
                guard let candidateLines = recognize(candidate) else { continue }
                let counts = lineCounts(candidateLines)
                guard requiredLines.allSatisfy({ counts[$0.key, default: 0] >= $0.value }) else { continue }
            }
            smallest = candidate
        }
        return smallest
    }

    static func recognizedTextLines(_ data: Data) -> [String]? {
        guard let source = imageSource(from: data),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientationValue = properties?[kCGImagePropertyOrientation] as? UInt32 ?? 1
        let orientation = CGImagePropertyOrientation(rawValue: orientationValue) ?? .up

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ko-KR", "en-US"]
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0
        let handler = VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:])
        do { try handler.perform([request]) }
        catch { return nil }
        return request.results?.compactMap { $0.topCandidates(1).first?.string } ?? []
    }

    private static func lineCounts(_ lines: [String]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for line in lines {
            let normalized = line.precomposedStringWithCanonicalMapping
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if !normalized.isEmpty { counts[normalized, default: 0] += 1 }
        }
        return counts
    }

    static func png(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return encode(source, as: .png)
    }

    private static func encode(_ source: CGImageSource, as type: UTType, maximumLongEdge: Int? = nil,
                               jpegCompression: Double? = nil) -> Data? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let longEdge = max(width, height)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(longEdge, maximumLongEdge ?? longEdge)
        ]
        // Apply EXIF orientation before writing formats whose receivers may
        // ignore that metadata. Smaller presets also limit the long edge.
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)
        else { return nil }
        let propertiesForOutput = jpegCompression.map { [kCGImageDestinationLossyCompressionQuality: $0] as CFDictionary }
        CGImageDestinationAddImage(destination, image, propertiesForOutput)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    static func save(_ jpeg: Data, in directory: URL, now: Date = Date(), suffix: String = "") throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "'IMG_'yyyyMMdd_HHmmss"
        let name = formatter.string(from: now) + suffix
        let manager = FileManager.default
        let staging = directory.appendingPathComponent(".aishot-photo-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: staging) }
        try jpeg.write(to: staging, options: .withoutOverwriting)
        var serial = 1
        while true {
            let collisionNumber = serial == 1 ? "" : " (\(serial))"
            let url = directory.appendingPathComponent(name + collisionNumber + ".jpg")
            do {
                try manager.moveItem(at: staging, to: url)
                return url
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                serial += 1
            }
        }
    }
}

// The hidden responder and the system-populated menu adapt ContinuityCapture
// by TechJuiceLab (MIT). This class lives only in the one-shot photo worker.
final class PhonePhotoCapture: NSObject, NSApplicationDelegate {
    enum Outcome {
        case photo(Data)
        case unavailable
        case cancelled
        case timedOut
        case invalidPhoto
    }

    private let timeout: TimeInterval
    private let waitingLabel: String
    private let cancelLabel: String
    private var outcome: Outcome?
    private var window: PhotoReceiverWindow?
    private var textView: PhotoReceiverView?
    private var fileMenu: NSMenu?
    private var invoked = false
    private var preexistingVisibleWindows = Set<ObjectIdentifier>()
    private var systemPanel: NSWindow?
    private var panelDisappearedAt: TimeInterval?
    private var waitingPanel: PhotoWaitingPanel?
    private var panelTimer: Timer?
    private var keyMonitor: Any?

    init(timeout: TimeInterval, waitingLabel: String = "Waiting for iPhone…",
         cancelLabel: String = "Cancel") {
        self.timeout = timeout
        self.waitingLabel = waitingLabel
        self.cancelLabel = cancelLabel
    }

    func run() -> Outcome {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = self
        app.run()
        NotificationCenter.default.removeObserver(self)
        panelTimer?.invalidate()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        waitingPanel?.close()
        window?.orderOut(nil)
        window?.close()
        app.delegate = nil
        return outcome ?? .cancelled
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        let mainMenu = NSMenu()
        let applicationItem = NSMenuItem()
        applicationItem.submenu = NSMenu(title: "AIShot")
        mainMenu.addItem(applicationItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        let importItem = NSMenuItem(title: "Import from Device", action: nil, keyEquivalent: "")
        importItem.identifier = NSMenuItem.importFromDeviceIdentifier
        fileMenu.addItem(importItem)
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)
        self.fileMenu = fileMenu
        NSApp.mainMenu = mainMenu
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.registerServicesMenuSendTypes([], returnTypes: NSImage.imageTypes.map {
            NSPasteboard.PasteboardType($0)
        })

        let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = NSRect(x: screen.midX - 150, y: screen.midY - 60, width: 300, height: 120)
        let window = PhotoReceiverWindow(contentRect: frame, styleMask: [.borderless],
                                         backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.alphaValue = 0.02
        window.ignoresMouseEvents = true
        window.level = .floating
        let view = PhotoReceiverView(frame: NSRect(origin: .zero, size: frame.size))
        view.isRichText = true
        view.isEditable = true
        view.importsGraphics = true
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        self.window = window
        textView = view

        NotificationCenter.default.addObserver(self, selector: #selector(storageChanged(_:)),
            name: NSTextStorage.didProcessEditingNotification, object: view.textStorage)
        NotificationCenter.default.addObserver(self, selector: #selector(panelClosed(_:)),
            name: NSWindow.willCloseNotification, object: nil)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == UInt16(kVK_Escape), self.outcome == nil else { return event }
            self.cancelPhoto(nil)
            return nil
        }

        // AppKit attaches and fills the device menu asynchronously.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(200)) { [weak self] in
            self?.findDevice(attempt: 1)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.finish(.timedOut)
        }
    }

    private func findDevice(attempt: Int) {
        guard outcome == nil else { return }
        if fileMenu?.items.contains(where: { $0.submenu != nil }) == false { fileMenu?.update() }
        if let submenu = fileMenu?.items.lazy.compactMap(\.submenu).first {
            submenu.update()
            let items = submenu.items
            let photoActions = items.indices.filter { Self.isPhotoAction(items[$0]) }
            let iphone = photoActions.first { index in
                for heading in items[..<index].reversed() {
                    if heading.isSeparatorItem { break }
                    if !heading.isEnabled, heading.title.localizedCaseInsensitiveContains("iPhone") {
                        return true
                    }
                }
                return false
            }
            if let index = iphone ?? photoActions.first {
                // A system window can be created early and ordered in only
                // after the action. Ignore only windows already on screen.
                preexistingVisibleWindows = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
                invoked = true
                watchForSystemPanel()
                submenu.performActionForItem(at: index)
                return
            }
        }
        guard attempt < 15 else { finish(.unavailable); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(200)) { [weak self] in
            self?.findDevice(attempt: attempt + 1)
        }
    }

    private static func isPhotoAction(_ item: NSMenuItem) -> Bool {
        guard item.isEnabled, item.action != nil else { return false }
        let title = item.title
        if title == "Take Photo" || title == "사진 찍기" { return true }
        // For other system languages, look up the label in the bundle that
        // owns the generated action instead of matching a private selector.
        guard let target = item.target, let targetClass = object_getClass(target) else { return false }
        return title == Bundle(for: targetClass).localizedString(forKey: "Take Photo", value: nil, table: nil)
    }

    @objc private func storageChanged(_ notification: Notification) {
        // Leave NSTextStorage's editing pass before reading attachments.
        DispatchQueue.main.async { [weak self] in self?.readPhoto() }
    }

    private func readPhoto() {
        guard invoked, outcome == nil, let storage = textView?.textStorage else { return }
        var sawAttachment = false
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, stop in
            guard let attachment = value as? NSTextAttachment else { return }
            sawAttachment = true
            let file = attachment.fileWrapper
            let bytes = (file?.isRegularFile == true ? file?.regularFileContents : nil) ?? attachment.contents
            if let bytes, PhonePhoto.isSupportedImage(bytes) {
                finish(.photo(bytes))
                stop.pointee = true
            }
        }
        if sawAttachment, outcome == nil { finish(.invalidPhoto) }
    }

    private func watchForSystemPanel() {
        let started = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 0.125, repeats: true) { [weak self] _ in
            self?.checkSystemPanel(started: started)
        }
        panelTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        checkSystemPanel(started: started)
    }

    private func isSystemWindow(_ candidate: NSWindow) -> Bool {
        candidate !== window && candidate !== waitingPanel
            && !preexistingVisibleWindows.contains(ObjectIdentifier(candidate))
    }

    private func checkSystemPanel(started: TimeInterval) {
        guard outcome == nil else { return }
        if let visible = NSApp.windows.first(where: { $0.isVisible && isSystemWindow($0) }) {
            systemPanel = visible
            panelDisappearedAt = nil
            waitingPanel?.orderOut(nil)
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        if let systemPanel, NSApp.isActive || !systemPanel.hidesOnDeactivate {
            // A transfer can arrive after the panel closes or is ordered out.
            // Brief visibility changes must not cancel a successful import.
            let disappearedAt = panelDisappearedAt ?? now
            panelDisappearedAt = disappearedAt
            if now - disappearedAt >= 1.8 {
                readPhoto()
                finish(.cancelled)
            }
            return
        }

        panelDisappearedAt = nil
        // Some macOS versions keep their UI outside this process. Provide a
        // Cancel button without making either waiting panel the key window.
        if now - started >= 1.0, waitingPanel?.isVisible != true {
            showWaitingPanel()
        }
    }

    private func showWaitingPanel() {
        if let waitingPanel {
            waitingPanel.orderFrontRegardless()
            return
        }
        let desktop = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = NSRect(x: desktop.midX - 140, y: desktop.maxY - 138, width: 280, height: 56)
        let panel = PhotoWaitingPanel(contentRect: frame, styleMask: [.titled, .closable, .nonactivatingPanel],
                                      backing: .buffered, defer: false)
        panel.title = waitingLabel
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        let cancel = PhotoCancelButton(title: cancelLabel, target: self, action: #selector(cancelPhoto(_:)))
        cancel.bezelStyle = .rounded
        cancel.frame = NSRect(x: 80, y: 13, width: 120, height: 30)
        panel.contentView?.addSubview(cancel)
        waitingPanel = panel
        panel.orderFrontRegardless()
    }

    @objc private func panelClosed(_ notification: Notification) {
        guard outcome == nil, let closed = notification.object as? NSWindow else { return }
        if closed === waitingPanel {
            cancelPhoto(nil)
        } else if invoked, closed === systemPanel || (closed.isVisible && isSystemWindow(closed)) {
            systemPanel = closed
            panelDisappearedAt = ProcessInfo.processInfo.systemUptime
        }
    }

    @objc private func cancelPhoto(_ sender: Any?) { finish(.cancelled) }

    private func finish(_ result: Outcome) {
        guard outcome == nil else { return }
        outcome = result
        NSApp.stop(nil)
        // stop(_:) takes effect after the next AppKit event is dispatched.
        if let wake = NSEvent.otherEvent(with: .applicationDefined, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
            NSApp.postEvent(wake, atStart: true)
        }
    }
}

private final class PhotoWaitingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class PhotoCancelButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class PhotoReceiverWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class PhotoReceiverView: NSTextView {
    // Continuity delivers through Services. A keyboard paste during capture
    // would otherwise put an unrelated clipboard image in the receiver.
    override func paste(_ sender: Any?) {}

    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?,
                                 returnType: NSPasteboard.PasteboardType?) -> Any? {
        if let returnType, NSImage.imageTypes.contains(returnType.rawValue) { return self }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }
}
