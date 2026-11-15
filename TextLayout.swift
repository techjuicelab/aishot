// AIShot — reading order for recognized text.
//
// Vision hands back lines of text with a box each and no idea of layout. The
// first version of Copy Text sorted those lines top to bottom and printed each
// on its own line, which reads well for a single block of text and badly for
// almost anything captured from a web page or an app window:
//
//   - Two columns side by side came out interleaved, one line from the left,
//     one from the right. Measured on a two-card pricing page: "Google AI Pro /
//     Google AI Ultra / 5TB 저장용량 / 20TB 저장용량 / …" — each card's text
//     scattered through the other's.
//   - Vision sometimes reports a second, low-confidence reading of a line that
//     touches the edge of the capture, on top of the real one. Both were kept,
//     so the copy started with a line that is not on screen ("넹. 가능합니다._"
//     at confidence 0.30 over "네, 가능합니다. …" at 1.00).
//   - A row Vision split into pieces (a label and its value, a toolbar, a table
//     row) became one line per piece.
//
// The order is now recovered from the boxes: duplicates are dropped, the
// capture is cut recursively into columns (a vertical gutter no line crosses)
// and bands (a horizontal gap), and what is left is read row by row, with the
// pieces of a row joined on one line. A blank line marks a paragraph gap or the
// start of the next column.

import CoreGraphics
import Foundation

/// One line Vision recognized, in the capture's pixel space with the origin at
/// the top left — the way the capture is read, not the way Vision reports it.
struct RecognizedLine {
    var rect: CGRect
    var text: String
    var confidence: Float
}

/// The recognized lines as clipboard text, in reading order.
func readingOrderText(_ recognized: [RecognizedLine]) -> String {
    let lines = withoutDuplicateLines(recognized.filter {
        $0.rect.width > 0 && $0.rect.height > 0
            && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    })
    guard !lines.isEmpty else { return "" }
    let heights = lines.map(\.rect.height).sorted()
    let unit = heights[heights.count / 2]
    var pieces: [LayoutPiece] = []
    arrange(lines, unit: unit, into: &pieces)
    return render(pieces)
}

/// Drops a line when most of it lies inside a line Vision was surer of.
///
/// Separate lines of text do not overlap like that — tightly set lines share a
/// sliver of their boxes at most — so heavy overlap means two readings of the
/// same text, and the more confident one is the one to keep.
func withoutDuplicateLines(_ lines: [RecognizedLine]) -> [RecognizedLine] {
    func area(_ rect: CGRect) -> CGFloat { rect.width * rect.height }
    let ranked = lines.indices.sorted { a, b in
        if lines[a].confidence != lines[b].confidence { return lines[a].confidence > lines[b].confidence }
        if area(lines[a].rect) != area(lines[b].rect) { return area(lines[a].rect) > area(lines[b].rect) }
        return a < b
    }
    var kept: [Int] = []
    for index in ranked {
        let rect = lines[index].rect
        let duplicate = kept.contains { other in
            let otherRect = lines[other].rect
            guard rect.minY < otherRect.maxY, otherRect.minY < rect.maxY else { return false }
            let overlap = rect.intersection(otherRect)
            guard !overlap.isNull else { return false }
            return area(overlap) >= min(area(rect), area(otherRect)) * 0.5
        }
        if !duplicate { kept.append(index) }
    }
    return kept.sorted().map { lines[$0] }
}

// MARK: - windows across a wide capture

/// What Vision read through one horizontal window of a strip of the capture.
/// `minX`/`maxX` are the window's extent in the capture's pixels.
struct RecognizedWindow {
    var minX: CGFloat
    var maxX: CGFloat
    var lines: [RecognizedLine]
}

/// One set of lines from the overlapping windows of the same strip.
///
/// A line that lies wholly inside a window is read whole there. One that
/// crosses a window's edge is read as far as the edge, and what comes back is
/// a fragment ending — often mid-word — at the cut. So a fragment gives way to
/// any whole line it overlaps on its row, and whole lines seen through two
/// windows are kept once. Only a line longer than the overlap is cut in every
/// window; its two fragments are joined on the text they share.
func mergingWindows(_ windows: [RecognizedWindow], captureWidth: CGFloat) -> [RecognizedLine] {
    guard windows.count > 1 else { return windows.first?.lines ?? [] }

    func sameRow(_ a: CGRect, _ b: CGRect) -> Bool {
        min(a.maxY, b.maxY) - max(a.minY, b.minY) >= min(a.height, b.height) * 0.5
    }
    func sharedWidth(_ a: CGRect, _ b: CGRect) -> CGFloat {
        max(0, min(a.maxX, b.maxX) - max(a.minX, b.minX))
    }

    var whole: [(window: Int, line: RecognizedLine)] = []
    var fragments: [(window: Int, line: RecognizedLine)] = []
    for (index, window) in windows.enumerated() {
        for line in window.lines {
            let slack = max(12, line.rect.height * 0.5)
            let cutLeft = window.minX > 0 && line.rect.minX - window.minX <= slack
            let cutRight = window.maxX < captureWidth && window.maxX - line.rect.maxX <= slack
            if cutLeft || cutRight { fragments.append((index, line)) } else { whole.append((index, line)) }
        }
    }

    // Whole lines: the same line seen through two windows is kept once.
    var kept: [(window: Int, line: RecognizedLine)] = []
    for candidate in whole {
        let twin = kept.firstIndex { other in
            other.window != candidate.window && sameRow(other.line.rect, candidate.line.rect)
                && sharedWidth(other.line.rect, candidate.line.rect)
                    >= min(other.line.rect.width, candidate.line.rect.width) * 0.8
        }
        if let twin {
            if candidate.line.rect.width > kept[twin].line.rect.width { kept[twin] = candidate }
        } else {
            kept.append(candidate)
        }
    }

    // Fragments: dropped where a whole line already covers the row there.
    var loose: [(window: Int, line: RecognizedLine)] = []
    for fragment in fragments {
        let covered = kept.contains {
            sameRow($0.line.rect, fragment.line.rect) && sharedWidth($0.line.rect, fragment.line.rect) > 0
        }
        if !covered { loose.append(fragment) }
    }
    // What is left was cut in every window that saw it. Two fragments of one
    // line overlap on the row; join them, or failing that keep the longer.
    var joined: [RecognizedLine] = []
    for fragment in loose.sorted(by: { $0.line.rect.minX < $1.line.rect.minX }) {
        if let last = joined.indices.last, sameRow(joined[last].rect, fragment.line.rect),
           sharedWidth(joined[last].rect, fragment.line.rect) > 0 {
            let left = joined[last]
            let right = fragment.line
            if let text = joiningCutFragments(left.text, right.text) {
                joined[last] = RecognizedLine(rect: left.rect.union(right.rect), text: text,
                                              confidence: min(left.confidence, right.confidence))
            } else if right.rect.width > left.rect.width {
                joined[last] = right
            }
        } else {
            joined.append(fragment.line)
        }
    }
    return kept.map(\.line) + joined
}

/// Joins the left and right fragments of one line on the longest run of text
/// they share, or returns nil when they share too little to be sure. The
/// characters next to each cut are not trusted: a glyph sliced by the window's
/// edge is read as something else.
func joiningCutFragments(_ left: String, _ right: String) -> String? {
    let a = Array(left), b = Array(right)
    guard a.count >= 8, b.count >= 8 else { return nil }
    // Longest common substring, by dynamic programming over two short lines.
    var best = (length: 0, endA: 0, endB: 0)
    var previous = [Int](repeating: 0, count: b.count + 1)
    for i in 1 ... a.count {
        var current = [Int](repeating: 0, count: b.count + 1)
        for j in 1 ... b.count where a[i - 1] == b[j - 1] {
            current[j] = previous[j - 1] + 1
            if current[j] > best.length { best = (current[j], i, j) }
        }
        previous = current
    }
    guard best.length >= 8 else { return nil }
    return String(a[..<best.endA]) + String(b[best.endB...])
}

// MARK: - parts of a tile left unread

/// Stretches of a tile, as row ranges, that show something and have no line
/// read in them — where Vision answered for the rest of the tile and skipped
/// this part. `busyRows` says which pixel rows hold more than flat background,
/// `lineSpans` the rows each recognized line covers, `within` the rows this
/// tile is responsible for.
///
/// A stretch has to be at least two lines tall and busy over a fifth of its
/// height. The space between paragraphs is not busy, a rule or a border is too
/// thin, and a single unread line is as likely a line Vision joined to its
/// neighbour as one it missed. A picture does qualify, and costs one request
/// that finds nothing.
func unreadBands(busyRows: [Bool], lineSpans: [Range<Int>], within: Range<Int>,
                 lineHeight: Int) -> [Range<Int>] {
    var covered = [Bool](repeating: false, count: busyRows.count)
    for span in lineSpans {
        for row in max(0, span.lowerBound) ..< min(busyRows.count, span.upperBound) { covered[row] = true }
    }
    let minimum = max(60, lineHeight * 2)
    var bands: [Range<Int>] = []
    var row = max(0, within.lowerBound)
    let end = min(busyRows.count, within.upperBound)
    while row < end {
        guard !covered[row] else { row += 1; continue }
        var runEnd = row
        while runEnd < end, !covered[runEnd] { runEnd += 1 }
        let busy = (row ..< runEnd).filter { busyRows[$0] }
        if let first = busy.first, let last = busy.last {
            let band = first ..< last + 1
            if band.count >= minimum, busy.count * 5 >= band.count { bands.append(band) }
        }
        row = runEnd
    }
    return bands
}

private enum LayoutPiece {
    case row([RecognizedLine])
    case columnBreak
}

/// Columns first, then bands, then rows. Columns go first because a gutter is
/// the stronger signal: two columns usually share some horizontal gaps (their
/// lines sit on the same baseline grid), and cutting there would put a line of
/// each column into every band — the interleaving this exists to undo.
private func arrange(_ lines: [RecognizedLine], unit: CGFloat, into pieces: inout [LayoutPiece]) {
    if lines.count > 1, let columns = columnSplit(lines, unit: unit) {
        for (index, column) in columns.enumerated() {
            if index > 0 { pieces.append(.columnBreak) }
            arrange(column, unit: unit, into: &pieces)
        }
        return
    }
    if lines.count > 1, let bands = bandSplit(lines) {
        for band in bands { arrange(band, unit: unit, into: &pieces) }
        return
    }
    for row in rows(of: lines) { pieces.append(.row(row)) }
}

/// Splits at the widest vertical gutter that no line crosses, as long as what
/// lies on either side is not simply the cells of the same rows.
private func columnSplit(_ lines: [RecognizedLine], unit: CGFloat) -> [[RecognizedLine]]? {
    // Wider than any gap between words: Vision already returns whole lines, so
    // a gutter this wide only appears between separate blocks of text.
    let minimumGutter = max(unit * 1.5, 8)
    let sorted = lines.sorted { $0.rect.minX < $1.rect.minX }
    var gutters: [(start: CGFloat, end: CGFloat)] = []
    var reach = sorted[0].rect.maxX
    for line in sorted.dropFirst() {
        if line.rect.minX - reach >= minimumGutter { gutters.append((reach, line.rect.minX)) }
        reach = max(reach, line.rect.maxX)
    }
    for gutter in gutters.sorted(by: { $0.end - $0.start > $1.end - $1.start }) {
        let left = lines.filter { $0.rect.maxX <= gutter.start }
        let right = lines.filter { $0.rect.minX >= gutter.end }
        guard !left.isEmpty, !right.isEmpty else { continue }
        if looksLikeRowsOfOneTable(left, right),
           !(holdsRunningText(left, unit: unit) && holdsRunningText(right, unit: unit)) {
            continue
        }
        return [left, right]
    }
    return nil
}

/// A table, a form or a label next to its value also leaves a gutter, but
/// there nearly every line on the sparser side has a partner on the same row
/// across it, and the rows are what should be read.
private func looksLikeRowsOfOneTable(_ left: [RecognizedLine], _ right: [RecognizedLine]) -> Bool {
    let (fewer, more) = left.count <= right.count ? (left, right) : (right, left)
    let paired = fewer.filter { line in
        more.contains { abs($0.rect.midY - line.rect.midY) <= min($0.rect.height, line.rect.height) * 0.5 }
    }.count
    return Double(paired) >= Double(fewer.count) * 0.7
}

/// Whether a block reads as prose: wide enough for a sentence, with at least
/// one line that filled the block and wrapped onto the next.
///
/// Rows alone cannot tell columns from a table when the columns are built
/// alike — two plan cards side by side shared a row for 84% of their lines,
/// more than many real tables do. Wrapping is what tables rarely do and running
/// text always does, and a narrow side (line numbers, timestamps, the labels of
/// a form, spreadsheet cells) keeps the rows.
private func holdsRunningText(_ lines: [RecognizedLine], unit: CGFloat) -> Bool {
    let left = lines.map(\.rect.minX).min() ?? 0
    let width = (lines.map(\.rect.maxX).max() ?? 0) - left
    guard width >= unit * 10 else { return false }
    let sorted = lines.sorted { $0.rect.minY < $1.rect.minY }
    return zip(sorted, sorted.dropFirst()).contains { upper, lower in
        let height = min(upper.rect.height, lower.rect.height)
        return upper.rect.width >= width * 0.6
            && lower.rect.minY - upper.rect.maxY < height * 0.5
            && abs(lower.rect.minX - upper.rect.minX) < height
    }
}

/// Splits at the widest horizontal gaps — every gap within 10% of the widest,
/// so a page of evenly spaced lines is split in one step rather than one line
/// per level of recursion.
private func bandSplit(_ lines: [RecognizedLine]) -> [[RecognizedLine]]? {
    // Trimmed top and bottom: Vision's boxes for tightly set lines overlap a
    // little, and that must not hide the gap between them.
    func span(_ line: RecognizedLine) -> (top: CGFloat, bottom: CGFloat) {
        let inset = line.rect.height * 0.15
        return (line.rect.minY + inset, line.rect.maxY - inset)
    }
    let sorted = lines.sorted { span($0).top < span($1).top }
    var gaps: [(before: Int, size: CGFloat)] = []
    var reach = span(sorted[0]).bottom
    for index in sorted.indices.dropFirst() {
        let (top, bottom) = span(sorted[index])
        if top > reach { gaps.append((index, top - reach)) }
        reach = max(reach, bottom)
    }
    guard let widest = gaps.map(\.size).max() else { return nil }
    var bands: [[RecognizedLine]] = []
    var start = 0
    for gap in gaps where gap.size >= widest * 0.9 {
        bands.append(Array(sorted[start ..< gap.before]))
        start = gap.before
    }
    bands.append(Array(sorted[start...]))
    return bands
}

/// Groups lines with no gap between them into rows, each read left to right.
private func rows(of lines: [RecognizedLine]) -> [[RecognizedLine]] {
    // A strict order first: a pairwise "close enough in y" comparator is not
    // transitive and can swap densely spaced, indented lines.
    let sorted = lines.sorted {
        if $0.rect.midY != $1.rect.midY { return $0.rect.midY < $1.rect.midY }
        if $0.rect.minX != $1.rect.minX { return $0.rect.minX < $1.rect.minX }
        return $0.text < $1.text
    }
    // Grouped around a fixed anchor, with the tolerance scaled to the glyphs so
    // small text on adjacent lines is not mistaken for one row.
    var result: [[RecognizedLine]] = []
    var start = 0
    while start < sorted.count {
        let anchor = sorted[start]
        var end = start + 1
        while end < sorted.count,
              sorted[end].rect.midY - anchor.rect.midY
                <= min(anchor.rect.height, sorted[end].rect.height) * 0.45 {
            end += 1
        }
        result.append(sorted[start ..< end].sorted {
            if $0.rect.minX != $1.rect.minX { return $0.rect.minX < $1.rect.minX }
            return $0.text < $1.text
        })
        start = end
    }
    return result
}

private func render(_ pieces: [LayoutPiece]) -> String {
    var output: [String] = []
    var previous: (bottom: CGFloat, height: CGFloat)?
    var startsColumn = false
    for piece in pieces {
        switch piece {
        case .columnBreak:
            startsColumn = true
        case .row(let row):
            let top = row.map(\.rect.minY).min() ?? 0
            let bottom = row.map(\.rect.maxY).max() ?? 0
            let height = row.map(\.rect.height).min() ?? 0
            if let previous {
                // A paragraph gap: well over the space between lines of a
                // paragraph (about a quarter of a line in most UI text) and
                // about one empty line in a terminal.
                let gap = top - previous.bottom
                if startsColumn || gap > min(height, previous.height) * 0.65 { output.append("") }
            }
            output.append(joined(row))
            previous = (bottom, height)
            startsColumn = false
        }
    }
    return output.joined(separator: "\n")
}

/// The pieces of one row on one line: a space between parts of the same
/// phrase, a tab across a gap wide enough to be a column of its own, so a
/// table pasted into a spreadsheet keeps its cells.
private func joined(_ row: [RecognizedLine]) -> String {
    var text = row[0].text
    for (previous, next) in zip(row, row.dropFirst()) {
        let gap = next.rect.minX - previous.rect.maxX
        text += (gap > min(previous.rect.height, next.rect.height) * 2 ? "\t" : " ") + next.text
    }
    return text
}
