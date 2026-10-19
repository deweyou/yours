import SwiftUI

/// A Markdown table is rectangular, with a required header and single-line cells.
struct TableData: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    var rows: [[String]]
    var alignments: [TableAlignment]

    init(id: UUID = UUID(), rows: [[String]] = [["", ""], ["", ""]], alignments: [TableAlignment] = [.left, .left]) {
        self.id = id
        let count = max(1, rows.map(\.count).max() ?? 1)
        self.rows = (rows.isEmpty ? [[""]] : rows).map { $0 + Array(repeating: "", count: count - $0.count) }
        self.alignments = (0..<count).map { $0 < alignments.count ? alignments[$0] : .left }
    }

    private enum CodingKeys: String, CodingKey { case id, rows, alignments }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        rows = try container.decode([[String]].self, forKey: .rows)
        alignments = try container.decode([TableAlignment].self, forKey: .alignments)
        guard !rows.isEmpty, !alignments.isEmpty,
            rows.allSatisfy({ $0.count == alignments.count })
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .rows, in: container, debugDescription: "Table rows must match the column count.")
        }
    }

    mutating func insertRow(after row: Int) {
        rows.insert(Array(repeating: "", count: alignments.count), at: min(rows.count, max(1, row + 1)))
    }

    mutating func removeRow(at row: Int) {
        guard rows.count > 1, rows.indices.contains(row) else { return }
        rows.remove(at: row)
    }

    mutating func insertColumn(after column: Int) {
        let index = min(alignments.count, max(0, column + 1))
        alignments.insert(.left, at: index)
        for row in rows.indices { rows[row].insert("", at: index) }
    }

    mutating func removeColumn(at column: Int) {
        guard alignments.count > 1, alignments.indices.contains(column) else { return }
        alignments.remove(at: column)
        for row in rows.indices { rows[row].remove(at: column) }
    }

    var attributedText: AttributedString {
        var text = AttributedString("\u{FFFC}")
        text[TableAttribute.self] = self
        text[ParagraphStyleAttribute.self] = "table"
        text.font = .body
        return text
    }

    var plainText: String { rows.map { $0.joined(separator: "\t") }.joined(separator: "\n") }

    var markdown: String {
        func line(_ cells: [String]) -> String { "| " + cells.joined(separator: " | ") + " |" }
        let content = rows.map { row in line(row.map(Self.escapeCell)) }
        let divider = line(alignments.map { $0 == .center ? ":---:" : $0 == .right ? "---:" : "---" })
        return ([content[0], divider] + content.dropFirst()).joined(separator: "\n")
    }

    /// Only consumes a table when the delimiter row exactly matches its header.
    static func parse(lines: [String], at start: Int) -> (table: TableData, count: Int)? {
        guard start + 1 < lines.count, lines[start].contains("|"),
            let header = splitRow(lines[start]), let delimiters = splitRow(lines[start + 1]),
            header.count == delimiters.count
        else { return nil }
        var alignments: [TableAlignment] = []
        for delimiter in delimiters {
            guard delimiter.range(of: #"^:?-{3,}:?$"#, options: .regularExpression) != nil else { return nil }
            alignments.append(delimiter.hasSuffix(":") ? (delimiter.hasPrefix(":") ? .center : .right) : .left)
        }
        var rows = [header]
        var index = start + 2
        while index < lines.count, lines[index].contains("|"), let row = splitRow(lines[index]), row.count == header.count {
            rows.append(row)
            index += 1
        }
        return (TableData(rows: rows, alignments: alignments), index - start)
    }

    private static func splitRow(_ source: String) -> [String]? {
        let line = source.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return nil }
        var cells: [String] = []
        var cell = ""
        var escaped = false
        for character in line {
            if escaped {
                if character != "|" && character != "\\" { cell.append("\\") }
                cell.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                cells.append(cell)
                cell = ""
            } else {
                cell.append(character)
            }
        }
        if escaped { cell.append("\\") }
        cells.append(cell)
        if line.hasPrefix("|") { cells.removeFirst() }
        if cells.last == "", line.hasSuffix("|") { cells.removeLast() }
        return cells.isEmpty ? nil : cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func escapeCell(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    static func plainText(in text: AttributedString) -> String {
        text.runs.map { run in
            run[TableAttribute.self]?.plainText ?? run[RenderedContentAttribute.self]?.source ?? String(text[run.range].characters)
        }.joined()
    }
}

enum TableAlignment: String, Codable, Hashable, Sendable { case left, center, right }

enum TableAttribute: CodableAttributedStringKey {
    typealias Value = TableData
    static let name = "yours.table"
}
