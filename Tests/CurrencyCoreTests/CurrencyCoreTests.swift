import XCTest
@testable import CurrencyCore

final class CurrencyCoreTests: XCTestCase {
    private func decimal(_ value: String) -> Decimal { Decimal(string: value)! }
    private func table(fetchedAt: Date = Date()) throws -> RateSnapshot {
        try RateSnapshot(rows: [
            RateQuote(date: "2026-11-20", quote: "USD", rate: 1),
            RateQuote(date: "2026-11-20", quote: "CHF", rate: decimal("0.88")),
            RateQuote(date: "2026-11-19", quote: "EUR", rate: decimal("0.92")),
            RateQuote(date: "2026-11-20", quote: "JPY", rate: decimal("153.5"))
        ], fetchedAt: fetchedAt)
    }

    func testInputFormatsAndIntermediateValues() {
        for text in ["1,234.56", "1234.56", "1'234.56", "1’234.56", "1 234.56", "1234,56"] {
            XCTAssertEqual(AmountParser.parse(text), decimal("1234.56"), text)
        }
        XCTAssertEqual(AmountParser.parse("1,000"), 1000)
        XCTAssertEqual(AmountParser.parse(".25"), decimal("0.25"))
        XCTAssertEqual(AmountParser.parse("-5.2"), decimal("-5.2"))
        XCTAssertEqual(AmountParser.parse(""), 0)
        XCTAssertEqual(AmountParser.parse("-"), 0)
        for text in ["hello", "1.2.3", "1,2,3", "12,34.5", "NaN", "1e6", "100000000001"] {
            XCTAssertNil(AmountParser.parse(text), text)
        }
    }

    func testCrossRatesUseFullPrecisionAndPreserveTheSourceAmount() throws {
        let rates = try table()
        XCTAssertEqual(rates.amount(1100, from: "CHF", to: "EUR"), 1150)
        XCTAssertEqual(rates.amount(1100, from: "CHF", to: "JPY"), 191875)
        XCTAssertEqual(rates.amount(decimal("123.456789"), from: "CHF", to: "CHF"), decimal("123.456789"))
        let precise = decimal("1234567890.1234567890123456789012345678")
        XCTAssertEqual(rates.amount(precise, from: "CHF", to: "CHF"), precise)
        XCTAssertNil(rates.amount(5, from: "BAD", to: "EUR"))
        XCTAssertNil(rates.amount(5, from: "CHF", to: "BAD"))
    }

    func testInvalidTablesNeverReplaceUsableRates() {
        XCTAssertThrowsError(try RateSnapshot(rows: []))
        XCTAssertThrowsError(try RateSnapshot(rows: [RateQuote(date: "2026-11-20", quote: "CHF", rate: 0)]))
        XCTAssertThrowsError(try RateSnapshot(rows: [RateQuote(date: "2026-11-20", quote: "USD", rate: 2)]))
        XCTAssertThrowsError(try RateSnapshot(rows: [RateQuote(date: "bad", quote: "CHF", rate: 1)]))
        XCTAssertThrowsError(try RateSnapshot(rows: [RateQuote(date: "2026-11-20", base: "EUR", quote: "CHF", rate: 1)]))
        let duplicate = RateQuote(date: "2026-11-20", quote: "CHF", rate: 1)
        XCTAssertThrowsError(try RateSnapshot(rows: [duplicate, duplicate]))
    }

    func testRefreshIntervalAndQuoteDateAreIndependent() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fresh = try table(fetchedAt: now.addingTimeInterval(-3599))
        XCTAssertFalse(fresh.isRefreshDue(now: now, interval: 3600))
        XCTAssertTrue(fresh.isRefreshDue(now: now.addingTimeInterval(1), interval: 3600))
        XCTAssertFalse(fresh.isRefreshDue(now: now, interval: 14400))
        XCTAssertEqual(fresh.oldestQuoteDate(for: ["CHF", "EUR"]), "2026-11-19")
        XCTAssertEqual(fresh.oldestQuoteDate(for: ["CHF", "JPY"]), "2026-11-20")
    }

    func testCacheRoundTripKeepsDecimalPrecision() throws {
        let original = try table()
        let restored = try JSONDecoder().decode(RateSnapshot.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(restored, original)
        XCTAssertEqual(restored.amount(1100, from: "CHF", to: "EUR"), 1150)
    }

    func testCorruptPreferencesAreRepairedWithoutAnEmptyList() {
        var settings = UserSettings()
        settings.currencies = ["BAD", "CHF", "CHF"]
        settings.selectedCurrency = "BAD"; settings.anchorCurrency = "BAD"
        settings.decimals = 99; settings.refreshInterval = -100
        settings.sanitize(available: ["CHF", "USD"])
        XCTAssertEqual(settings.currencies, ["CHF"])
        XCTAssertEqual(settings.selectedCurrency, "CHF")
        XCTAssertEqual(settings.anchorCurrency, "CHF")
        XCTAssertEqual(settings.decimals, 2)
        XCTAssertEqual(settings.refreshInterval, 3600)
        settings.currencies = []
        settings.sanitize(available: ["JPY"])
        XCTAssertEqual(settings.currencies, ["JPY"])
    }

    func testLiveProviderSchema() async throws {
        guard ProcessInfo.processInfo.environment["CURRENCY_LIVE_TEST"] == "1" else { throw XCTSkip("Opt-in live API verification") }
        let snapshot = try await RateClient().fetch()
        for code in ["CHF", "EUR", "GBP", "USD", "JPY", "THB", "VND", "IDR"] {
            XCTAssertGreaterThan(try XCTUnwrap(snapshot.quotes[code]?.rate), 0)
        }
        XCTAssertEqual(snapshot.source, "Frankfurter")
    }
}
