import Foundation

public struct FormattedAmountEdit: Equatable {
    public let text: String
    public let normalized: String
    public let selection: NSRange
}

/// Adds grouping without rounding a number, dropping fractional zeros, or moving
/// the caret to the end. Existing display commas never become decimal commas as
/// digits are inserted or removed. A pasted decimal-comma amount is accepted too.
public enum AmountEditingFormatter {
    public static func format(_ input: String, selection: NSRange, previousText: String? = nil) -> FormattedAmountEdit? {
        guard input.utf16.count <= 128 else { return nil }
        let compact = input.filter { !$0.isWhitespace && $0 != "'" && $0 != "’" }
        let inserted = insertedText(input, replacing: previousText ?? "")
        let introducedComma = inserted.count > 1 && inserted.contains(",")
        let groupedInteger = compact.range(of: #"^[+-]?\d{1,3}(,\d{3})+$"#, options: .regularExpression) != nil
        let decimalComma = introducedComma && !compact.contains(".") && compact.filter { $0 == "," }.count == 1 && !groupedInteger
        if introducedComma && !decimalComma && AmountParser.parse(compact) == nil { return nil }

        func token(_ scalar: UnicodeScalar) -> String? {
            if scalar == "," { return decimalComma ? "." : nil }
            if CharacterSet.whitespacesAndNewlines.contains(scalar) || scalar == "'" || scalar == "’" { return nil }
            return String(scalar)
        }
        let normalized = input.unicodeScalars.compactMap(token).joined()
        guard AmountParser.parse(normalized) != nil else { return nil }
        let hasSign = normalized.first == "-" || normalized.first == "+"
        let sign = hasSign ? String(normalized.prefix(1)) : ""
        let unsigned = hasSign ? String(normalized.dropFirst()) : normalized
        let parts = unsigned.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let integer = Array(String(parts.first ?? ""))
        var grouped = ""
        for (index, digit) in integer.enumerated() {
            if index > 0 && (integer.count - index).isMultiple(of: 3) { grouped.append(",") }
            grouped.append(digit)
        }
        let output = sign + grouped + (parts.count == 2 ? "." + String(parts[1]) : "")

        func logicalOffset(_ utf16Offset: Int) -> Int {
            var original = 0, logical = 0
            for scalar in input.unicodeScalars {
                let length = scalar.utf16.count
                if original + length > utf16Offset { break }
                original += length
                if token(scalar) != nil { logical += 1 }
            }
            return logical
        }
        func displayOffset(_ logicalOffset: Int) -> Int {
            if logicalOffset <= 0 { return 0 }
            var logical = 0, offset = 0
            for scalar in output.unicodeScalars {
                offset += scalar.utf16.count
                if scalar != "," { logical += 1 }
                if logical == logicalOffset { return offset }
            }
            return output.utf16.count
        }
        let start = selection.location == NSNotFound ? input.utf16.count : min(selection.location, input.utf16.count)
        let end = min(start + min(selection.length, input.utf16.count - start), input.utf16.count)
        let displayStart = displayOffset(logicalOffset(start))
        let displayEnd = displayOffset(logicalOffset(end))
        return FormattedAmountEdit(text: output, normalized: normalized,
                                   selection: NSRange(location: displayStart, length: max(0, displayEnd - displayStart)))
    }

    private static func insertedText(_ current: String, replacing previous: String) -> String {
        let next = Array(current), old = Array(previous)
        var prefix = 0
        while prefix < min(next.count, old.count) && next[prefix] == old[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(next.count - prefix, old.count - prefix) && next[next.count - suffix - 1] == old[old.count - suffix - 1] { suffix += 1 }
        return String(next[prefix..<(next.count - suffix)])
    }
}
