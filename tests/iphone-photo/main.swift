// swiftc tests/iphone-photo/main.swift Hotkeys.swift iPhonePhoto.swift -o /tmp/aishot-photo-tests
import AppKit
import Carbon
import ImageIO
import UniformTypeIdentifiers

func t(_ korean: String, _ english: String) -> String { english }

let decoder = JSONDecoder()
let encoder = JSONEncoder()
let legacy = try decoder.decode(HotkeyConfiguration.self, from: Data("""
{"screenshot":{"keyCode":19,"modifiers":768}}
""".utf8))
let defaultPhoto = KeyboardShortcut(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(cmdKey | optionKey))
precondition(legacy.iphonePhoto == defaultPhoto)
precondition(legacy.ocr == nil && legacy.scroll == nil)
let legacyConflict = try decoder.decode(HotkeyConfiguration.self, from: Data("""
{"screenshot":{"keyCode":35,"modifiers":2304}}
""".utf8))
precondition(legacyConflict.screenshot == defaultPhoto && legacyConflict.iphonePhoto == nil)
var disabled = legacy
disabled.iphonePhoto = nil
let roundTrip = try decoder.decode(HotkeyConfiguration.self, from: encoder.encode(disabled))
precondition(roundTrip == disabled)
print("PASS: legacy migration, conflict preservation, explicit disable")

let width = 80, height = 48

func fixture(_ type: UTType, width: Int, height: Int, detailed: Bool = false) -> Data {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    if detailed {
        // Fixed seed gives high-frequency image detail without a fixture file.
        let pixels = context.data!.assumingMemoryBound(to: UInt32.self)
        let stride = context.bytesPerRow / MemoryLayout<UInt32>.stride
        var state: UInt32 = 42
        for y in 0..<height {
            for x in 0..<width {
                state = 1_664_525 &* state &+ 1_013_904_223
                pixels[y * stride + x] = state
            }
        }
    } else {
        context.setFillColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!,
                               [kCGImagePropertyOrientation: 6] as CFDictionary)
    precondition(CGImageDestinationFinalize(destination))
    return data as Data
}

func checkImage(_ data: Data, type: UTType, width: Int, height: Int) {
    let source = CGImageSourceCreateWithData(data as CFData, nil)!
    let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
    precondition(CGImageSourceGetType(source) as String? == type.identifier)
    precondition(image.width == width && image.height == height,
                 "Expected \(width)×\(height), got \(image.width)×\(image.height)")
}

func longEdge(of data: Data) -> Int {
    let source = CGImageSourceCreateWithData(data as CFData, nil)!
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
    let width = properties[kCGImagePropertyPixelWidth] as! Int
    let height = properties[kCGImagePropertyPixelHeight] as! Int
    return max(width, height)
}

let jpeg = fixture(.jpeg, width: width, height: height)
precondition(PhonePhoto.jpeg(from: jpeg, quality: .original) == jpeg)
let alreadyCompact = PhonePhoto.aiJPEG(from: jpeg) { _ in
    preconditionFailure("A compact incoming JPEG should not run OCR or be re-encoded")
}
precondition(alreadyCompact == jpeg)
checkImage(PhonePhoto.png(from: jpeg)!, type: .png, width: height, height: width)
let heic = fixture(.heic, width: width, height: height)
checkImage(PhonePhoto.jpeg(from: heic, quality: .original)!, type: .jpeg, width: height, height: width)
precondition(PhonePhoto.jpeg(from: Data("bad photo".utf8), quality: .original) == nil)
print("PASS: JPEG preserves original bytes, HEIC and clipboard PNG keep orientation, invalid input rejected")

let largeJPEG = fixture(.jpeg, width: 3200, height: 1800)
precondition(PhonePhoto.jpeg(from: largeJPEG, quality: .original) == largeJPEG)
checkImage(PhonePhoto.jpeg(from: largeJPEG, quality: .high)!, type: .jpeg, width: 1440, height: 2560)
checkImage(PhonePhoto.jpeg(from: largeJPEG, quality: .compact)!, type: .jpeg, width: 900, height: 1600)
print("PASS: High and Compact cap the long edge and preserve aspect ratio and orientation")

for quality in [PhonePhoto.Quality.high, .compact] {
    checkImage(PhonePhoto.jpeg(from: jpeg, quality: quality)!, type: .jpeg, width: height, height: width)
}
print("PASS: High and Compact do not upscale smaller photos")

let customDefault = PhonePhoto.JPEGOptions.customDefault
let aiDefault = PhonePhoto.JPEGOptions.aiDefault
precondition(customDefault.maxLongEdge == 2560 && customDefault.compression == 90)
precondition(aiDefault.maxLongEdge == 2048 && aiDefault.compression == 82)
precondition(PhonePhoto.JPEGOptions.pixelRange == 320...12000)
precondition(PhonePhoto.JPEGOptions.compressionRange == 40...100)

let custom = PhonePhoto.JPEGOptions(maxLongEdge: 800, compression: 60)
checkImage(PhonePhoto.jpeg(from: largeJPEG, quality: .custom, custom: custom)!,
           type: .jpeg, width: 450, height: 800)
checkImage(PhonePhoto.jpeg(from: jpeg, quality: .custom, custom: custom)!,
           type: .jpeg, width: height, height: width)
print("PASS: Custom uses its own JPEG dimensions without upscaling")

for invalidOptions in [PhonePhoto.JPEGOptions(maxLongEdge: 319, compression: 90),
                       PhonePhoto.JPEGOptions(maxLongEdge: 12_001, compression: 90),
                       PhonePhoto.JPEGOptions(maxLongEdge: 800, compression: 39),
                       PhonePhoto.JPEGOptions(maxLongEdge: 800, compression: 101)] {
    precondition(PhonePhoto.jpeg(from: jpeg, options: invalidOptions) == nil,
                 "Out-of-range JPEG options must be rejected")
}
let largestAllowed = PhonePhoto.JPEGOptions(maxLongEdge: 12_000, compression: 90)
checkImage(PhonePhoto.jpeg(from: jpeg, options: largestAllowed)!, type: .jpeg, width: height, height: width)
print("PASS: JPEG options enforce the pixel and compression ranges")

let detailedJPEG = fixture(.jpeg, width: 2400, height: 1200, detailed: true)
let fullPNG = PhonePhoto.png(from: detailedJPEG)!
let aiJPEG = PhonePhoto.jpeg(from: detailedJPEG, options: aiDefault)!
checkImage(fullPNG, type: .png, width: 1200, height: 2400)
checkImage(aiJPEG, type: .jpeg, width: 1024, height: 2048)
precondition(aiJPEG.count < fullPNG.count / 2, "AI JPEG \(aiJPEG.count) bytes, PNG \(fullPNG.count) bytes")
let highQualityOptions = PhonePhoto.JPEGOptions(maxLongEdge: 320, compression: 100)
let lowQualityOptions = PhonePhoto.JPEGOptions(maxLongEdge: 320, compression: 40)
let highQuality = PhonePhoto.jpeg(from: detailedJPEG, options: highQualityOptions)!
let lowQuality = PhonePhoto.jpeg(from: detailedJPEG, options: lowQualityOptions)!
checkImage(highQuality, type: .jpeg, width: 160, height: 320)
checkImage(lowQuality, type: .jpeg, width: 160, height: 320)
precondition(lowQuality.count < highQuality.count)
print("PASS: JPEG compression changes payload size, and the default AI JPEG is under half the full PNG (\(aiJPEG.count) vs \(fullPNG.count) bytes)")

let sourceLines = ["Invoice 2026", "LOT 01X4", "LOT 01X4", "Total 112.51"]
var recognizedEdges: [Int] = []
let compactWithText = PhonePhoto.aiJPEG(from: largeJPEG, recognize: { image in
    recognizedEdges.append(longEdge(of: image))
    return sourceLines
})!
checkImage(compactWithText, type: .jpeg, width: 1152, height: 2048)
precondition(recognizedEdges.starts(with: [3200, 2048]))
precondition(compactWithText.count < largeJPEG.count)
print("PASS: AI JPEG accepts the compact, correctly oriented image when all OCR lines survive")

let oneLineMissing = Array(sourceLines.dropLast())
let largerWithText = PhonePhoto.aiJPEG(from: largeJPEG, recognize: { image in
    longEdge(of: image) <= 2048 ? oneLineMissing : sourceLines
})!
precondition(longEdge(of: largerWithText) > 2048, "A small source line disappeared in the compact JPEG")
checkImage(largerWithText, type: .jpeg, width: 1440, height: 2560)
precondition(largerWithText.count < largeJPEG.count)
print("PASS: AI JPEG tries a larger image when a small source line disappears")

var missingDuplicate = sourceLines
missingDuplicate.remove(at: 2)
let keptDuplicate = PhonePhoto.aiJPEG(from: largeJPEG, recognize: { image in
    longEdge(of: image) <= 2048 ? missingDuplicate : sourceLines
})!
precondition(longEdge(of: keptDuplicate) > 2048, "One OCR line occurrence disappeared in the compact JPEG")
checkImage(keptDuplicate, type: .jpeg, width: 1440, height: 2560)
print("PASS: AI JPEG requires every occurrence of a repeated source line")

let failedSourceOCR = PhonePhoto.aiJPEG(from: largeJPEG, recognize: { _ in nil })
precondition(failedSourceOCR == largeJPEG, "A source OCR failure must preserve the original JPEG")
let failedCandidateOCR = PhonePhoto.aiJPEG(from: largeJPEG, recognize: { image in
    image == largeJPEG ? sourceLines : nil
})
precondition(failedCandidateOCR == largeJPEG, "Candidate OCR failures must preserve the original JPEG")
print("PASS: AI JPEG keeps the original when OCR cannot verify readability")

let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let now = Date()
let first = try PhonePhoto.save(jpeg, in: directory, now: now)
let second = try PhonePhoto.save(jpeg, in: directory, now: now)
precondition(first != second && first.pathExtension == "jpg" && second.pathExtension == "jpg")
precondition(first.lastPathComponent.hasPrefix("IMG_"))
let saved = try Data(contentsOf: first)
precondition(saved == jpeg)
print("PASS: same-second captures are both saved")

let derivative = try PhonePhoto.save(aiJPEG, in: directory, now: now, suffix: "-AI")
let derivativeAgain = try PhonePhoto.save(lowQuality, in: directory, now: now, suffix: "-AI")
let baseName = first.deletingPathExtension().lastPathComponent
precondition(derivative.lastPathComponent == "\(baseName)-AI.jpg")
precondition(derivativeAgain.lastPathComponent == "\(baseName)-AI (2).jpg")
let originalAfter = try Data(contentsOf: first)
let derivativeAfter = try Data(contentsOf: derivative)
let derivativeAgainAfter = try Data(contentsOf: derivativeAgain)
precondition(originalAfter == jpeg && derivativeAfter == aiJPEG && derivativeAgainAfter == lowQuality)
print("PASS: named AI derivatives coexist with the original and each other")
