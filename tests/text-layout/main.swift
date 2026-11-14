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
print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
if failures > 0 { exit(1) }
