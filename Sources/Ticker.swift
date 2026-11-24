import AppKit

// MARK: - Quote model / fetching

struct Quote {
    let symbol: String
    let name: String
    let exchange: String
    let price: Double
    let previousClose: Double
    let dayHigh: Double?
    let dayLow: Double?
    let volume: Double?
    let time: Date
    let isExtendedHours: Bool
    var currency = "USD"
    /// Today's prices (1-minute bars, incl. pre/post market) for the mini chart.
    var points: [Double] = []
    /// nil = unknown; otherwise whether the regular session is open right now.
    var marketOpen: Bool?

    var change: Double { price - previousClose }
    var changePct: Double { previousClose == 0 ? 0 : change / previousClose * 100 }
}

enum QuoteError: Error { case badResponse }

func fetchQuote(_ symbol: String) async throws -> Quote {
    let encoded = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? symbol
    let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(encoded)?interval=1m&range=1d&includePrePost=true")!
    var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
    req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
    let (data, _) = try await URLSession.shared.data(for: req)

    guard
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        let chart = root["chart"] as? [String: Any],
        let result = (chart["result"] as? [[String: Any]])?.first,
        let meta = result["meta"] as? [String: Any],
        let regPrice = meta["regularMarketPrice"] as? Double
    else { throw QuoteError.badResponse }

    let prevClose = (meta["chartPreviousClose"] as? Double) ?? (meta["previousClose"] as? Double) ?? regPrice
    let regTime = (meta["regularMarketTime"] as? Double) ?? Date().timeIntervalSince1970

    // Use the latest extended-hours bar if it's newer than the regular-market print.
    var price = regPrice
    var time = regTime
    var extended = false
    var points: [Double] = []
    if let timestamps = result["timestamp"] as? [Double],
       let indicators = result["indicators"] as? [String: Any],
       let q = (indicators["quote"] as? [[String: Any]])?.first,
       let closes = q["close"] as? [Any] {
        points = closes.compactMap { $0 as? Double }
        for i in stride(from: min(timestamps.count, closes.count) - 1, through: 0, by: -1) {
            if let c = closes[i] as? Double {
                if timestamps[i] > regTime + 60 {
                    price = c; time = timestamps[i]; extended = true
                }
                break
            }
        }
    }

    return Quote(
        symbol: symbol,
        name: (meta["longName"] as? String) ?? (meta["shortName"] as? String) ?? symbol,
        exchange: (meta["fullExchangeName"] as? String) ?? (meta["exchangeName"] as? String) ?? "",
        price: price,
        previousClose: prevClose,
        dayHigh: meta["regularMarketDayHigh"] as? Double,
        dayLow: meta["regularMarketDayLow"] as? Double,
        volume: meta["regularMarketVolume"] as? Double,
        time: Date(timeIntervalSince1970: time),
        isExtendedHours: extended,
        currency: (meta["currency"] as? String) ?? "USD",
        points: points,
        marketOpen: {
            guard let period = meta["currentTradingPeriod"] as? [String: Any],
                  let reg = period["regular"] as? [String: Any],
                  let start = reg["start"] as? Double, let end = reg["end"] as? Double else { return nil }
            let now = Date().timeIntervalSince1970
            return now >= start && now < end
        }()
    )
}

// MARK: - Menu bar ticker

@MainActor
final class TickerController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var timer: Timer?
    private var currentSymbol = ""
    private var currentInterval: Double = 0
    private var lastQuote: Quote?
    private var flashUntil = Date.distantPast
    private let openSettings: () -> Void

    private let headerItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let priceItem = NSMenuItem(title: "Loading…", action: nil, keyEquivalent: "")
    private let changeItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let rangeItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let volumeItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let updatedItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    init(openSettings: @escaping () -> Void) {
        self.openSettings = openSettings
        super.init()
        item.autosaveName = "ticker"

        menu.addItem(headerItem)
        menu.addItem(.separator())
        [priceItem, changeItem, rangeItem, volumeItem, updatedItem].forEach { menu.addItem($0) }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Refresh Now", action: #selector(refresh), keyEquivalent: "r").target = self
        menu.addItem(withTitle: "Open in Yahoo Finance", action: #selector(openWeb), keyEquivalent: "o").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(settings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu

        applyPrefs()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.applyPrefs() } }   // deferred: never re-enter layout
        }
    }

    private func applyPrefs() {
        let s = Prefs.symbol
        if !s.isEmpty, s != currentSymbol {
            currentSymbol = s
            lastQuote = nil
            item.button?.title = "\(s) …"
            headerItem.title = s
            priceItem.title = "Loading…"
            refresh()
        }
        let interval = Prefs.refreshInterval
        if interval != currentInterval {
            currentInterval = interval
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            timer?.tolerance = 1
        }
        if let q = lastQuote { render(q) }
    }

    @objc private func refresh() {
        let symbol = currentSymbol
        Task { @MainActor in
            do {
                let q = try await fetchQuote(symbol)
                guard q.symbol == self.currentSymbol else { return }   // symbol changed meanwhile
                if let old = self.lastQuote, old.price != q.price, Prefs.flashOnChange {
                    self.flashUntil = Date().addingTimeInterval(0.8)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) {
                        MainActor.assumeIsolated { if let q = self.lastQuote { self.render(q) } }
                    }
                }
                self.lastQuote = q
                self.render(q)
            } catch {
                if self.lastQuote == nil { self.item.button?.title = "\(symbol) ?" }
                self.updatedItem.title = "⚠︎ Update failed — check the symbol or connection"
            }
        }
    }

    private func render(_ q: Quote) {
        let up = q.change >= 0
        let arrow = up ? "▲" : "▼"
        let color: NSColor = up ? .systemGreen : .systemRed
        let pct = String(format: "%@%.2f%%", up ? "+" : "", q.changePct)
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        let flashing = Date() < flashUntil

        var base: [NSAttributedString.Key: Any] = [.font: font]
        if flashing { base[.backgroundColor] = color.withAlphaComponent(0.35) }

        let title = NSMutableAttributedString(
            string: (Prefs.showSymbol ? "\(q.symbol) " : "") + formatPrice(q.price, q.currency),
            attributes: base)
        if Prefs.showPercent {
            var attrs = base
            if Prefs.colorize { attrs[.foregroundColor] = color }
            title.append(NSAttributedString(string: " \(arrow)\(pct)", attributes: attrs))
        }
        item.button?.attributedTitle = title

        headerItem.title = q.exchange.isEmpty ? "\(q.name) (\(q.symbol))" : "\(q.name) (\(q.exchange): \(q.symbol))"
        priceItem.title = "Price: " + formatPrice(q.price, q.currency) + (q.isExtendedHours ? "  (extended hours)" : "")
        changeItem.title = "Change: \(up ? "+" : "-")\(formatPrice(abs(q.change), q.currency)) (\(pct))  ·  Prev close \(formatPrice(q.previousClose, q.currency))"
        if let lo = q.dayLow, let hi = q.dayHigh {
            rangeItem.title = "Day range: \(formatPrice(lo, q.currency)) – \(formatPrice(hi, q.currency))"
        }
        if let v = q.volume {
            volumeItem.title = "Volume: " + NumberFormatter.localizedString(from: NSNumber(value: v), number: .decimal)
        }
        let df = DateFormatter(); df.timeStyle = .medium; df.dateStyle = .none
        updatedItem.title = "Last trade: \(df.string(from: q.time))  ·  checked \(df.string(from: Date()))"
    }

    @objc private func openWeb() {
        NSWorkspace.shared.open(URL(string: "https://finance.yahoo.com/quote/\(currentSymbol)")!)
    }

    @objc private func settings() { openSettings() }

    func teardown() {
        timer?.invalidate()
        NSStatusBar.system.removeStatusItem(item)
    }
}
