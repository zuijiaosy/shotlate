import CoreGraphics
import Foundation

/// Turns OCR lines back into the structure they came from: a table (as Markdown) or indented code.
public enum StructuredText {
    /// Lines sharing a baseline band form a row, left to right.
    static func rows(_ lines: [OCRLine]) -> [[OCRLine]] {
        var rows: [[OCRLine]] = []
        for line in lines.sorted(by: { $0.rect.midY < $1.rect.midY }) {
            if let i = rows.indices.last, let ref = rows[i].first,
               abs(line.rect.midY - ref.rect.midY) < min(line.rect.height, ref.rect.height) * 0.6 {
                rows[i].append(line)
            } else {
                rows.append([line])
            }
        }
        return rows.map { $0.sorted { $0.rect.minX < $1.rect.minX } }
    }

    /// Cells as a grid when the text looks like a table: at least two rows and two columns whose cells line up.
    public static func table(_ lines: [OCRLine]) -> [[String]]? {
        let rows = rows(lines)
        guard rows.count >= 2 else { return nil }
        let columns = columns(rows)
        guard columns.count >= 2 else { return nil }
        let grid = rows.map { row -> [String] in
            var cells = Array(repeating: "", count: columns.count)
            for cell in row {
                let column = columns.firstIndex { cell.rect.minX <= $0.upperBound && $0.lowerBound <= cell.rect.maxX } ?? 0
                cells[column] = cells[column].isEmpty ? cell.text : cells[column] + " " + cell.text
            }
            return cells
        }
        // Most rows must fill most columns.
        let filled = grid.map { $0.filter { !$0.isEmpty }.count }
        let fullRows = filled.filter { $0 >= max(2, columns.count - 1) }.count
        return Double(fullRows) / Double(grid.count) >= 0.6 ? grid : nil
    }

    /// Column spans: the stretches of x that some cell covers, split wherever no cell does. Cells of one column
    /// overlap whether they are left-aligned, right-aligned (numbers) or centered, so the empty bands between
    /// columns are what separates them, not where each cell starts.
    static func columns(_ rows: [[OCRLine]]) -> [ClosedRange<CGFloat>] {
        let cells = rows.enumerated().flatMap { r, row in row.map { (row: r, rect: $0.rect) } }
        let heights = cells.map(\.rect.height).sorted()
        // Boxes closer than this are one cell that OCR split, like "原始金额合计" and "（元）".
        let join = heights.isEmpty ? 0 : heights[heights.count / 2] * 0.3
        var columns: [(span: ClosedRange<CGFloat>, rows: Set<Int>)] = []
        for cell in cells.sorted(by: { $0.rect.minX < $1.rect.minX }) {
            if let last = columns.last, cell.rect.minX < last.span.upperBound + join {
                columns[columns.count - 1] = (last.span.lowerBound...max(last.span.upperBound, cell.rect.maxX), last.rows.union([cell.row]))
            } else {
                columns.append((cell.rect.minX...cell.rect.maxX, [cell.row]))
            }
        }
        // Neighbours that never share a row are one column aligned two ways, such as a left-aligned
        // header over right-aligned numbers.
        var i = 0
        while i + 1 < columns.count {
            if columns[i].rows.isDisjoint(with: columns[i + 1].rows) {
                columns[i] = (columns[i].span.lowerBound...columns[i + 1].span.upperBound, columns[i].rows.union(columns[i + 1].rows))
                columns.remove(at: i + 1)
            } else {
                i += 1
            }
        }
        return columns.map(\.span)
    }

    public static func markdown(_ grid: [[String]]) -> String {
        func row(_ cells: [String]) -> String {
            "| " + cells.map { $0.replacingOccurrences(of: "|", with: "\\|") }.joined(separator: " | ") + " |"
        }
        guard let header = grid.first else { return "" }
        var out = [row(header), row(header.map { _ in "---" })]
        out += grid.dropFirst().map(row)
        return out.joined(separator: "\n")
    }

    /// One line per row, with leading spaces rebuilt from how far each line starts from the leftmost one.
    public static func indented(_ lines: [OCRLine]) -> String {
        let rows = rows(lines)
        guard let left = rows.compactMap({ $0.first?.rect.minX }).min() else { return "" }
        // Typical character width: the text's width over its length, across all lines.
        let totalWidth = lines.reduce(0) { $0 + $1.rect.width }
        let totalChars = lines.reduce(0) { $0 + max(1, $1.text.count) }
        let charWidth = max(1, totalWidth / CGFloat(totalChars))
        return rows.map { row in
            let indent = Int(((row[0].rect.minX - left) / charWidth).rounded())
            return String(repeating: " ", count: max(0, indent)) + row.map(\.text).joined(separator: " ")
        }.joined(separator: "\n")
    }
}
