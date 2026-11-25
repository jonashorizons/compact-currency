import XCTest
@testable import CurrencyCore

final class AmountEditingFormatterTests: XCTestCase {
    func testGroupingOnEachKeystrokeNeverChangesTheAmount() throws {
        var text = ""
        for (index, digit) in "1234567890".enumerated() {
            let next = text + String(digit)
            let edit = try XCTUnwrap(AmountEditingFormatter.format(next,
                selection: NSRange(location: next.utf16.count, length: 0), previousText: text))
            text = edit.text
            XCTAssertEqual(edit.normalized, String("1234567890".prefix(index + 1)))
            XCTAssertEqual(edit.selection, NSRange(location: text.utf16.count, length: 0))
        }
        XCTAssertEqual(text, "1,234,567,890")
    }

    func testInsertionInTheMiddleKeepsTheLogicalCaret() throws {
        let edit = try XCTUnwrap(AmountEditingFormatter.format("1290,345", selection: NSRange(location: 4, length: 0), previousText: "129,345"))
        XCTAssertEqual(edit.text, "1,290,345")
        XCTAssertEqual(edit.normalized, "1290345")
        XCTAssertEqual(edit.selection.location, 5)
    }

    func testDeletingAGroupingCommaDoesNotTrapBackspace() throws {
        let edit = try XCTUnwrap(AmountEditingFormatter.format("12345", selection: NSRange(location: 2, length: 0), previousText: "12,345"))
        XCTAssertEqual(edit.text, "12,345")
        XCTAssertEqual(edit.selection.location, 2)
        let second = try XCTUnwrap(AmountEditingFormatter.format("1,345", selection: NSRange(location: 1, length: 0), previousText: edit.text))
        XCTAssertEqual(second.normalized, "1345")
        XCTAssertEqual(second.selection.location, 1)
    }

    func testDecimalPointTrailingZerosAndSignArePreserved() throws {
        for (input, expected) in [("12345.", "12,345."), ("12345.00", "12,345.00"),
                                  ("-12345.0040", "-12,345.0040"), (".50", ".50"), ("-", "-")] {
            let edit = try XCTUnwrap(AmountEditingFormatter.format(input, selection: NSRange(location: input.utf16.count, length: 0)))
            XCTAssertEqual(edit.text, expected)
            XCTAssertEqual(edit.selection.location, expected.utf16.count)
        }
    }

    func testPastedFormatsAreUnambiguousAndKeepFractionalDigits() throws {
        for input in ["1234,56", "1,234.56", "1'234.56", "1’234.56", "1 234.56"] {
            let edit = try XCTUnwrap(AmountEditingFormatter.format(input,
                selection: NSRange(location: input.utf16.count, length: 0), previousText: "1,000.00"))
            XCTAssertEqual(edit.text, "1,234.56", input)
            XCTAssertEqual(AmountParser.parse(edit.normalized), Decimal(string: "1234.56"), input)
        }
        let grouped = try XCTUnwrap(AmountEditingFormatter.format("1,000", selection: NSRange(location: 5, length: 0)))
        XCTAssertEqual(AmountParser.parse(grouped.normalized), 1000)
    }

    func testInvalidOrOutOfRangeInputIsNotReinterpreted() {
        for input in ["oops", "12,34.56", "1,23,45", "1.2.3", "100000000001"] {
            XCTAssertNil(AmountEditingFormatter.format(input, selection: NSRange(location: input.utf16.count, length: 0)), input)
        }
    }
}
