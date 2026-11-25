import AppKit
import CurrencyCore
import ServiceManagement

@MainActor
final class AppModel {
    enum Change { case values, selection, structure, status }
    var onChange: ((Change) -> Void)?
    private(set) var settings: UserSettings
    private(set) var snapshot: RateSnapshot
    let catalog: [CurrencyInfo]
    private(set) var isLoading = false
    private(set) var networkError: String?
    private(set) var storageError: String?
    private var lastAttempt: Date?
    private var refreshTask: Task<Void, Never>?
    private var timer: Timer?
    private var saveWork: DispatchWorkItem?
    private let directory: URL
    private let settingsURL: URL
    private let ratesURL: URL
    private let client = RateClient()

    init(directory: URL? = nil) throws {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Compact Currency", isDirectory: true)
        settingsURL = self.directory.appendingPathComponent("settings.json")
        ratesURL = self.directory.appendingPathComponent("rates.json")
        let decoder = JSONDecoder()
        catalog = try decoder.decode([CurrencyInfo].self, from: Data(contentsOf: Bundle.module.url(forResource: "currencies", withExtension: "json")!))
            .filter { $0.type == "currency" }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let rows = try decoder.decode([RateQuote].self, from: Data(contentsOf: Bundle.module.url(forResource: "seed-rates", withExtension: "json")!))
        let metadata = try decoder.decode([String: String].self, from: Data(contentsOf: Bundle.module.url(forResource: "seed-metadata", withExtension: "json")!))
        let dateParser = ISO8601DateFormatter()
        dateParser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let seed = try RateSnapshot(rows: rows, fetchedAt: metadata["fetchedAt"].flatMap(dateParser.date(from:)) ?? .distantPast)
        if let data = try? Data(contentsOf: ratesURL), let cached = try? decoder.decode(RateSnapshot.self, from: data),
           let validated = try? RateSnapshot(rows: Array(cached.quotes.values), fetchedAt: cached.fetchedAt, source: cached.source) {
            snapshot = validated
        } else { snapshot = seed }
        if let data = try? Data(contentsOf: settingsURL), let restored = try? decoder.decode(UserSettings.self, from: data) {
            settings = restored
        } else { settings = UserSettings() }
        settings.sanitize(available: Set(catalog.map(\.isoCode)).intersection(snapshot.quotes.keys))
    }

    var selectedCode: String { settings.selectedCurrency }
    var currencies: [String] { settings.currencies }
    var loginEnabled: Bool { SMAppService.mainApp.status == .enabled }
    var loginNeedsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshIfNeeded() }
        }
        refreshIfNeeded()
    }

    func currency(_ code: String) -> CurrencyInfo {
        catalog.first { $0.isoCode == code } ?? CurrencyInfo(isoCode: code, name: code)
    }

    func amount(_ code: String) -> Decimal? {
        snapshot.amount(settings.anchorAmount, from: settings.anchorCurrency, to: code)
    }

    func formatted(_ code: String) -> String {
        guard let amount = amount(code) else { return "—" }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = settings.decimals
        formatter.maximumFractionDigits = settings.decimals
        formatter.roundingMode = .halfUp
        return formatter.string(from: NSDecimalNumber(decimal: amount)) ?? "—"
    }

    func select(_ code: String) {
        guard settings.currencies.contains(code) else { return }
        settings.selectedCurrency = code
        scheduleSave(); onChange?(.selection)
    }

    func moveSelection(_ delta: Int) {
        guard let index = settings.currencies.firstIndex(of: selectedCode), !currencies.isEmpty else { return }
        select(currencies[(index + delta + currencies.count) % currencies.count])
    }

    @discardableResult
    func enter(_ text: String, currency: String) -> Bool {
        guard let amount = AmountParser.parse(text), snapshot.quotes[currency] != nil else { return false }
        settings.anchorCurrency = currency; settings.anchorAmount = amount; settings.selectedCurrency = currency
        scheduleSave(); onChange?(.values)
        return true
    }

    func toggle(_ code: String, enabled: Bool) {
        guard snapshot.quotes[code] != nil else { return }
        if enabled {
            if !settings.currencies.contains(code) { settings.currencies.append(code) }
        } else if currencies.count > 1 {
            settings.currencies.removeAll { $0 == code }
            if selectedCode == code { settings.selectedCurrency = currencies[0] }
        }
        scheduleSave(); onChange?(.structure)
    }

    func reorder(_ code: String, delta: Int) {
        guard let index = currencies.firstIndex(of: code), currencies.indices.contains(index + delta) else { return }
        settings.currencies.swapAt(index, index + delta)
        scheduleSave(); onChange?(.structure)
    }

    func setDecimals(_ count: Int) {
        guard [0,2,4].contains(count) else { return }
        settings.decimals = count; scheduleSave(); onChange?(.structure)
    }

    func setInterval(_ interval: TimeInterval) {
        guard [3600.0,14400.0,86400.0].contains(interval) else { return }
        settings.refreshInterval = interval; scheduleSave(); onChange?(.status)
    }

    func setFlags(_ enabled: Bool) {
        settings.showFlags = enabled; scheduleSave(); onChange?(.structure)
    }

    func setLogin(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() }
        else { try SMAppService.mainApp.unregister() }
        onChange?(.status)
    }

    func refreshIfNeeded() {
        guard snapshot.isRefreshDue(interval: settings.refreshInterval) else { return }
        if networkError != nil, let lastAttempt, Date().timeIntervalSince(lastAttempt) < 900 { return }
        refresh()
    }

    func refresh() {
        guard !isLoading else { return }
        if let lastAttempt, Date().timeIntervalSince(lastAttempt) < 10 { return }
        lastAttempt = Date(); isLoading = true; onChange?(.status)
        refreshTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isLoading = false; self.onChange?(.status) }
            do {
                let fresh = try await client.fetch()
                guard Set(currencies + [settings.anchorCurrency]).isSubset(of: Set(fresh.quotes.keys)) else { throw CurrencyError.invalidRates }
                snapshot = fresh; networkError = nil
                do { try write(fresh, to: ratesURL) }
                catch { storageError = "Could not save rates: \(error.localizedDescription)" }
                onChange?(.values)
            } catch is CancellationError {
                return
            } catch {
                networkError = error.localizedDescription
            }
        }
    }

    var quoteDate: String {
        snapshot.oldestQuoteDate(for: currencies + [settings.anchorCurrency]) ?? "Unknown date"
    }

    var footerText: String {
        if isLoading { return "Updating rates…" }
        if networkError != nil { return "Cached · \(quoteDate)" }
        return "Frankfurter · \(quoteDate)"
    }

    var details: String {
        let dates = currencies.compactMap { code -> String? in
            guard let quote = snapshot.quotes[code] else { return nil }
            return "\(code): \(quote.date)"
        }.joined(separator: "\n")
        let downloaded = DateFormatter.localizedString(from: snapshot.fetchedAt, dateStyle: .medium, timeStyle: .short)
        return "Daily reference rates from Frankfurter.\n\(dates)\nDownloaded: \(downloaded)" +
            (networkError.map { "\nLast update failed: \($0)" } ?? "") +
            (storageError.map { "\n\($0)" } ?? "")
    }

    func flush() {
        saveWork?.cancel(); saveWork = nil
        do { try write(settings, to: settingsURL) }
        catch { storageError = "Could not save preferences: \(error.localizedDescription)"; onChange?(.status) }
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}
