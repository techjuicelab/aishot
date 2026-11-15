// Settling cases for ScrollCapture.swift's settledFrame — no screen, no window,
// just a simulated one on a simulated clock. Each case is a window that reacts
// to a scroll burst in a different way; what matters is which frame is taken
// as "at rest" and how long that took.
//
//   swiftc tests/scroll-settle/main.swift ScrollCapture.swift TextLayout.swift \
//     -o /tmp/aishot-settle-tests && /tmp/aishot-settle-tests

import ApplicationServices
import Foundation

// ScrollCapture.swift leans on three things from main.swift.
func log(_ message: String) {}
func t(_ korean: String, _ english: String) -> String { english }
func axString(_ element: AXUIElement, attribute: CFString) -> String? { nil }

let rows = 400, columns = 64
/// The window showing a tall page from `offset` down; `blink` flips a few rows
/// in place, the way a cursor or a spinner does without any scrolling.
func window(at offset: Int, blink: Bool = false) -> FrameSignature {
  var samples = [UInt8](repeating: 0, count: rows * columns)
  for y in 0..<rows { for c in 0..<columns {
    let pageRow = y + offset
    samples[y * columns + c] = UInt8(truncatingIfNeeded: (pageRow &* 131 &+ c &* 31 &+ (pageRow / 7) &* 57) % 251)
  } }
  if blink { for y in 200..<206 { for c in 0..<columns { samples[y * columns + c] = 255 } } }
  return FrameSignature(width: columns, height: rows, columns: columns, samples: samples)
}

var failures = 0
/// Runs settledFrame against a window whose scroll offset at time `t` since
/// the burst is `position(t)`; a shot costs 40 ms, like a real one.
func check(_ name: String, expectOffset: Int?, finishesBefore latest: Double, notBefore earliest: Double = 0,
           blinkUntil: Double = -1, position: @escaping (Double) -> Int?) {
  var now = 0.0
  let settled: (frame: Int, signature: FrameSignature)? = settledFrame(
    after: window(at: 0),
    shoot: {
      now += 0.04
      guard let offset = position(now) else { return nil }
      return (offset, window(at: offset, blink: now < blinkUntil))
    },
    pause: { now += $0 }, clock: { now })
  let ok = settled?.frame == expectOffset && now <= latest && now >= earliest
  if ok { print("PASS", name, String(format: "(%.2fs)", now)) } else {
    failures += 1
    print("FAIL", name, "— offset \(String(describing: settled?.frame)) at \(String(format: "%.2f", now))s,",
          "expected \(String(describing: expectOffset)) between \(earliest)s and \(latest)s")
  }
}

// 1. a snappy window: moved by the first look → done well inside the old 0.28 s + two shots
check("snappy", expectOffset: 300, finishesBefore: 0.25) { _ in 300 }
// 2. the bottom of the page: nothing moves → believed only after the full settle time
check("bottom", expectOffset: 0, finishesBefore: 0.50, notBefore: 0.28) { _ in 0 }
// 3. a slow starter: still for 0.2 s, then jumps → the jumped frame, never the still one
check("slow start", expectOffset: 300, finishesBefore: 0.50) { $0 < 0.2 ? 0 : 300 }
// 4. a smooth scroll: glides for 0.3 s → the resting frame, not one from the glide
check("smooth", expectOffset: 300, finishesBefore: 0.50) { min(300, Int($0 / 0.3 * 300)) }
// 5. a blinking cursor before a late scroll → not mistaken for movement
check("blink then scroll", expectOffset: 300, finishesBefore: 0.50, blinkUntil: 0.22) { $0 < 0.22 ? 0 : 300 }
// 6. something that never holds still (a video) → gives up with the latest frame, in bounded time
check("never still", expectOffset: 1930, finishesBefore: 2.0, notBefore: 1.8) { Int(($0 * 1000).rounded()) }
// 7. the window went away before the first shot → nil
check("no frame", expectOffset: nil, finishesBefore: 0.2) { _ in nil }

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
if failures > 0 { exit(1) }
