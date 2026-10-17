import Foundation

/// Reconstructs the bounded screen-reader panel, including incremental erases.
nonisolated enum ClaudeTerminalScreen {
    static func render(_ text: String) -> String? {
        let input = Array(text)
        let rowLimit = 2_048, columnLimit = 1_024
        var rows: [[String]] = [[]]
        var row = 0, column = 0, saved = (0, 0), index = 0

        func ensureRow() {
            while rows.count <= row { rows.append([]) }
        }
        func eraseLine(_ mode: Int) -> Bool {
            ensureRow()
            switch mode {
            case 0:
                if column < rows[row].count { rows[row].removeSubrange(column...) }
            case 1:
                let end = min(column + 1, rows[row].count)
                for position in 0..<end { rows[row][position] = " " }
            case 2: rows[row] = []
            default: return false
            }
            return true
        }

        while index < input.count {
            let character = input[index]
            index += 1
            switch character {
            case "\u{1B}":
                guard index < input.count else { return nil }
                let command = input[index]
                index += 1
                switch command {
                case "[":
                    let beginning = index
                    while index < input.count,
                          let value = input[index].asciiValue, !(0x40...0x7E).contains(value) {
                        guard (0x20...0x3F).contains(value) else { return nil }
                        index += 1
                    }
                    guard index < input.count else { return nil }
                    let final = input[index]
                    let parameters = String(input[beginning..<index])
                    index += 1
                    // Rendition, visibility, paste and synchronization modes do not move text.
                    if final == "m" { continue }
                    if final == "c" || (final == "q" && parameters == ">0")
                        || (final == "u" && ["?", "<"].contains(parameters)) { continue }
                    if final == "h" || final == "l" {
                        guard ["?25", "?2004", "?2026", "?2031", "?1000", "?1002", "?1003", "?1004", "?1006"].contains(parameters) else { return nil }
                        continue
                    }
                    if final == "q", parameters.hasSuffix(" ") { continue }
                    let pieces = parameters.split(separator: ";", omittingEmptySubsequences: false)
                    guard pieces.allSatisfy({ $0.isEmpty || $0.allSatisfy(\.isNumber) }) else { return nil }
                    let values = pieces.map { $0.isEmpty ? 0 : Int($0) ?? -1 }
                    guard values.allSatisfy({ (0...65_535).contains($0) }) else { return nil }
                    let first = values.first ?? 0
                    let amount = max(1, first)
                    switch final {
                    case "A": row = max(0, row - amount)
                    case "B": row += amount
                    case "C": column += amount
                    case "D": column = max(0, column - amount)
                    case "E": row += amount; column = 0
                    case "F": row = max(0, row - amount); column = 0
                    case "G": column = amount - 1
                    case "H", "f":
                        guard values.count <= 2 else { return nil }
                        row = amount - 1
                        column = max(1, values.count == 2 ? values[1] : 1) - 1
                    case "K": guard eraseLine(first) else { return nil }
                    case "J":
                        guard (0...2).contains(first) else { return nil }
                        ensureRow()
                        if first == 2 { rows = Array(repeating: [], count: row + 1) }
                        else if first == 0 {
                            guard eraseLine(0) else { return nil }
                            if row + 1 < rows.count { rows.removeSubrange((row + 1)...) }
                        } else {
                            for position in 0..<row { rows[position] = [] }
                            guard eraseLine(1) else { return nil }
                        }
                    case "s": saved = (row, column)
                    case "u": (row, column) = saved
                    case "r": guard parameters.isEmpty else { return nil }
                    default: return nil
                    }
                case "]":
                    var ended = false
                    while index < input.count {
                        if input[index] == "\u{07}" { index += 1; ended = true; break }
                        if input[index] == "\u{1B}", index + 1 < input.count, input[index + 1] == "\\" {
                            index += 2; ended = true; break
                        }
                        index += 1
                    }
                    guard ended else { return nil }
                case "7": saved = (row, column)
                case "8": (row, column) = saved
                case "(", ")":
                    guard index < input.count, input[index] == "B" else { return nil }
                    index += 1
                case "=", ">": break
                default: return nil
                }
            case "\r": column = 0
            case "\n", "\r\n": row += 1; column = 0
            case "\u{08}": column = max(0, column - 1)
            case "\t": column = (column / 8 + 1) * 8
            case "\u{00}", "\u{07}", "\u{0F}": break
            default:
                guard !character.unicodeScalars.contains(where: { $0.value < 0x20 || (0x7F...0x9F).contains($0.value) }) else { return nil }
                let width = cellWidth(character)
                guard column + width <= columnLimit else { return nil }
                ensureRow()
                while rows[row].count < column + width { rows[row].append(" ") }
                rows[row][column] = String(character)
                if width == 2 { rows[row][column + 1] = "" }
                column += width
            }
            guard row < rowLimit, column < columnLimit else { return nil }
        }
        return rows.map { $0.joined().replacingOccurrences(of: #" +$"#, with: "", options: .regularExpression) }.joined(separator: "\n")
    }

    private static func cellWidth(_ character: Character) -> Int {
        // ponytail: the English screen-reader panel uses narrow text and block bars;
        // account for common wide startup glyphs without a terminal dependency.
        character.unicodeScalars.contains {
            let value = $0.value
            return $0.properties.isEmojiPresentation || value == 0xFE0F
                || (0x1100...0x115F).contains(value) || (0x2E80...0xA4CF).contains(value)
                || (0xAC00...0xD7A3).contains(value) || (0xF900...0xFAFF).contains(value)
                || (0xFE10...0xFE19).contains(value) || (0xFE30...0xFE6F).contains(value)
                || (0xFF01...0xFF60).contains(value) || (0xFFE0...0xFFE6).contains(value)
                || (0x20000...0x3FFFD).contains(value)
        } ? 2 : 1
    }
}
