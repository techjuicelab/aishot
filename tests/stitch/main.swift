// Stitching cases for ScrollCapture.swift's stitch — frames cut from a page
// whose every pixel is known, so the result can be checked against the page
// itself. What goes wrong at a seam is whatever the window puts over the
// bottom of a frame: its rounded corners, and a footer that floats.
//
//   swiftc tests/stitch/main.swift ScrollCapture.swift TextLayout.swift \
//     -o /tmp/aishot-stitch-tests && /tmp/aishot-stitch-tests

import ApplicationServices
import Foundation

// ScrollCapture.swift leans on three things from main.swift.
func log(_ message: String) {}
func t(_ korean: String, _ english: String) -> String { english }
func axString(_ element: AXUIElement, attribute: CFString) -> String? { nil }

let width = 400, frameHeight = 600
/// The page: every row and every 8-px column block has its own shade.
func page(_ x: Int, _ y: Int) -> UInt8 { UInt8((y &* 131 &+ (x / 8) &* 31 &+ (y / 7) &* 57) % 251) }
/// What a floating footer or a sticky header shows: nothing the page ever does.
let footerShade: UInt8 = 253, headerShade: UInt8 = 255

struct Window {
  var corner = 0  // radius of the rounded corners, in px
  var footer = 0  // rows of a footer floating over the bottom
  var header = 0  // rows of a header that sticks once the page has scrolled
}

/// One shot of the window with the page scrolled to `offset`.
func frame(at offset: Int, _ window: Window) -> CGImage {
  var pixels = [UInt8](repeating: 0, count: width * frameHeight * 4)
  for y in 0..<frameHeight { for x in 0..<width {
    var shade = page(x, y + offset)
    if window.header > 0, offset > 0, y < window.header { shade = headerShade }
    if y >= frameHeight - window.footer { shade = footerShade }
    var alpha: UInt8 = 255
    let r = window.corner
    if r > 0 {
      // Outside the quarter circle in any of the four corners.
      let dx = x < r ? r - x : (x >= width - r ? x - (width - r - 1) : 0)
      let dy = y < r ? r - y : (y >= frameHeight - r ? y - (frameHeight - r - 1) : 0)
      if dx > 0, dy > 0, dx * dx + dy * dy > r * r { alpha = 0; shade = 0 }
    }
    let i = (y * width + x) * 4
    pixels[i] = shade; pixels[i + 1] = shade; pixels[i + 2] = shade; pixels[i + 3] = alpha
  } }
  let provider = CGDataProvider(data: Data(pixels) as CFData)!
  return CGImage(width: width, height: frameHeight, bitsPerComponent: 8, bitsPerPixel: 32,
                 bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                 bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                 provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}

func shades(of image: CGImage) -> [UInt8] {
  var gray = [UInt8](repeating: 0, count: image.width * image.height)
  gray.withUnsafeMutableBytes { buffer in
    let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                            bitsPerComponent: 8, bytesPerRow: image.width,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
  }
  return gray
}

var failures = 0
/// Stitches the page shot at `offsets` and counts the rows that are not the
/// page's own. `spared` rows at the top and the bottom are left out of the
/// count: the corners of the window itself belong in the picture.
func check(_ name: String, _ window: Window, offsets: [Int], expectHeight: Int, spared: Int = 0) {
  let frames = offsets.map { frame(at: $0, window) }
  let signatures = frames.compactMap { frameSignature(of: $0) }
  let advances = zip(offsets.dropFirst(), offsets).map { $0 - $1 }
  let sticky = stickyBands(signatures)
  guard let stitched = stitch(frames: frames, advances: advances, sticky: sticky) else {
    print("FAIL \(name): nothing stitched"); failures += 1; return
  }
  let got = shades(of: stitched)
  var wrongRows: [Int] = []
  for y in spared..<max(spared, stitched.height - spared) {
    // A header that has stuck covers the page in every frame after the first,
    // so those rows of the page are in no frame at all. Nothing else may differ.
    var wrong = false
    for x in 0..<width where abs(Int(got[y * width + x]) - Int(page(x, y))) > 2 { wrong = true; break }
    if wrong { wrongRows.append(y) }
  }
  let heightOK = stitched.height == expectHeight
  if wrongRows.isEmpty, heightOK {
    print("PASS \(name) (\(stitched.height) rows, sticky \(sticky.top)/\(sticky.bottom))")
  } else {
    failures += 1
    let sample = wrongRows.prefix(6).map(String.init).joined(separator: " ")
    print("FAIL \(name): \(wrongRows.count) rows are not the page's (first: \(sample)); height \(stitched.height), expected \(expectHeight); sticky \(sticky.top)/\(sticky.bottom)")
  }
}

let steady = [0, 400, 800, 1200, 1600]
check("plain window", Window(), offsets: steady, expectHeight: 2200)
check("rounded corners", Window(corner: 30), offsets: steady, expectHeight: 2200, spared: 30)
check("floating footer", Window(footer: 50), offsets: steady, expectHeight: 2150)
check("footer and corners", Window(corner: 30, footer: 50), offsets: steady, expectHeight: 2150, spared: 30)
check("corners, uneven steps", Window(corner: 30), offsets: [0, 470, 480, 900, 1385, 1400], expectHeight: 2000, spared: 30)
check("corners, two frames", Window(corner: 30), offsets: [0, 350], expectHeight: 950, spared: 30)
// The header hides page rows 400..<440 and the like in every frame that could
// have shown them, but none of those rows are ever part of a strip.
check("sticky header and corners", Window(corner: 30, header: 40), offsets: steady, expectHeight: 2200, spared: 30)

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
