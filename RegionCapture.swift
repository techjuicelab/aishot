// AIShot — the interactive region capture, and a repair for the drag that
// screencapture(1) never sees.
//
// `screencapture -i` only tracks a drag that starts after its overlay is on
// screen. One that starts earlier belongs to the window underneath: that app
// gets the drag — a text selection, a moved file — and the capture, when it
// does appear, sits there with nothing selected until the user gives up with
// Esc. The gap is the time from the shortcut to the overlay. Launching a
// worker app before screencapture alone took 0.05–0.1 s when warm and
// 0.3–0.4 s for the first capture after a pause, which is how most people
// capture; the overlay itself then needs another 0.05–0.3 s depending on load.
// Someone who knows where they are going is already dragging by then.
//
// So the menu bar host starts screencapture itself, within milliseconds of the
// shortcut, and for the first moments of the capture the session filters the
// left mouse button with an event tap. A drag that begins
// before the overlay is on screen is withheld from everything — the app
// underneath never gets it — and once it is finished and the overlay is ready
// the session draws the same rectangle with synthetic events, which
// screencapture takes like any other drag. Every other event passes through
// untouched. Filtering and posting input need Accessibility, which auto-paste
// already requires; without it the session behaves like plain screencapture.
//
// Measured with synthetic input on macOS 27.2: drags started 0, 10, 30 and
// 50 ms after the trigger produced a capture 4 of 4 times through this
// session, against 0 of 4 with 1.10.1, which launched a worker app first
// (screencapture started 50–300 ms in). Holding ⌘⇧ from the shortcut through
// the drag is fine and needs no help; screencapture only stops taking drags if
// ⌘ is pressed anew while it is open, which no normal capture does.

import AppKit
import ApplicationServices

final class RegionCaptureSession {
    let path: String
    private let timeout: TimeInterval
    private let process = Process()
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var watchdog: DispatchWorkItem?
    private var replayTimer: Timer?
    private var completion: ((Int32) -> Void)?

    private struct DroppedDrag {
        var start: CGPoint
        var end: CGPoint
        let reason: String
    }
    private var dropped: DroppedDrag?
    private var buttonDown = false
    /// The current gesture is being kept from reaching anyone.
    private var withholding = false
    private var overlaySeen = false
    /// Whether the tap may drop events, or only watch them.
    private var filtering = false
    private var startedAt = Date()
    /// AISHOT_CAPTURE_TRACE=1 logs every step with millisecond timing.
    private let tracing = ProcessInfo.processInfo.environment["AISHOT_CAPTURE_TRACE"] == "1"
    private func trace(_ message: @autoclosure () -> String) {
        guard tracing else { return }
        log(String(format: "capture trace +%.0fms ", Date().timeIntervalSince(startedAt) * 1000) + message())
    }

    /// Stamped on the events this session posts, so its own tap ignores them.
    static let syntheticMarker: Int64 = 0x4149_5348 // "AISH"
    /// How long to wait for the drag to end and the overlay to be ready before
    /// giving up on a redraw. Past this the user has moved on.
    private static let releaseWait: TimeInterval = 3
    /// The overlay normally appears 0.1 s in. Past this, a missing overlay
    /// means something else is wrong, and withholding clicks would only leave
    /// the user with a mouse that does nothing.
    private static let overlayGrace: TimeInterval = 2
    /// Anything smaller is a click, not a selection. A click is never replayed:
    /// in selection mode it would end the capture.
    private static let minimumDrag: CGFloat = 6

    init(path: String, timeout: TimeInterval) {
        self.path = path
        self.timeout = timeout
    }

    /// Starts screencapture. `completion` runs on the main thread with its
    /// exit status once it has gone; whether a file exists at `path` is the
    /// actual answer, since Esc and a failed capture both exit 0.
    ///
    /// Main thread only. The caller keeps the session alive until completion.
    func start(completion: @escaping (Int32) -> Void) throws {
        precondition(Thread.isMainThread)
        self.completion = completion
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", path]
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            DispatchQueue.main.async { self?.finish(status) }
        }
        // Before the launch, so a drag that beats the overlay is still seen.
        startedAt = Date()
        installTap()
        do {
            try process.run()
        } catch {
            removeTap()
            self.completion = nil
            throw error
        }
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self, self.process.isRunning else { return }
            log("capture: no selection after \(Int(self.timeout))s — closing the capture")
            self.process.terminate()
        }
        self.watchdog = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: watchdog)
    }

    private func finish(_ status: Int32) {
        guard let completion else { return }
        trace("screencapture exited \(status)")
        self.completion = nil
        removeTap()
        replayTimer?.invalidate()
        replayTimer = nil
        watchdog?.cancel()
        watchdog = nil
        completion(status)
    }

    // MARK: - watching the mouse

    private func installTap() {
        let mask = (CGEventMask(1) << CGEventType.leftMouseDown.rawValue)
            | (CGEventMask(1) << CGEventType.leftMouseDragged.rawValue)
            | (CGEventMask(1) << CGEventType.leftMouseUp.rawValue)
        let context = Unmanaged.passUnretained(self).toOpaque()
        var created: CFMachPort?
        if AXIsProcessTrusted() {
            created = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                        options: .defaultTap, eventsOfInterest: mask,
                                        callback: regionCaptureTapCallback, userInfo: context)
        }
        filtering = created != nil
        if created == nil {
            created = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap,
                                        options: .listenOnly, eventsOfInterest: mask,
                                        callback: regionCaptureTapCallback, userInfo: context)
        }
        guard let tap = created else {
            log("capture: could not watch the mouse — a dropped selection will not be redrawn")
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        tapSource = source
        trace("tap installed (filtering: \(filtering))")
    }

    private func removeTap() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        tap = nil
        tapSource = nil
    }

    /// Returns true when the event must not be delivered.
    fileprivate func observe(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        default:
            break
        }
        let synthetic = event.getIntegerValueField(.eventSourceUserData) == Self.syntheticMarker
        trace("event \(type.rawValue) synthetic=\(synthetic) running=\(process.isRunning) overlay=\(overlayOnScreen()) withholding=\(withholding)")
        guard process.isRunning, !synthetic else { return false }
        let point = event.location
        switch type {
        case .leftMouseDown:
            buttonDown = true
            replayTimer?.invalidate()
            replayTimer = nil
            dropped = nil
            withholding = false
            if !overlaySeen, Date().timeIntervalSince(startedAt) < Self.overlayGrace {
                if overlayOnScreen() {
                    overlaySeen = true // from here on screencapture takes drags itself
                } else {
                    dropped = DroppedDrag(start: point, end: point,
                                          reason: "it began before the selection overlay appeared")
                }
            }
            withholding = filtering && dropped != nil
            return withholding
        case .leftMouseDragged:
            dropped?.end = point
            return withholding
        case .leftMouseUp:
            buttonDown = false
            let swallow = withholding
            withholding = false
            guard var drag = dropped else { return swallow }
            drag.end = point
            guard abs(drag.end.x - drag.start.x) >= Self.minimumDrag,
                  abs(drag.end.y - drag.start.y) >= Self.minimumDrag else {
                dropped = nil
                return swallow
            }
            dropped = drag
            scheduleReplay()
            return swallow
        default:
            return false
        }
    }

    /// The overlay is a window owned by the screencapture process itself.
    /// Owner and layer are readable without Screen Recording.
    private func overlayOnScreen() -> Bool {
        guard process.isRunning else { return false }
        let pid = process.processIdentifier
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        return windows.contains { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid }
    }

    // MARK: - redrawing a dropped selection

    private func scheduleReplay() {
        let deadline = Date(timeIntervalSinceNow: Self.releaseWait)
        var overlaySince: Date?
        replayTimer?.invalidate()
        let timer = Timer(timeInterval: 0.015, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            guard self.process.isRunning, !self.buttonDown, let drag = self.dropped else {
                timer.invalidate()
                self.replayTimer = nil
                return
            }
            // A window on screen is not yet an overlay tracking the mouse; give
            // a freshly shown one a moment before drawing into it. Should the
            // overlay never be identified — a future screencapture drawing it
            // from another process, say — a second into the capture it is
            // surely up, and a withheld drag must not be lost to a lookup.
            if overlaySince == nil, self.overlayOnScreen() { overlaySince = Date() }
            let overlayReady = overlaySince.map { Date().timeIntervalSince($0) >= 0.15 }
                ?? (Date().timeIntervalSince(self.startedAt) >= 1.0)
            let mouseHeld = CGEventSource.buttonState(.hidSystemState, button: .left)
            if mouseHeld || !overlayReady {
                if Date() > deadline {
                    log("capture: a selection was missed because \(drag.reason), and the capture "
                        + "was not ready in time to redraw it — drag again")
                    timer.invalidate()
                    self.replayTimer = nil
                    self.dropped = nil
                }
                return
            }
            timer.invalidate()
            self.replayTimer = nil
            self.dropped = nil
            self.replay(drag)
        }
        replayTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func replay(_ drag: DroppedDrag) {
        guard AXIsProcessTrusted() else {
            log("capture: a selection was missed because \(drag.reason); "
                + "redrawing it needs Accessibility — drag again")
            return
        }
        let source = CGEventSource(stateID: .hidSystemState)
        let pointer = CGEvent(source: nil)?.location
        func post(_ type: CGEventType, at point: CGPoint) {
            guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                      mouseCursorPosition: point, mouseButton: .left) else { return }
            // Explicitly none: a ⇧ or ⌥ still held from the shortcut would
            // change the selection's geometry.
            event.flags = []
            event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
            event.post(tap: .cghidEventTap)
        }
        // The tap's work is done once the overlay is up, and it must be gone
        // before the redraw: a filtering tap on this thread holds each posted
        // event until the thread is free, so a redraw paced with usleep would
        // reach screencapture as one burst and be taken for a click.
        removeTap()
        trace("replay start")
        post(.leftMouseDown, at: drag.start)
        usleep(25_000)
        let steps = 10
        for step in 1...steps {
            let progress = CGFloat(step) / CGFloat(steps)
            post(.leftMouseDragged, at: CGPoint(x: drag.start.x + (drag.end.x - drag.start.x) * progress,
                                                y: drag.start.y + (drag.end.y - drag.start.y) * progress))
            usleep(12_000)
        }
        post(.leftMouseUp, at: drag.end)
        if let pointer {
            CGWarpMouseCursorPosition(pointer)
            CGAssociateMouseAndMouseCursorPosition(1)
        }
        log("capture: redrew a selection screencapture missed because \(drag.reason)")
    }
}

private func regionCaptureTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                      refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if let refcon,
       Unmanaged<RegionCaptureSession>.fromOpaque(refcon).takeUnretainedValue()
        .observe(type: type, event: event) {
        return nil
    }
    return Unmanaged.passUnretained(event)
}

/// Creates the screenshot folder if needed, proves it is writable and returns
/// the next free macOS-style file name in it — or nil, having said why.
///
/// The write probe surfaces the Files & Folders prompt (iCloud Drive, Desktop)
/// before the capture UI, and unmasks a denied grant that would otherwise look
/// exactly like an Esc-cancelled capture.
func prepareScreenshotPath(in directory: String, now: Date = Date()) -> String? {
    try? fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
    let probe = directory + "/.aishot-write-test"
    guard fm.createFile(atPath: probe, contents: Data()) else {
        log("ERROR: cannot write to \(directory) — allow AIShot under System Settings → "
            + "Privacy & Security → Files and Folders")
        return nil
    }
    try? fm.removeItem(atPath: probe)

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd 'at' h.mm.ss a"
    let stamp = formatter.string(from: now)
    var path = "\(directory)/Screenshot \(stamp).png"
    var serial = 2
    while fm.fileExists(atPath: path) {
        path = "\(directory)/Screenshot \(stamp) (\(serial)).png"
        serial += 1
    }
    return path
}
