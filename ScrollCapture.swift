// AIShot — scrolling capture.
//
// Everything a browser extension gets for free, a screen-space capture has to
// infer. Inside a page you can ask for scrollHeight and scroll to an exact
// offset; from outside you can only push scroll events at a window and look at
// what came back. So the engine here is built around that asymmetry:
//
//   pick a window → raise it → scroll to the top → repeatedly
//   [ shoot a frame → push a scroll event → wait for it to settle ]
//   → find how far each frame actually moved by matching pixels
//   → drop the bands that never moved (sticky headers/footers)
//   → concatenate what is left
//
// The scroll distance is never trusted: macOS applies its own acceleration and
// every app decides for itself how far a wheel event travels. Overlap detection
// is what makes the seams line up, and it is also the bottom-of-page signal —
// when a frame stops moving, there is nothing below it.
//
// The result is a CGImage. main.swift writes it out and hands it to the same
// save → clipboard → destination pipeline every other capture uses.

import AppKit
import CoreGraphics
import Darwin
import ImageIO
import ScreenCaptureKit
import UserNotifications
import Vision

// MARK: - window identity

/// The accessibility API exposes no window ID in its public surface, which
/// leaves matching an AX window to a CGWindow a guessing game: two browser
/// windows tiled to the same rectangle are identical by position and size, and
/// titles collide too. `_AXUIElementGetWindow` answers it exactly and is the
/// long-standing way every window manager on this platform does it.
///
/// Resolved through dlsym rather than declared, so a macOS that drops the symbol
/// costs us the exact match and falls back to attribute matching instead of
/// failing to launch.
private typealias AXGetWindowFunction =
    @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

private let axGetWindowID: AXGetWindowFunction? = {
    // RTLD_DEFAULT — search every loaded image, since the symbol lives in the
    // already-linked HIServices framework.
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow")
    else { return nil }
    return unsafeBitCast(symbol, to: AXGetWindowFunction.self)
}()

func windowID(of element: AXUIElement) -> CGWindowID? {
    guard let axGetWindowID else { return nil }
    var id: CGWindowID = 0
    guard axGetWindowID(element, &id) == .success, id != 0 else { return nil }
    return id
}

// MARK: - tuning

enum ScrollTuning {
    /// Fraction of the window height to advance per step. Well under 1.0 so
    /// consecutive frames always share a band to match on — the overlap is what
    /// the seam is computed from, so losing it loses the stitch.
    static let advanceFraction = 0.80

    /// How long to let a scroll settle before shooting. Covers momentum and
    /// smooth-scroll animations; frames are compared for stillness on top of
    /// this, so a slow app costs time rather than correctness.
    static let settleSeconds = 0.28
    static let maxSettleSeconds = 1.6

    /// Safety stop. An infinite-scroll page never reaches the bottom, and a
    /// runaway loop that fills memory with frames is worse than a short capture.
    static let defaultMaxFrames = 60

    /// Columns sampled per row when hashing a frame. Comparing every pixel is
    /// wasted work — a few dozen columns identify a row just as well and keep a
    /// 60-frame match under a second.
    static let sampleColumns = 64

    /// Rows may differ this much per sampled channel and still count as equal.
    /// Subpixel antialiasing and font smoothing shift by a few levels between
    /// frames even when the content is identical.
    static let rowTolerance = 12

    /// A row must match this fraction of its sampled columns to count as equal.
    static let rowMatchRatio = 0.94

    /// Fraction of probed samples that must line up for an offset to be accepted
    /// as the seam. Short of 1.0 on purpose: an animating element, a lazily
    /// loaded image or a blinking cursor inside the overlap should cost an
    /// offset a few samples, not disqualify it.
    static let offsetAcceptScore = 0.80

    /// How far the winning offset must stand above the median offset's score.
    /// The absolute floor alone is not enough — on a page where most of the
    /// frame holds still, *every* offset scores high and the "best" one is
    /// noise. Requiring a margin is what distinguishes a real seam from a tie.
    static let offsetAcceptMargin = 0.10

    /// A column matching more than this fraction of its rows across a scroll is
    /// treated as stationary and dropped from scoring.
    static let stationaryColumnRatio = 0.9
}

enum ScrollCaptureError: Error {
    case cancelled
    case noWindowPicked
    case windowUnavailable
    case captureFailed(String)
    /// The window did not move for the first scroll event. Nothing here can be
    /// worked around: either the surface is not scrollable or it ignores
    /// synthetic wheel events.
    case didNotScroll
}

struct ScrollCaptureOutcome {
    let image: CGImage
    let frameCount: Int
    /// Set when the capture is complete but imperfect — hit the frame cap,
    /// seams estimated rather than matched. Surfaced to the user, not fatal.
    let warning: String?
}

// MARK: - geometry

/// CGWindowList and ScreenCaptureKit speak top-left-origin display coordinates;
/// AppKit windows speak bottom-left-origin. Flipping needs the *primary*
/// screen's height — the one whose origin is (0, 0) — not the screen the window
/// happens to be on.
func displayRectToAppKit(_ rect: CGRect) -> NSRect {
    guard let primary = NSScreen.screens.first else { return rect }
    let flippedY = primary.frame.maxY - rect.origin.y - rect.height
    return NSRect(x: rect.origin.x, y: flippedY, width: rect.width, height: rect.height)
}

// MARK: - window enumeration

struct CandidateWindow {
    let id: CGWindowID
    let displayBounds: CGRect // top-left origin
    let ownerPID: pid_t
    let ownerName: String
    let title: String

    var label: String {
        title.isEmpty ? ownerName : "\(ownerName) — \(title)"
    }
}

/// On-screen, user-facing windows in front-to-back order.
///
/// Layer 0 is the ordinary document/window layer; everything else is the menu
/// bar, the Dock, wallpaper, notification banners and our own overlay. Tiny
/// windows are dropped because every app keeps invisible 1×1 helpers around and
/// they sit in front of the real thing in hit-testing order.
func onScreenWindows(excluding pid: pid_t) -> [CandidateWindow] {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
        return []
    }

    var result: [CandidateWindow] = []
    for entry in raw {
        guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
              let ownerPID = entry[kCGWindowOwnerPID as String] as? pid_t, ownerPID != pid,
              let windowID = entry[kCGWindowNumber as String] as? CGWindowID,
              let boundsDict = entry[kCGWindowBounds as String] as? [String: Any],
              let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
              bounds.width >= 120, bounds.height >= 120
        else { continue }

        result.append(CandidateWindow(
            id: windowID,
            displayBounds: bounds,
            ownerPID: ownerPID,
            ownerName: (entry[kCGWindowOwnerName as String] as? String) ?? "",
            title: (entry[kCGWindowName as String] as? String) ?? ""))
    }
    return result
}

// MARK: - window picker overlay

/// Full-screen click-through-free overlay that highlights whatever window is
/// under the cursor and returns it on click.
///
/// This runs its own event loop rather than NSApp.run(): a capture worker is a
/// short-lived process with no delegate and nothing else to service, and
/// pumping events by hand keeps "picked / cancelled" a plain return value
/// instead of state smuggled out of a callback.
/// Reads the picker's input straight from the event stream, bypassing AppKit
/// delivery entirely.
///
/// The overlay cannot rely on ordinary event routing, because it never gets to
/// be the active app. AIShot is LSUIElement and the hotkey launches it in the
/// background; macOS 14's cooperative activation then refuses it the foreground
/// however it asks — regular activation policy, `finishLaunching()` and
/// `activate(ignoringOtherApps:)` were all tried and the app in front stayed in
/// front. That breaks both halves of the picker:
///
///   - keystrokes go to the active app, so Esc never arrived and the picker
///     could not be cancelled;
///   - the first click on an inactive app's window is spent activating it and
///     is swallowed, and with activation refused *every* click is a first
///     click — so no click ever selected anything and the highlight appeared
///     stuck on one window.
///
/// A tap sees both regardless of who is active, and consumes them so the app
/// underneath does not also act on the click that picked it.
final class PickerInput {
    /// Shared with the C callback, which cannot capture context.
    final class State {
        var cancelled = false
        /// Display coordinates, top-left origin — the same space window bounds
        /// come back in, so the hit test needs no conversion.
        var clickedAt: CGPoint?
    }

    private let state = State()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    var cancelled: Bool { state.cancelled }
    var clickedAt: CGPoint? { state.clickedAt }

    /// Drops a click that landed on nothing, so it is not re-examined forever.
    func clearClick() { state.clickedAt = nil }

    init?() {
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let state = Unmanaged<State>.fromOpaque(context).takeUnretainedValue()
            switch type {
            case .keyDown where event.getIntegerValueField(.keyboardEventKeycode) == 53:
                state.cancelled = true
                return nil
            case .rightMouseDown:
                state.cancelled = true
                return nil
            case .leftMouseDown:
                state.clickedAt = event.location
                return nil
            default:
                // Includes the disabled-by-timeout notifications, which carry no
                // useful payload here — pass everything else straight through.
                return Unmanaged.passUnretained(event)
            }
        }

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.rightMouseDown.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(state).toOpaque())
        else { return nil }

        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes) }
        tap = nil
        source = nil
    }
}

final class WindowPicker {
    /// One overlay per display, not one window stretched across all of them.
    /// A single window spanning several screens does not render at all when
    /// "Displays have separate Spaces" is on — it reports `isVisible == true`
    /// and shows nothing, leaving an invisible picker that still swallows the
    /// next click.
    private struct Pane {
        let window: OverlayWindow
        let view: HighlightView
        let screen: NSScreen
    }

    private var panes: [Pane] = []
    private var candidates: [CandidateWindow]

    /// A borderless window refuses key status by default, and AppKit routes
    /// `keyDown` and `mouseMoved` only to the key window. Without this override
    /// the picker looks broken in exactly two ways: Esc does nothing, and the
    /// highlight freezes wherever the pointer happened to be when the overlay
    /// appeared — so every click seems to pick the same window.
    private final class OverlayWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }

    private final class HighlightView: NSView {
        var focus: NSRect?
        var caption: String = ""

        override var isFlipped: Bool { false }

        /// Where the instruction banner goes — the screen holding the pointer,
        /// in this view's coordinates.
        var bannerCenter: NSPoint?

        override func draw(_ dirtyRect: NSRect) {
            // Dark enough to be unmistakable. A subtle wash reads as a rendering
            // glitch, and a picker nobody notices is worse than no picker: it
            // swallows the next click anywhere on screen and captures whatever
            // was under it, which looks like the app acting on its own.
            NSColor.black.withAlphaComponent(0.35).setFill()
            bounds.fill()

            guard let focus else { return }
            // Punch the target out of the dimming so the window reads normally,
            // then outline it. A dimmed target is hard to identify when several
            // windows of the same app overlap.
            NSColor.clear.setFill()
            focus.fill(using: .copy)

            NSColor.controlAccentColor.setStroke()
            let border = NSBezierPath(rect: focus.insetBy(dx: 1, dy: 1))
            border.lineWidth = 3
            border.stroke()

            guard !caption.isEmpty else { return }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor.white,
            ]
            let size = caption.size(withAttributes: attributes)
            let padding: CGFloat = 8
            var box = NSRect(x: focus.minX, y: focus.maxY + 6,
                             width: size.width + padding * 2, height: size.height + padding)
            if box.maxY > bounds.maxY { box.origin.y = focus.maxY - box.height - 6 }
            if box.maxX > bounds.maxX { box.origin.x = bounds.maxX - box.width }
            box.origin.x = max(bounds.minX, box.origin.x)

            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
            caption.draw(at: NSPoint(x: box.minX + padding, y: box.minY + padding / 2),
                         withAttributes: attributes)
        }

        /// States what the overlay is waiting for. Without it the dimmed screen
        /// is a mystery, and the user has no way to know a click is about to be
        /// interpreted rather than delivered to the app underneath.
        ///
        /// A real subview rather than something drawn in `draw(_:)`: custom
        /// drawing in this overlay reached the backing store but never the
        /// screen — the draw calls ran, with correct coordinates, and nothing
        /// appeared. Subviews composite through the ordinary AppKit path and do
        /// show up.
        func installBanner(at center: NSPoint) {
            bannerCenter = center
            let message = t("스크롤 캡처할 창을 클릭하세요        Esc · 우클릭 취소",
                            "Click the window to capture in full        Esc or right-click to cancel")
            let label = NSTextField(labelWithString: message)
            label.font = .systemFont(ofSize: 17, weight: .medium)
            label.textColor = .white
            label.alignment = .center
            label.sizeToFit()

            let box = NSView(frame: NSRect(x: center.x - label.frame.width / 2 - 24,
                                           y: center.y - label.frame.height / 2 - 14,
                                           width: label.frame.width + 48,
                                           height: label.frame.height + 28))
            box.wantsLayer = true
            box.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.8).cgColor
            box.layer?.cornerRadius = 14
            label.frame = NSRect(x: 24, y: 14, width: label.frame.width, height: label.frame.height)
            box.addSubview(label)
            addSubview(box)
        }
    }

    init() {
        candidates = []
        for screen in NSScreen.screens {
            let window = OverlayWindow(contentRect: screen.frame, styleMask: .borderless,
                                       backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.level = .screenSaver
            window.ignoresMouseEvents = true // input comes from the event tap
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            let view = HighlightView(frame: NSRect(origin: .zero, size: screen.frame.size))
            window.contentView = view
            panes.append(Pane(window: window, view: view, screen: screen))
        }
    }

    /// Blocks until the user clicks a window, cancels, or `timeout` elapses.
    ///
    /// The timeout is a safety valve, not a convenience. While the picker is up
    /// its event tap swallows clicks everywhere on screen, so a picker that
    /// outlives the user's attention turns their next ordinary click into a
    /// capture of whatever happened to be under it.
    func run(timeout: TimeInterval = 60) -> CandidateWindow? {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        // A capture worker never runs NSApplicationMain, so AppKit is only
        // half-initialized until this is called.
        app.finishLaunching()
        // Deliberately not activating. macOS refuses the foreground to an
        // LSUIElement app launched in the background — regular activation
        // policy, `activate()` and `activate(ignoringOtherApps:)` were all
        // tried and the app in front stayed in front. Input comes from the
        // event tap instead, which does not care who is active.

        // Enumerate before the overlay is on screen. Our own window is filtered
        // by PID anyway, but a snapshot taken now also cannot pick up whatever
        // the act of activating shuffles to the front.
        candidates = onScreenWindows(excluding: getpid())
        guard !candidates.isEmpty else { return nil }

        // `orderFrontRegardless`, not `makeKeyAndOrderFront`: the latter shows
        // nothing at all for an app that is not active, and this app cannot
        // become active. That left the picker completely invisible while its
        // event tap still swallowed the next click anywhere on screen — the
        // capture then looked like it fired on its own, on a window the user
        // never chose.
        // An ordered-front window is not necessarily a drawn one: nothing has
        // marked the view dirty yet, and a worker process that never entered a
        // normal run loop will not get around to it on its own.
        for pane in panes {
            pane.window.orderFrontRegardless()
            pane.view.needsDisplay = true
            pane.window.displayIfNeeded()
        }
        log("picker: \(panes.count) overlay(s), \(candidates.count) candidate window(s)")
        NSCursor.crosshair.push()
        let input = PickerInput()
        if input == nil {
            log("scrolling capture: could not read input — check Accessibility for AIShot")
        }
        defer {
            input?.stop()
            NSCursor.pop()
            for pane in panes { pane.window.orderOut(nil) }
        }

        // On every display, not just the pointer's. The banner is the only thing
        // telling the user that a click is about to be interpreted rather than
        // delivered, and on a multi-display desk they may well be looking at a
        // different screen than the one the pointer was left on.
        for pane in panes {
            pane.view.installBanner(at: NSPoint(x: pane.screen.frame.width / 2,
                                                y: pane.screen.frame.height - 120))
        }
        updateFocus(at: NSEvent.mouseLocation)

        let giveUpAt = Date(timeIntervalSinceNow: timeout)
        let escapeKey: UInt16 = 53
        while true {
            if Date() > giveUpAt {
                log("scrolling capture: nothing picked within \(Int(timeout))s — closing the picker")
                return nil
            }
            // Drain whatever has arrived, then fall through to the poll. The
            // highlight is driven by polling the pointer rather than by
            // mouseMoved delivery, so it keeps tracking even if something takes
            // key status from the overlay mid-pick — which otherwise looks
            // exactly like the picker having frozen on one window.
            //
            // Cancellation is left to real events. Polling the hardware key
            // state for Esc looked like a free safety net and was not: it read
            // as pressed on a keyboard nobody was touching, so the picker
            // cancelled itself the moment it opened.
            let deadline = Date(timeIntervalSinceNow: 0.02)
            while let event = app.nextEvent(matching: [.leftMouseDown, .rightMouseDown,
                                                       .keyDown, .mouseMoved,
                                                       .leftMouseDragged],
                                            until: deadline,
                                            inMode: .default, dequeue: true) {
                switch event.type {
                case .leftMouseDown:
                    // A click on bare desktop selects nothing; ignore it rather
                    // than treating it as a cancel, which would throw the pick
                    // away on a misplaced click.
                    if let hit = window(at: NSEvent.mouseLocation) { return hit }
                case .rightMouseDown:
                    return nil
                case .keyDown where event.keyCode == escapeKey:
                    return nil
                default:
                    break
                }
            }

            if input?.cancelled == true { return nil }
            if let point = input?.clickedAt {
                // Hit-tested in display coordinates, the space the click and the
                // window bounds already share. A click on bare desktop selects
                // nothing and is ignored rather than cancelling the pick.
                if let hit = candidates.first(where: { $0.displayBounds.contains(point) }) {
                    return hit
                }
                input?.clearClick()
            }
            updateFocus(at: NSEvent.mouseLocation)
        }
    }

    /// Front-to-back order is the same order CGWindowList returned, so the first
    /// hit is the one the user sees and would click.
    private func window(at point: NSPoint) -> CandidateWindow? {
        candidates.first { displayRectToAppKit($0.displayBounds).contains(point) }
    }

    private func updateFocus(at point: NSPoint) {
        let hit = window(at: point)
        let rect = hit.map { displayRectToAppKit($0.displayBounds) }
        let caption = hit?.label ?? ""

        // Every pane draws the same window, each in its own screen's
        // coordinates, so a window straddling two displays is outlined across
        // both instead of being cut off at the seam.
        for pane in panes {
            let local = rect.map {
                $0.offsetBy(dx: -pane.screen.frame.minX, dy: -pane.screen.frame.minY)
            }
            guard local != pane.view.focus || caption != pane.view.caption else { continue }
            pane.view.focus = local
            pane.view.caption = caption
            pane.view.needsDisplay = true
            pane.window.displayIfNeeded()
        }
    }
}

// MARK: - screen capture

/// Carries a completion handler's result back to the waiting caller. Swift
/// cannot prove the semaphore orders the write against the read, so the promise
/// is made explicitly here rather than silenced at each call site.
private final class Box<T>: @unchecked Sendable {
    var value: T?
}

/// Drives a callback-style ScreenCaptureKit call from synchronous code.
///
/// The run loop is pumped while waiting instead of blocking outright:
/// ScreenCaptureKit delivers its replies through the main run loop, so a bare
/// semaphore wait on the main thread deadlocks against the very callback it is
/// waiting for.
private func awaitCallback<T>(timeout: TimeInterval,
                              _ start: (Box<T>, DispatchSemaphore) -> Void) -> T? {
    let box = Box<T>()
    let semaphore = DispatchSemaphore(value: 0)
    start(box, semaphore)

    let deadline = Date(timeIntervalSinceNow: timeout)
    while semaphore.wait(timeout: .now() + 0.005) == .timedOut {
        if Date() > deadline { return nil }
        RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005))
    }
    return box.value
}

/// Repeated captures of one window. Resolving the SCWindow is the expensive
/// part, so it is done once and the handle reused for every frame.
final class WindowShooter {
    private let scWindow: SCWindow
    private let configuration: SCStreamConfiguration

    init?(windowID: CGWindowID) {
        let content = awaitCallback(timeout: 5.0) { (box: Box<SCShareableContent>, semaphore) in
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, _ in
                box.value = content
                semaphore.signal()
            }
        }
        guard let match = content?.windows.first(where: { $0.windowID == windowID }) else { return nil }
        scWindow = match

        configuration = SCStreamConfiguration()
        configuration.showsCursor = false
        configuration.captureResolution = .best
        // Capture at backing-store resolution: the stitched result should be as
        // sharp as the screen, and downscaling later is lossless-ish while
        // upscaling is not.
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        configuration.width = Int(match.frame.width * scale)
        configuration.height = Int(match.frame.height * scale)
    }

    var title: String { scWindow.title ?? "" }
    var owningPID: pid_t { scWindow.owningApplication?.processID ?? 0 }
    var frame: CGRect { scWindow.frame }

    func shoot() -> CGImage? {
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let config = configuration
        return awaitCallback(timeout: 4.0) { (box: Box<CGImage>, semaphore) in
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { image, _ in
                box.value = image
                semaphore.signal()
            }
        }
    }
}

// MARK: - frame signatures

/// A frame reduced to one hash per row, plus the sampled bytes those hashes came
/// from. Matching two frames is then a comparison of short integer arrays rather
/// than of megapixels, and the retained samples let near-misses be scored
/// tolerantly instead of exact-matched.
struct FrameSignature {
    let width: Int
    let height: Int
    let columns: Int
    /// Row-major, `columns` luminance bytes per row.
    let samples: [UInt8]

    func rowsMatch(_ selfRow: Int, _ other: FrameSignature, _ otherRow: Int) -> Bool {
        guard columns == other.columns else { return false }
        let a = selfRow * columns
        let b = otherRow * columns
        var hits = 0
        for i in 0 ..< columns {
            let delta = Int(samples[a + i]) - Int(other.samples[b + i])
            if abs(delta) <= ScrollTuning.rowTolerance { hits += 1 }
        }
        return Double(hits) >= Double(columns) * ScrollTuning.rowMatchRatio
    }

    /// Rows that differ when the two frames are compared in place. Zero means
    /// nothing moved at all — the difference between "did not scroll" and
    /// "scrolled, but the seam matcher failed", which is the first thing worth
    /// knowing when a capture stops after one frame.
    func differingRows(against other: FrameSignature) -> Int {
        guard columns == other.columns, height == other.height else { return height }
        var count = 0
        for y in 0 ..< height where !rowsMatch(y, other, y) { count += 1 }
        return count
    }
}

func frameSignature(of image: CGImage) -> FrameSignature? {
    let width = image.width
    let height = image.height
    guard width > 0, height > 0 else { return nil }

    // Redraw into a known 8-bit grayscale layout. CGImage can arrive in any of a
    // dozen pixel formats, and normalizing once here means the matcher never has
    // to care which one ScreenCaptureKit chose.
    var gray = [UInt8](repeating: 0, count: width * height)
    let ok: Bool = gray.withUnsafeMutableBytes { buffer -> Bool in
        guard let context = CGContext(data: buffer.baseAddress,
                                      width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    guard ok else { return nil }

    let columns = min(ScrollTuning.sampleColumns, width)
    var samples = [UInt8](repeating: 0, count: columns * height)
    // Sample at the centre of `columns` equal slices rather than at the left
    // edge: a centred sample sits inside content instead of on the page margin,
    // where every row looks identical and matching degenerates.
    var offsets = [Int](repeating: 0, count: columns)
    for c in 0 ..< columns {
        offsets[c] = min(width - 1, (c * width) / columns + width / (columns * 2))
    }
    for y in 0 ..< height {
        let rowStart = y * width
        let outStart = y * columns
        for c in 0 ..< columns {
            samples[outStart + c] = gray[rowStart + offsets[c]]
        }
    }

    return FrameSignature(width: width, height: height, columns: columns, samples: samples)
}

// MARK: - overlap detection

/// How far `next` scrolled past `previous`, in pixels, or nil if no offset lines
/// the two up.
///
/// Only rows inside `band` are compared, and that restriction is load-bearing.
/// A sticky header or floating footer holds the same screen position in both
/// frames, so it matches *no* scroll offset; leaving it in the comparison makes
/// every candidate fail, which is indistinguishable from a window that never
/// scrolled at all. That was the difference between this working and reporting
/// "did not scroll" on any page with a sticky bar — which is most of them.
///
/// Every offset is scored rather than accepting the first that clears the bar.
/// Repeated content — tables, lists, whitespace — lines up at many offsets, and
/// the best-scoring one keeps the seam continuous; ties resolve to the smallest,
/// which is the one that cannot have skipped content.
func verticalAdvance(from previous: FrameSignature, to next: FrameSignature,
                     band: Range<Int>, minimum: Int, maximum: Int) -> Int? {
    guard previous.columns == next.columns, previous.height == next.height else { return nil }
    let height = previous.height
    let lowerBound = max(1, minimum)
    let upperBound = min(maximum, height - 1)
    guard lowerBound <= upperBound, band.lowerBound < band.upperBound else { return nil }

    let columns = previous.columns

    // Columns that hold still across the scroll — a sticky sidebar, a fixed
    // margin, window chrome. They match at *every* offset, so leaving them in
    // raises the floor until the true seam stops standing out: on a Wikipedia
    // page 40 of 64 sampled columns are stationary, and with those included a
    // deliberately wrong offset outscored the acceptance bar while the correct
    // one cleared it by only 0.09. Dropping them takes that separation to 0.25.
    var moving: [Int] = []
    for column in 0 ..< columns {
        var same = 0
        var total = 0
        var y = band.lowerBound
        while y < band.upperBound {
            total += 1
            let delta = Int(previous.samples[y * columns + column])
                - Int(next.samples[y * columns + column])
            if abs(delta) <= ScrollTuning.rowTolerance { same += 1 }
            y += 4
        }
        if total > 0, Double(same) / Double(total) <= ScrollTuning.stationaryColumnRatio {
            moving.append(column)
        }
    }
    // Everything held still. There is nothing to discriminate on, so score over
    // the lot and let the acceptance test throw it out.
    let scoring = moving.count >= 4 ? moving : Array(0 ..< columns)

    // A fixed probe budget keeps the cost flat regardless of window height, and
    // spreading probes across the whole overlap catches a mismatch that a
    // contiguous run at one end would miss.
    let probeBudget = 32
    var scores: [Double] = []
    var bestAdvance: Int?
    var bestScore = 0.0

    for advance in lowerBound ... upperBound {
        // Both the row read from `next` and its source row in `previous` have to
        // sit inside the band, which is what bounds the scan.
        let start = band.lowerBound
        let end = band.upperBound - advance
        guard end - start >= 60 else { break }
        let step = max(1, (end - start) / probeBudget)

        // Scored per sample rather than per row. A row is only "equal" if nearly
        // all of its columns agree, so a sticky sidebar — which freezes part of
        // every row — fails every row and sinks the true offset along with the
        // false ones. Counting samples lets the moving part of each row speak.
        var hits = 0
        var total = 0
        var y = start
        while y < end {
            let previousRow = (advance + y) * columns
            let nextRow = y * columns
            for column in scoring {
                total += 1
                let delta = Int(previous.samples[previousRow + column])
                    - Int(next.samples[nextRow + column])
                if abs(delta) <= ScrollTuning.rowTolerance { hits += 1 }
            }
            y += step
        }
        guard total > 0 else { continue }

        let score = Double(hits) / Double(total)
        scores.append(score)
        if score > bestScore + 0.0001 {
            bestScore = score
            bestAdvance = advance
        }
    }

    guard let advance = bestAdvance, !scores.isEmpty else { return nil }
    // Two tests, because either alone is fooled. The floor rejects a frame whose
    // content changed wholesale; the margin over the median rejects the
    // degenerate case where everything matches everything.
    let median = scores.sorted()[scores.count / 2]
    guard bestScore >= ScrollTuning.offsetAcceptScore,
          bestScore - median >= ScrollTuning.offsetAcceptMargin
    else { return nil }
    return advance
}

/// Rows at the top and bottom that are identical *in place* across a scroll —
/// the signature of a sticky header, toolbar or floating footer.
///
/// Whitespace at the edge of the content also matches in place and gets counted
/// as sticky. That is harmless: the band is only ever excluded from matching or
/// cropped from the result, and cropping blank rows costs nothing.
func stickyBandsBetween(_ a: FrameSignature, _ b: FrameSignature) -> (top: Int, bottom: Int) {
    guard a.height == b.height, a.columns == b.columns else { return (0, 0) }
    let height = a.height
    // Past a third of the window this is far more likely to be a page that
    // barely moved than a genuinely enormous toolbar.
    let limit = height / 3

    var top = 0
    while top < limit, a.rowsMatch(top, b, top) { top += 1 }

    var bottom = 0
    while bottom < limit, a.rowsMatch(height - 1 - bottom, b, height - 1 - bottom) { bottom += 1 }

    return (top, bottom)
}

/// Rows at the top and bottom that never move — sticky headers, toolbars, and
/// floating footers. They are identical in every frame, so leaving them in would
/// repeat them down the stitched image at every seam.
///
/// Measured across all frames rather than the first pair: a bar that appears
/// only after the first scroll (the "shrink on scroll" header) is still constant
/// from frame 1 onward, and taking the intersection catches it.
func stickyBands(_ frames: [FrameSignature]) -> (top: Int, bottom: Int) {
    guard frames.count >= 3 else { return (0, 0) }
    let height = frames[0].height
    // Never let the bands eat the whole window; past a third of the height this
    // is far more likely to be a detection failure than a real toolbar.
    let limit = height / 3

    var top = 0
    while top < limit {
        var constant = true
        for i in 1 ..< frames.count where !frames[i].rowsMatch(top, frames[i - 1], top) {
            constant = false
            break
        }
        if !constant { break }
        top += 1
    }

    var bottom = 0
    while bottom < limit {
        let row = height - 1 - bottom
        var constant = true
        for i in 1 ..< frames.count where !frames[i].rowsMatch(row, frames[i - 1], row) {
            constant = false
            break
        }
        if !constant { break }
        bottom += 1
    }

    return (top, bottom)
}

// MARK: - scrolling

/// Pushes wheel events at a point inside the window. Negative scrolls down.
///
/// Line units, in small bursts, rather than one large pixel-unit event. A
/// pixel-unit event is the trackpad shape, and a trackpad also sends a gesture
/// phase (began / changed / ended); WebKit and several AppKit scroll views drop
/// phase-less continuous events on the floor, which looks exactly like "this
/// window does not scroll". Classic notched line events carry no phase by
/// definition and are handled by every scrollable surface.
///
/// Posted to the HID tap because that is where a real device's events enter —
/// a session-tap event never reaches a browser compositor.
func postScroll(lines: Int, at point: CGPoint, perEvent: Int = 3, pace: TimeInterval = 0.008) {
    guard lines != 0 else { return }
    let sign: Int32 = lines < 0 ? -1 : 1
    var remaining = abs(lines)
    while remaining > 0 {
        let chunk = Int32(min(perEvent, remaining)) * sign
        if let event = CGEvent(scrollWheelEvent2Source: nil, units: .line,
                               wheelCount: 1, wheel1: chunk, wheel2: 0, wheel3: 0) {
            event.location = point
            event.post(tap: .cghidEventTap)
        }
        remaining -= perEvent
        // Spaced out so a view animating a smooth scroll coalesces the burst
        // instead of servicing only the last event in it.
        Thread.sleep(forTimeInterval: pace)
    }
}

/// Drives the window back to the top, returning the frame that shows it.
///
/// A "full page" capture that begins wherever the user last left the scroll
/// position is not a full page. It also removes an ambiguity that has no good
/// resolution later: a window already scrolled to the bottom yields one frame
/// and no movement, which is indistinguishable from a window that cannot scroll
/// at all — and reporting the second when it was the first is a lie.
///
/// Coarser and faster than the capture loop: nothing here is being photographed,
/// so the bursts are large and barely paced.
func scrollToTop(shooter: WindowShooter, at point: CGPoint,
                 limit: Int = 40) -> (image: CGImage, signature: FrameSignature)? {
    guard var image = shooter.shoot(), var signature = frameSignature(of: image) else { return nil }
    for _ in 0 ..< limit {
        postScroll(lines: 100, at: point, perEvent: 10, pace: 0.004)
        Thread.sleep(forTimeInterval: 0.12)
        guard let shot = shooter.shoot(), let next = frameSignature(of: shot) else { break }
        let moved = next.differingRows(against: signature)
        image = shot
        signature = next
        if moved == 0 { break }
    }
    return (image, signature)
}

/// Brings the picked window forward so wheel events land on it.
/// Returns false when the exact window could not be identified.
///
/// Activating the app is not enough: it raises whichever window the app
/// considers frontmost, which may not be the one that was picked. AXRaise
/// targets a specific window — but the accessibility API exposes no window ID,
/// so the picked window has to be re-identified by its attributes.
///
/// Geometry alone is not enough either, and that failure is not rare: two
/// browser windows tiled to the same rectangle are identical by position and
/// size, so matching on geometry raises whichever came first and the scroll
/// lands on a window we are not photographing. The captured window then never
/// moves, which is reported as "this window does not scroll" — a wrong answer to
/// a common setup. Title is the discriminator, geometry the tiebreak.
@discardableResult
func raiseWindow(_ candidate: CandidateWindow, trace: (String) -> Void = { _ in }) -> Bool {
    if let app = NSRunningApplication(processIdentifier: candidate.ownerPID) {
        app.activate(options: [])
    }

    let axApp = AXUIElementCreateApplication(candidate.ownerPID)
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
          let windows = value as? [AXUIElement] else {
        trace("raise: the app exposes no accessibility window list")
        return false
    }

    var bestScore = 0
    var bestWindow: AXUIElement?

    for axWindow in windows {
        var score = 0

        // An exact window-ID match ends the search — nothing else can be more
        // certain, and the attribute heuristics below exist only for the case
        // where the ID is unavailable.
        if let id = windowID(of: axWindow) {
            if id == candidate.id {
                bestScore = 100
                bestWindow = axWindow
                break
            }
            // The ID was readable and did not match, so this is definitively a
            // different window; scoring it on title or size could only mislead.
            continue
        }

        if !candidate.title.isEmpty,
           axString(axWindow, attribute: kAXTitleAttribute as CFString) == candidate.title {
            score += 2
        }

        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &positionValue) == .success,
           AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeValue) == .success,
           let positionValue, let sizeValue {
            var origin = CGPoint.zero
            var size = CGSize.zero
            AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin)
            AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
            if abs(origin.x - candidate.displayBounds.origin.x) < 2,
               abs(origin.y - candidate.displayBounds.origin.y) < 2,
               abs(size.width - candidate.displayBounds.width) < 2,
               abs(size.height - candidate.displayBounds.height) < 2 {
                score += 1
            }
        }

        if score > bestScore {
            bestScore = score
            bestWindow = axWindow
        }
    }

    guard let bestWindow else {
        trace("raise: no accessibility window matched [\(candidate.id)] \(candidate.label)")
        return false
    }
    trace("raise: matched by \(bestScore == 100 ? "window ID" : "attributes (score \(bestScore))")")
    // Raising restacks the window; making it main and focused is what gives it
    // key status. Chrome routes input by key window, so a raise on its own
    // leaves scroll events going to whichever sibling window held the focus.
    AXUIElementSetAttributeValue(bestWindow, kAXMainAttribute as CFString, kCFBooleanTrue)
    AXUIElementSetAttributeValue(bestWindow, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    AXUIElementPerformAction(bestWindow, kAXRaiseAction as CFString)
    // Raising is asynchronous — the compositor has to restack before a wheel
    // event posted at that point reaches the newly front window.
    Thread.sleep(forTimeInterval: 0.2)
    return true
}

// MARK: - stitching

/// Concatenates frames using the measured advances, cropping the sticky bands.
///
/// The first frame is kept whole — its header is the real one, seen before
/// anything scrolled — and later frames contribute only their newly revealed
/// band.
func stitch(frames: [CGImage], advances: [Int], sticky: (top: Int, bottom: Int)) -> CGImage? {
    guard let first = frames.first else { return nil }
    let width = first.width
    let frameHeight = first.height
    let bodyHeight = frameHeight - sticky.top - sticky.bottom
    guard bodyHeight > 0 else { return nil }

    let totalHeight = frameHeight + advances.reduce(0, +)
    guard totalHeight > 0, totalHeight <= 200_000 else { return nil }

    let rgb = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(data: nil, width: width, height: totalHeight,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: rgb,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return nil }

    // CGContext is bottom-up, the capture is top-down: draw each frame at a
    // y that counts down from the top of the canvas.
    var drawnFromTop = 0
    context.draw(first, in: CGRect(x: 0, y: totalHeight - frameHeight,
                                   width: width, height: frameHeight))
    drawnFromTop = frameHeight

    for (index, advance) in advances.enumerated() {
        let frame = frames[index + 1]
        // Only the strip below the previous frame's content is new. Clip to it
        // and draw the whole frame behind that window, which puts the new band
        // exactly where it belongs without slicing the image first.
        let stripTop = drawnFromTop
        let stripHeight = advance
        guard stripHeight > 0 else { continue }

        context.saveGState()
        context.clip(to: CGRect(x: 0, y: totalHeight - stripTop - stripHeight,
                                width: width, height: stripHeight))
        // The frame's own row (frameHeight - advance) has to land at stripTop.
        let frameTop = stripTop - (frameHeight - advance)
        context.draw(frame, in: CGRect(x: 0, y: totalHeight - frameTop - frameHeight,
                                       width: width, height: frameHeight))
        context.restoreGState()
        drawnFromTop += stripHeight
    }

    guard let full = context.makeImage() else { return nil }

    // Sticky bands are removed at the end, from the assembled image: the top bar
    // is kept once (it is genuine content in frame 0) and the floating footer is
    // dropped once, rather than either being handled per frame.
    guard sticky.bottom > 0 else { return full }
    let keepHeight = totalHeight - sticky.bottom
    guard keepHeight > 0 else { return full }
    return full.cropping(to: CGRect(x: 0, y: 0, width: width, height: keepHeight)) ?? full
}

// MARK: - orchestration

/// Captures a window from its current scroll position to the bottom.
///
/// `progress` reports the frame count so a caller can show something during what
/// may be a half-minute operation. `debugDirectory`, when set, writes every raw
/// frame next to a verbose trace — the only practical way to tell a window that
/// ignored the scroll from a seam the matcher could not find.
func runScrollCapture(window candidate: CandidateWindow,
                      maxFrames: Int = ScrollTuning.defaultMaxFrames,
                      debugDirectory: String? = nil,
                      progress: (Int) -> Void = { _ in }) -> Result<ScrollCaptureOutcome, ScrollCaptureError> {
    func trace(_ message: String) {
        guard debugDirectory != nil else { return }
        log("  scroll-debug: \(message)")
    }
    func dump(_ image: CGImage, _ name: String) {
        guard let directory = debugDirectory else { return }
        _ = writePNG(image, to: "\(directory)/\(name).png")
    }

    guard let shooter = WindowShooter(windowID: candidate.id) else {
        return .failure(.windowUnavailable)
    }

    raiseWindow(candidate, trace: trace)
    // The shutter here confirms the click landed and the capture has begun. It
    // matters more than it would for a region shot: this one runs for tens of
    // seconds, and the overlay is already gone.
    playShutter()
    // Let the raise finish compositing. A frame shot mid-animation matches
    // nothing and poisons the very first advance measurement.
    Thread.sleep(forTimeInterval: 0.35)

    let bounds = candidate.displayBounds
    // Aim at the middle of the window: the centre is inside the scrollable
    // content in essentially every layout, whereas an edge lands on a sidebar,
    // a scrollbar or the title bar.
    let aimPoint = CGPoint(x: bounds.midX, y: bounds.midY)

    let previousMouse = CGEvent(source: nil)?.location
    CGWarpMouseCursorPosition(aimPoint)
    // Warping alone leaves the window server's idea of the pointer behind until
    // the association is re-enabled, and a scroll event is delivered by pointer
    // location — so without this the burst lands on whatever was under the old
    // position.
    CGAssociateMouseAndMouseCursorPosition(1)
    defer {
        if let previousMouse {
            CGWarpMouseCursorPosition(previousMouse)
            CGAssociateMouseAndMouseCursorPosition(1)
        }
    }

    let shootStart = Date()
    guard let top = scrollToTop(shooter: shooter, at: aimPoint) else {
        return .failure(.captureFailed("first frame"))
    }
    var currentImage = top.image
    var currentSignature = top.signature
    trace(String(format: "window %.0fx%.0f pt → frame %dx%d px, top+first shot %.0f ms",
                 bounds.width, bounds.height, currentSignature.width, currentSignature.height,
                 Date().timeIntervalSince(shootStart) * 1000))
    trace("aim point \(Int(aimPoint.x)),\(Int(aimPoint.y))")
    // Which window will actually receive the wheel events. Scroll is delivered
    // by pointer location, so if this is not the window being photographed the
    // capture is doomed and this line is the only place that shows why.
    if let topmost = onScreenWindows(excluding: getpid())
        .first(where: { $0.displayBounds.contains(aimPoint) }) {
        trace("topmost window at aim point: [\(topmost.id)] \(topmost.label)"
              + (topmost.id == candidate.id ? "  ← target" : "  ← NOT the target"))
    }
    dump(currentImage, "frame-000")

    // A wheel "line" has no fixed pixel size — it varies by app, by scrolling
    // preferences and by what sits under the pointer. Guessing once and living
    // with it would either crawl or overshoot past the overlap, so the burst
    // size is corrected from the advance each step actually produced.
    var linesPerStep = 12
    // Recomputed from the matchable band once one is known — see the loop.
    var targetAdvance = Int(Double(currentSignature.height) * ScrollTuning.advanceFraction)

    var frames: [CGImage] = [currentImage]
    var signatures: [FrameSignature] = [currentSignature]
    var advances: [Int] = []
    var warning: String?
    var retriedFirstStep = false

    progress(1)

    while frames.count < maxFrames {
        postScroll(lines: -linesPerStep, at: aimPoint)

        // Wait for the scroll to settle: shoot repeatedly and stop once two
        // consecutive shots agree. A fixed sleep is either too short for a
        // smooth-scrolling app or wasted on a snappy one.
        Thread.sleep(forTimeInterval: ScrollTuning.settleSeconds)
        let settleDeadline = Date(timeIntervalSinceNow: ScrollTuning.maxSettleSeconds)
        guard var nextImage = shooter.shoot(), var nextSignature = frameSignature(of: nextImage) else {
            return .failure(.captureFailed("frame \(frames.count + 1)"))
        }
        while Date() < settleDeadline {
            Thread.sleep(forTimeInterval: 0.06)
            guard let shot = shooter.shoot(), let signature = frameSignature(of: shot) else { break }
            let moved = signature.differingRows(against: nextSignature)
            nextImage = shot
            nextSignature = signature
            if moved == 0 { break }
        }

        let movedRows = currentSignature.differingRows(against: nextSignature)
        trace("step \(frames.count): \(linesPerStep) lines → \(movedRows) rows differ")
        dump(nextImage, String(format: "frame-%03d", frames.count))

        // Nothing moved. At the bottom of the page that is the correct signal to
        // stop — but on the very first step it is more often a focus race, with
        // the burst going out before the compositor finished restacking the
        // window we just raised. Re-raise and try once before concluding that
        // the window cannot scroll, because that conclusion is terminal.
        if movedRows == 0 {
            if frames.count == 1, !retriedFirstStep {
                retriedFirstStep = true
                trace("first step moved nothing — re-raising and retrying once")
                raiseWindow(candidate, trace: trace)
                CGWarpMouseCursorPosition(aimPoint)
                CGAssociateMouseAndMouseCursorPosition(1)
                continue
            }
            break
        }

        // Remeasure the sticky bands for this pair rather than once up front: a
        // header that only appears after the first scroll, or a footer that
        // fades in near the bottom, is sticky for some pairs and not others.
        // Over-measuring here is harmless — it costs the matcher a few probes.
        let pairSticky = stickyBandsBetween(currentSignature, nextSignature)
        var bandLow = pairSticky.top
        var bandHigh = nextSignature.height - pairSticky.bottom
        if bandHigh - bandLow < 120 {
            // Almost everything looked stationary. Trusting that would leave no
            // rows to match on, so fall back to comparing the whole frame.
            bandLow = 0
            bandHigh = nextSignature.height
        }
        let matchBand = bandLow ..< bandHigh

        let bandHeight = bandHigh - bandLow

        // The overlap has to survive *inside the band*, not merely inside the
        // frame. A tall sticky header plus a floating footer leaves far less
        // matchable height than the window suggests, and stepping by a fraction
        // of the whole frame then lands past the end of the band with nothing
        // left to line up — the capture stops mid-page. Sizing the next step
        // from the band, at the bottom of this loop, is what prevents that.
        let searchCeiling = min(nextSignature.height - 1, bandHeight - 60)
        var measured = verticalAdvance(from: currentSignature, to: nextSignature,
                                       band: matchBand, minimum: 1, maximum: searchCeiling)
        if measured == nil, bandLow > 0 || bandHigh < nextSignature.height {
            // The band is a guess about what holds still. If the guess was
            // wrong, the whole frame is still worth one try before giving up on
            // the rest of the page.
            trace("step \(frames.count): band \(bandLow)..<\(bandHigh) matched nothing — retrying full frame")
            measured = verticalAdvance(from: currentSignature, to: nextSignature,
                                       band: 0 ..< nextSignature.height,
                                       minimum: 1, maximum: nextSignature.height - 1)
        }
        guard let advance = measured else {
            // The frames differ but no offset lines them up: content changed
            // under us, or the step cleared the entire overlap. Splicing a seam
            // we cannot justify would corrupt the result silently, so stop and
            // keep what is already correct.
            trace("step \(frames.count): no matching offset — stopping")
            warning = "seam-unmatched"
            break
        }
        trace("step \(frames.count): advance \(advance) px (target \(targetAdvance), band \(bandHeight))")
        targetAdvance = max(120, Int(Double(bandHeight) * ScrollTuning.advanceFraction))

        frames.append(nextImage)
        signatures.append(nextSignature)
        advances.append(advance)
        currentImage = nextImage
        currentSignature = nextSignature
        progress(frames.count)

        // Re-calibrate toward the target overlap.
        let corrected = Double(linesPerStep) * Double(targetAdvance) / Double(advance)
        linesPerStep = max(2, min(400, Int(corrected.rounded())))
    }

    if frames.count == 1 {
        return .failure(.didNotScroll)
    }
    if frames.count >= maxFrames {
        warning = "frame-cap"
    }

    let sticky = stickyBands(signatures)
    trace("sticky bands: top \(sticky.top) px, bottom \(sticky.bottom) px")
    guard let stitched = stitch(frames: frames, advances: advances, sticky: sticky) else {
        return .failure(.captureFailed("stitch"))
    }

    return .success(ScrollCaptureOutcome(image: stitched,
                                         frameCount: frames.count,
                                         warning: warning))
}

/// Runs the whole interactive flow. `nil` means the user cancelled.
func pickAndScrollCapture(maxFrames: Int,
                          pickTimeout: TimeInterval = 60,
                          debugDirectory: String? = nil,
                          progress: (Int) -> Void = { _ in })
    -> Result<ScrollCaptureOutcome, ScrollCaptureError>? {
    guard let picked = WindowPicker().run(timeout: pickTimeout) else { return nil }
    return runScrollCapture(window: picked, maxFrames: maxFrames,
                            debugDirectory: debugDirectory, progress: progress)
}

// MARK: - text recognition

/// Reads the text out of a stitched capture with the system OCR.
///
/// This exists because of a hard ceiling on the other side: Claude downscales
/// image input to at most 2576 px on the long edge, so a 50,000-px-tall page
/// arrives with its body text at a fraction of a pixel — the one thing a
/// full-page capture is for is the one thing the model cannot read. The OCR
/// text travels alongside the image and carries the content; the image carries
/// the layout.
///
/// Vision is given the capture in overlapping horizontal tiles, not whole: a
/// 280-megapixel bitmap is past the point where a single request is reliable,
/// and tiling also bounds memory. The overlap guarantees every text line falls
/// completely inside at least one tile; each line is then attributed to exactly
/// one tile by its centre, so the seams neither cut nor duplicate lines.
func recognizeText(in image: CGImage, progress: (Int, Int) -> Void = { _, _ in }) -> String {
    let width = image.width
    let height = image.height
    guard width > 0, height > 0 else { return "" }

    // Tile height is tied to the tile's *aspect ratio*, not to a fixed number of
    // pixels, because that is what Vision actually reacts to. Measured on a
    // 1312-px-wide capture, recognition holds a flat ~2350 characters per 1000
    // px of height up to a height:width ratio of about 2.2, then falls off a
    // cliff: 1194 at 2.29, 266 at 2.44, 34 at 2.50 — the tall tile comes back
    // near-empty rather than partially wrong. A 5120-px-wide capture recognized
    // 3600-px tiles (ratio 0.70) perfectly, so height alone is not the trigger.
    //
    // 1.6 keeps a margin below the cliff; the 3600 cap stays inside the tallest
    // tile actually measured good rather than extrapolating past it.
    let tileHeight = min(3600, max(1200, Int(Double(width) * 1.6)))
    let overlap = 240

    let stride = tileHeight - overlap
    let tileCount = max(1, (height - overlap + stride - 1) / stride)
    var lines: [String] = []

    for tileIndex in 0 ..< tileCount {
        let tileTop = tileIndex * stride
        let thisHeight = min(tileHeight, height - tileTop)
        guard thisHeight > 0 else { break }
        guard let tile = image.cropping(to: CGRect(x: 0, y: tileTop,
                                                   width: width, height: thisHeight))
        else { continue }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ko-KR", "en-US"]
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: tile)
        guard (try? handler.perform([request])) != nil,
              let observations = request.results else { continue }

        // A line belongs to this tile if its centre lies outside the half-overlap
        // margins; the neighbouring tile owns the margins' lines. Every line is
        // shorter than half the overlap, so exactly one tile claims each.
        let acceptFrom = tileIndex == 0 ? 0.0 : Double(overlap) / 2
        let acceptTo = Double(thisHeight)
            - (tileTop + thisHeight >= height ? 0.0 : Double(overlap) / 2)

        // Vision's boxes are normalized, origin bottom-left; captures are
        // reasoned about top-down.
        var accepted: [(y: Double, x: Double, text: String)] = []
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let box = observation.boundingBox
            let centerY = (1.0 - Double(box.midY)) * Double(thisHeight)
            guard centerY >= acceptFrom, centerY < acceptTo else { continue }
            accepted.append((centerY, Double(box.minX), candidate.string))
        }
        // Reading order within the tile: top to bottom, left to right for lines
        // that share a baseline. The tolerance is roughly half a line height.
        accepted.sort {
            abs($0.y - $1.y) > 14 ? $0.y < $1.y : $0.x < $1.x
        }
        lines.append(contentsOf: accepted.map(\.text))
        progress(tileIndex + 1, tileCount)
    }

    return lines.joined(separator: "\n")
}

// MARK: - feedback

/// The shutter macOS plays for its own screenshots.
///
/// A scrolling capture is otherwise completely silent, unlike every other
/// capture in this app — `screencapture(1)` plays this file itself. Borrowing it
/// keeps the two kinds of capture feeling like the same feature.
private let shutterSoundPath =
    "/System/Library/Components/CoreAudio.component/Contents/SharedSupport"
    + "/SystemSounds/system/Screen Capture.aif"

/// Plays a sound and waits for it, because a capture worker exits immediately
/// afterwards and an unfinished NSSound dies with the process.
func playSound(atPath path: String, waitFor seconds: TimeInterval = 0.6) {
    guard FileManager.default.fileExists(atPath: path),
          let sound = NSSound(contentsOfFile: path, byReference: true)
    else { return }
    sound.play()
    let deadline = Date(timeIntervalSinceNow: seconds)
    while sound.isPlaying, Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
    }
}

func playShutter() { playSound(atPath: shutterSoundPath) }

/// The chime for "the long thing you started has finished". Distinct from the
/// shutter so the two ends of a capture are not the same sound.
func playCompletionChime() { playSound(atPath: "/System/Library/Sounds/Glass.aiff") }

/// Asks for notification permission. Called by the resident menu bar host.
///
/// It has to be the host that asks. A capture worker is a short-lived
/// LSUIElement process, and `requestAuthorization` from one answers
/// "Notifications are not allowed for this application" — macOS never registers
/// it as a notification client. The host is long-lived and does get registered,
/// and authorization is per-bundle, so once it has been granted there the
/// workers can post.
func requestNotificationAuthorization() {
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, error in
        if let error {
            log("notifications unavailable: \(error.localizedDescription)")
        } else {
            log("notifications \(granted ? "allowed" : "declined")")
        }
    }
}

/// Posts a banner, but only when permission already exists.
///
/// Deliberately never requests: from a capture worker that request fails and
/// costs seconds of the user's time waiting for the refusal.
func postNotificationIfAllowed(title: String, body: String) {
    let center = UNUserNotificationCenter.current()
    let done = DispatchSemaphore(value: 0)

    center.getNotificationSettings { settings in
        guard settings.authorizationStatus == .authorized else { done.signal(); return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        center.add(request) { _ in done.signal() }
    }

    // Both callbacks answer on the main queue, so block by pumping rather than
    // waiting outright — and never for long, since the HUD is the real signal.
    let deadline = Date(timeIntervalSinceNow: 1.5)
    while done.wait(timeout: .now() + 0.01) == .timedOut {
        if Date() > deadline { return }
        RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
    }
}

/// A brief panel near the top of the screen confirming the capture.
///
/// This, not Notification Center, is the reliable signal: a capture worker
/// cannot post banners (see above), and after a capture that ran for half a
/// minute the user needs to be told *something* happened. Borrowing a corner of
/// the screen needs no permission, no daemon and no registration.
func showHUD(_ message: String, seconds: TimeInterval = 2.2) {
    // The screen under the pointer, which is where the user is looking.
    // `NSScreen.main` is the screen holding the *key window*, and a capture
    // worker has none — on a multi-display Mac it answers with whichever screen
    // it likes and the confirmation appears somewhere nobody is watching.
    let pointer = NSEvent.mouseLocation
    guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) })
        ?? NSScreen.screens.first
    else { return }

    let text = NSTextField(labelWithString: message)
    text.font = .systemFont(ofSize: 15, weight: .medium)
    text.textColor = .white
    text.alignment = .center
    text.sizeToFit()

    let padding = NSSize(width: 32, height: 20)
    let size = NSSize(width: min(screen.frame.width - 80, text.frame.width + padding.width * 2),
                      height: text.frame.height + padding.height * 2)
    // Under the menu bar, horizontally centred — where macOS puts its own
    // transient confirmations, so it reads as system feedback rather than a
    // window that needs attention.
    let origin = NSPoint(x: screen.frame.midX - size.width / 2,
                         y: screen.frame.maxY - size.height - 90)

    let panel = NSWindow(contentRect: NSRect(origin: origin, size: size),
                         styleMask: .borderless, backing: .buffered, defer: false)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.level = .statusBar
    panel.ignoresMouseEvents = true
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

    let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
    background.material = .hudWindow
    background.state = .active
    background.blendingMode = .behindWindow
    background.wantsLayer = true
    background.layer?.cornerRadius = 12
    background.layer?.masksToBounds = true

    text.frame = NSRect(x: padding.width, y: padding.height / 2,
                        width: size.width - padding.width * 2, height: text.frame.height)
    background.addSubview(text)
    panel.contentView = background
    panel.orderFrontRegardless()

    let visibleUntil = Date(timeIntervalSinceNow: seconds)
    while Date() < visibleUntil {
        RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.03))
    }

    NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.35
        panel.animator().alphaValue = 0
    }
    let fadeUntil = Date(timeIntervalSinceNow: 0.4)
    while Date() < fadeUntil {
        RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.03))
    }
    panel.orderOut(nil)
}

// MARK: - output

/// Proportionally shrinks an image until it fits `maxPixels`, or returns nil if
/// it already does.
///
/// The clipboard copy of a stitched page needs this even though the saved file
/// does not. A 5120×52014 capture is 267 megapixels; handed to the pasteboard it
/// killed TextEdit outright, and nothing downstream can use that resolution
/// anyway — Claude scales image input to 2576 px on the long edge before it ever
/// looks at it. The full-resolution PNG stays on disk; only what travels through
/// the clipboard is bounded.
func downscaled(_ image: CGImage, maxPixels: Int) -> CGImage? {
    let pixels = image.width * image.height
    guard pixels > maxPixels else { return nil }

    let scale = (Double(maxPixels) / Double(pixels)).squareRoot()
    let width = max(1, Int(Double(image.width) * scale))
    let height = max(1, Int(Double(image.height) * scale))

    let rgb = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: rgb,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return nil }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()
}

func writePNG(_ image: CGImage, to path: String) -> Bool {
    guard let destination = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)
    else { return false }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination)
}
