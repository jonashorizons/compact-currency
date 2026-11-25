import Foundation

public struct CurrencyInfo: Codable, Equatable, Sendable {
    public let isoCode: String
    public let name: String
    public let type: String

    enum CodingKeys: String, CodingKey { case isoCode = "iso_code", name, type }

    public init(isoCode: String, name: String, type: String = "currency") {
        self.isoCode = isoCode; self.name = name; self.type = type
    }

    public var flag: String {
        let preferred = ["EUR":"EU", "CHF":"CH", "USD":"US", "GBP":"GB", "AUD":"AU", "CAD":"CA",
                         "NZD":"NZ", "JPY":"JP", "THB":"TH", "VND":"VN", "IDR":"ID", "PHP":"PH",
                         "CNY":"CN", "HKD":"HK", "SGD":"SG", "MYR":"MY", "AED":"AE", "INR":"IN",
                         "KRW":"KR", "TWD":"TW", "SEK":"SE", "NOK":"NO", "DKK":"DK", "ZAR":"ZA"]
        let region = preferred[isoCode] ?? Locale.Region.isoRegions.first(where: {
            Locale(identifier: "en_\($0.identifier)").currency?.identifier == isoCode
        })?.identifier
        guard let region, region.count == 2 else { return "◌" }
        return region.unicodeScalars.compactMap { UnicodeScalar(127397 + $0.value) }.map(String.init).joined()
    }
}

public struct RateQuote: Codable, Equatable, Sendable {
    public let date: String
    public let base: String
    public let quote: String
    public let rate: Decimal

    public init(date: String, base: String = "USD", quote: String, rate: Decimal) {
        self.date = date; self.base = base; self.quote = quote; self.rate = rate
    }
}

public struct RateSnapshot: Codable, Equatable, Sendable {
    public let source: String
    public let fetchedAt: Date
    public let quotes: [String: RateQuote]

    public init(rows: [RateQuote], fetchedAt: Date = Date(), source: String = "Frankfurter") throws {
        guard !rows.isEmpty else { throw CurrencyError.invalidRates }
        var validated: [String: RateQuote] = [:]
        for row in rows {
            guard row.base == "USD", row.rate > 0, !row.rate.isNaN,
                  row.quote.count >= 3, row.date.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
                  validated[row.quote] == nil else { throw CurrencyError.invalidRates }
            validated[row.quote] = row
        }
        if let usd = validated["USD"], usd.rate != 1 { throw CurrencyError.invalidRates }
        if validated["USD"] == nil {
            validated["USD"] = RateQuote(date: rows.map(\.date).max()!, quote: "USD", rate: 1)
        }
        self.source = source; self.fetchedAt = fetchedAt; self.quotes = validated
    }

    public func amount(_ amount: Decimal, from source: String, to target: String) -> Decimal? {
        guard let from = quotes[source]?.rate, let to = quotes[target]?.rate,
              from > 0, to > 0, !amount.isNaN else { return nil }
        if source == target { return amount }
        let result = amount * to / from
        return result.isNaN ? nil : result
    }

    public func oldestQuoteDate(for currencies: [String]) -> String? {
        currencies.compactMap { quotes[$0]?.date }.min()
    }

    public func isRefreshDue(now: Date = Date(), interval: TimeInterval) -> Bool {
        now.timeIntervalSince(fetchedAt) >= max(3600, interval)
    }
}

public enum CurrencyError: Error, LocalizedError {
    case invalidRates
    case http(Int)
    case emptyResponse
    public var errorDescription: String? {
        switch self {
        case .invalidRates: return "The rate service returned an invalid rate table."
        case .http(let status): return "The rate service returned HTTP \(status)."
        case .emptyResponse: return "No exchange rates were returned."
        }
    }
}

public enum AmountParser {
    public static func parse(_ input: String) -> Decimal? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"[\s'’]"#, with: "", options: .regularExpression)
        if ["", "-", "+", ".", "-.", "+."].contains(text) { return 0 }
        if text.contains(",") && !text.contains(".") {
            let grouped = text.range(of: #"^[+-]?\d{1,3}(,\d{3})+$"#, options: .regularExpression) != nil
            text = grouped ? text.replacingOccurrences(of: ",", with: "") : text.replacingOccurrences(of: ",", with: ".")
        } else if text.contains(",") {
            guard text.range(of: #"^[+-]?\d{1,3}(,\d{3})+(\.\d*)?$"#, options: .regularExpression) != nil else { return nil }
            text = text.replacingOccurrences(of: ",", with: "")
        }
        guard text.range(of: #"^[+-]?(\d+(\.\d*)?|\.\d+)$"#, options: .regularExpression) != nil,
              let result = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), !result.isNaN,
              abs(result) <= Decimal(string: "100000000000")! else { return nil }
        return result
    }
}

public struct UserSettings: Codable, Equatable, Sendable {
    public var currencies = ["EUR", "CHF", "GBP", "USD", "CAD", "AUD", "JPY", "THB"]
    public var selectedCurrency = "CHF"
    public var anchorCurrency = "CHF"
    public var anchorAmount: Decimal = 1000
    public var decimals = 2
    public var refreshInterval: TimeInterval = 3600
    public var showFlags = true

    public init() {}

    public mutating func sanitize(available: Set<String>) {
        var seen = Set<String>()
        currencies = currencies.filter { available.contains($0) && seen.insert($0).inserted }
        if currencies.isEmpty { currencies = ["CHF", "USD", "EUR"].filter { available.contains($0) } }
        if currencies.isEmpty, let fallback = available.sorted().first { currencies = [fallback] }
        if !currencies.contains(selectedCurrency) { selectedCurrency = currencies.first ?? "USD" }
        if !available.contains(anchorCurrency) { anchorCurrency = selectedCurrency; anchorAmount = 1000 }
        if anchorAmount.isNaN || abs(anchorAmount) > Decimal(string: "100000000000")! { anchorAmount = 1000 }
        if ![0, 2, 4].contains(decimals) { decimals = 2 }
        if ![3600.0, 14400.0, 86400.0].contains(refreshInterval) { refreshInterval = 3600 }
    }
}

public struct RateClient: Sendable {
    public init() {}
    public func fetch() async throws -> RateSnapshot {
        let url = URL(string: "https://api.frankfurter.dev/v2/rates?base=USD")!
        var lastError: Error = CurrencyError.emptyResponse
        for attempt in 0..<3 {
            if attempt > 0 { try await Task.sleep(nanoseconds: UInt64(attempt == 1 ? 2 : 5) * 1_000_000_000) }
            do {
                var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200 else { throw CurrencyError.http(status) }
                let rows = try JSONDecoder().decode([RateQuote].self, from: data)
                return try RateSnapshot(rows: rows)
            } catch {
                lastError = error
                if case CurrencyError.http(let status) = error, status < 500 { throw error }
                if error is DecodingError { throw error }
                if case CurrencyError.invalidRates = error { throw error }
                if Task.isCancelled { throw CancellationError() }
            }
        }
        throw lastError
    }
}
