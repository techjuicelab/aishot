// Reading-order cases for TextLayout.swift — no Vision, no app, just boxes.
// The layouts come from real captures that went wrong in 1.10.2: two plan cards
// read as one interleaved list, a phantom line from a duplicate reading, rows
// split into one line per piece.
//
//   swiftc tests/text-layout/main.swift TextLayout.swift -o /tmp/aishot-layout-tests \
//     && /tmp/aishot-layout-tests

import CoreGraphics
import Foundation
func L(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ t: String, h: CGFloat = 20, c: Float = 1) -> RecognizedLine {
  RecognizedLine(rect: CGRect(x: x, y: y, width: w, height: h), text: t, confidence: c) }
var failures = 0
func check(_ name: String, _ lines: [RecognizedLine], _ expected: String) {
  let got = readingOrderText(lines)
  if got == expected { print("PASS", name) } else { failures += 1; print("FAIL", name, "\n--- got:\n\(got)\n--- expected:\n\(expected)") }
}
// 1. table: short cells, aligned rows → rows joined with tabs
check("table", [L(0,0,60,"이름"), L(300,0,40,"나이"), L(0,30,60,"홍길동"), L(300,30,20,"30"), L(0,60,60,"김철수"), L(300,60,20,"41")],
      "이름\t나이\n홍길동\t30\n김철수\t41")
// 2. two prose columns with aligned baselines → left column, blank line, right column
var two: [RecognizedLine] = []
for i in 0..<4 { two.append(L(0, CGFloat(i)*26, i == 3 ? 200 : 400, "L\(i)")); two.append(L(500, CGFloat(i)*26, i == 3 ? 150 : 400, "R\(i)")) }
check("two columns", two, "L0\nL1\nL2\nL3\n\nR0\nR1\nR2\nR3")
// 3. ghost duplicate over a real line → dropped
check("ghost", [L(0,0,900,"네, 가능합니다. 다만 지금 버전", h: 22, c: 1), L(0,-4,150,"넹. 가능합니다._", h: 30, c: 0.3), L(0,30,200,"추가가 필요합니다.")],
      "네, 가능합니다. 다만 지금 버전\n추가가 필요합니다.")
// 4. narrow sidebar + wide content, rows not aligned → sidebar first, then content
var side: [RecognizedLine] = [L(0,0,80,"홈"), L(0,45,80,"설정"), L(0,90,80,"도움말")]
for i in 0..<6 { side.append(L(200, 8 + CGFloat(i)*26, i == 5 ? 300 : 600, "본문\(i)")) }
check("sidebar", side, "홈\n\n설정\n\n도움말\n\n본문0\n본문1\n본문2\n본문3\n본문4\n본문5")
// 5. form: narrow labels with values on the same rows → rows
check("form", [L(0,0,60,"목적지"), L(120,0,200,"Ghostty"), L(0,40,60,"언어"), L(120,40,200,"한국어")],
      "목적지\tGhostty\n\n언어\t한국어")
// 6. same-row phrase pieces close together → single space
check("phrase", [L(0,0,100,"Google AI"), L(110,0,40,"Pro")], "Google AI Pro")
// 7. paragraph gap → blank line; tight lines → none
check("paragraphs", [L(0,0,500,"첫 문단 첫 줄"), L(0,24,300,"첫 문단 둘째 줄"), L(0,70,400,"둘째 문단")],
      "첫 문단 첫 줄\n첫 문단 둘째 줄\n\n둘째 문단")

// --- windows across a wide capture (mergingWindows) ---------------------------
// A 5120-px capture read through two 3840-px windows: 0..<3840 and 1280..<5120.
func W(_ minX: CGFloat, _ lines: [RecognizedLine]) -> RecognizedWindow {
  RecognizedWindow(minX: minX, maxX: minX + 3840, lines: lines) }
func checkMerge(_ name: String, _ windows: [RecognizedWindow], _ expected: [String]) {
  let got = mergingWindows(windows, captureWidth: 5120)
    .sorted { ($0.rect.minY, $0.rect.minX) < ($1.rect.minY, $1.rect.minX) }.map(\.text)
  if got == expected { print("PASS", name) } else { failures += 1; print("FAIL", name, "\n--- got:\n\(got)\n--- expected:\n\(expected)") }
}
// 8. a line inside both windows → kept once
checkMerge("window twin", [W(0, [L(1500, 0, 900, "가운데 줄")]), W(1280, [L(1500, 0, 900, "가운데 줄")])], ["가운데 줄"])
// 9. a line the right window cuts at its left edge → the whole one from the left window wins
checkMerge("window fragment", [W(0, [L(100, 0, 1600, "왼쪽 열의 온전한 줄")]), W(1280, [L(1284, 0, 416, "온전한 줄")])],
           ["왼쪽 열의 온전한 줄"])
// 10. lines only one window can see are all kept
checkMerge("window sides", [W(0, [L(40, 0, 700, "왼쪽 끝")]), W(1280, [L(4300, 0, 700, "오른쪽 끝")])], ["왼쪽 끝", "오른쪽 끝"])
// 11. a fragment on another row is not dropped by a whole line above it
checkMerge("window rows", [W(0, [L(100, 0, 1600, "첫 줄"), L(3000, 40, 838, "둘째 줄 왼쪽 조각")]),
                           W(1280, [L(3000, 40, 1500, "둘째 줄 왼쪽 조각과 나머지")])],
           ["첫 줄", "둘째 줄 왼쪽 조각과 나머지"])
// 12. a line longer than the overlap, cut in both windows → joined on the shared text
checkMerge("window long line",
           [W(0, [L(100, 0, 3738, "alpha bravo charlie delta echo foxtrot golf hotel indi")]),
            W(1280, [L(1284, 0, 3700, "harlie delta echo foxtrot golf hotel india juliett kilo lima")])],
           ["alpha bravo charlie delta echo foxtrot golf hotel india juliett kilo lima"])
// 13. one window: nothing to merge, nothing changed
if mergingWindows([RecognizedWindow(minX: 0, maxX: 2000, lines: [L(0, 0, 100, "a"), L(1990, 0, 10, "b")])], captureWidth: 2000).count == 2 {
  print("PASS single window") } else { failures += 1; print("FAIL single window") }

// --- parts of a tile left unread (unreadBands) ---------------------------------
// A 1000-row tile; text lines are 20 rows tall on a 30-row pitch.
func checkBands(_ name: String, busy: [Range<Int>], read: [Range<Int>], _ expected: [Range<Int>]) {
  var rows = [Bool](repeating: false, count: 1000)
  for range in busy { for row in range { rows[row] = true } }
  let got = unreadBands(busyRows: rows, lineSpans: read, within: 0..<1000, lineHeight: 20)
  if got == expected { print("PASS", name) } else { failures += 1; print("FAIL", name, "— got \(got), expected \(expected)") }
}
let textRows = (0..<30).map { $0 * 30 ..< $0 * 30 + 20 }
// 14. every line read → nothing to read again
checkBands("bands none", busy: textRows, read: textRows, [])
// 15. lines 10–19 came back unread → that stretch, trimmed to its text
checkBands("bands gap", busy: textRows, read: Array(textRows[..<10] + textRows[20...]), [300..<590])
// 16. nothing read at all → the whole of the text
checkBands("bands empty tile", busy: textRows, read: [], [0..<890])
// 17. one unread line between read ones is left alone
checkBands("bands single line", busy: textRows, read: Array(textRows[..<10] + textRows[11...]), [])
// 18. a paragraph gap is blank, a thin rule is too small → neither is a band
checkBands("bands blank and rule", busy: Array(textRows[..<10]) + [450..<452] + Array(textRows[20...]),
           read: Array(textRows[..<10] + textRows[20...]), [])
print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
if failures > 0 { exit(1) }
