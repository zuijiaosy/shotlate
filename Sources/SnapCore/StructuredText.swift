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
        // Column starts: left edges that recur across rows.
        var starts: [CGFloat] = []
        for cell in rows.flatMap({ $0 }).sorted(by: { $0.rect.minX < $1.rect.minX }) {
            if let last = starts.last, cell.rect.minX - last < 14 { continue }
            starts.append(cell.rect.minX)
        }
        guard starts.count >= 2 else { return nil }
        var grid = rows.map { row -> [String] in
            var cells = Array(repeating: "", count: starts.count)
            for cell in row {
                let column = starts.lastIndex { $0 <= cell.rect.minX + 14 } ?? 0
                cells[column] = cells[column].isEmpty ? cell.text : cells[column] + " " + cell.text
            }
            return cells
        }
        // Drop columns that are empty everywhere, then require most rows to fill most columns.
        let used = starts.indices.filter { c in grid.contains { !$0[c].isEmpty } }
        grid = grid.map { row in used.map { row[$0] } }
        guard used.count >= 2 else { return nil }
        let filled = grid.map { $0.filter { !$0.isEmpty }.count }
        let fullRows = filled.filter { $0 >= max(2, used.count - 1) }.count
        return Double(fullRows) / Double(grid.count) >= 0.6 ? grid : nil
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
