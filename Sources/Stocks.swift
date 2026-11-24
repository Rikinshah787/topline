import AppKit
import SwiftUI
import UserNotifications

// MARK: - Price formatting

/// "$187.42", "€92.10", "¥3,120", "$0.5123" — uses the quote's own currency.
@MainActor
func formatPrice(_ value: Double, _ currency: String) -> String {
    let key = "\(currency)|\(value < 1 ? 4 : 2)"
    if let f = PriceFormatters.cache[key] { return f.string(from: NSNumber(value: value)) ?? "" }
    let f = NumberFormatter()
    f.numberStyle = .currency
    f.currencyCode = currency
    if currency == "USD" { f.currencySymbol = "$" }
    f.minimumFractionDigits = value < 1 ? 4 : 2
    f.maximumFractionDigits = value < 1 ? 4 : 2
    PriceFormatters.cache[key] = f
    return f.string(from: NSNumber(value: value)) ?? ""
}

@MainActor private enum PriceFormatters { static var cache: [String: NumberFormatter] = [:] }

// MARK: - Yahoo Finance: symbol search + chart history

struct SymbolMatch: Identifiable, Hashable {
    let symbol: String
    let name: String
    let exchange: String
    let type: String
    var id: String { symbol }
}

private func yahooRequest(_ url: URL) -> URLRequest {
    var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
    req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
    return req
}

/// Finds tickers by company name or symbol ("apple", "nvda", "bitcoin", "sap").
func searchSymbols(_ query: String) async throws -> [SymbolMatch] {
    var c = URLComponents(string: "https://query1.finance.yahoo.com/v1/finance/search")!
    c.queryItems = [.init(name: "q", value: query), .init(name: "quotesCount", value: "10"),
                    .init(name: "newsCount", value: "0")]
    let (data, _) = try await URLSession.shared.data(for: yahooRequest(c.url!))
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let quotes = root["quotes"] as? [[String: Any]] else { return [] }
    return quotes.compactMap { q in
        guard let s = q["symbol"] as? String else { return nil }
        return SymbolMatch(symbol: s,
                           name: (q["longname"] as? String) ?? (q["shortname"] as? String) ?? s,
                           exchange: (q["exchDisp"] as? String) ?? "",
                           type: (q["typeDisp"] as? String) ?? "")
    }
}

enum ChartRange: String, CaseIterable, Identifiable {
    case day = "1D", week = "5D", month = "1M", sixMonths = "6M", year = "1Y", fiveYears = "5Y"
    var id: String { rawValue }
    var query: (range: String, interval: String) {
        switch self {
        case .day: ("1d", "5m")
        case .week: ("5d", "30m")
        case .month: ("1mo", "1d")
        case .sixMonths: ("6mo", "1d")
        case .year: ("1y", "1d")
        case .fiveYears: ("5y", "1wk")
        }
    }
}

struct ChartPoint: Hashable { let time: Date; let price: Double }

func fetchChart(_ symbol: String, _ range: ChartRange) async throws -> [ChartPoint] {
    let enc = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? symbol
    let q = range.query
    let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(enc)?interval=\(q.interval)&range=\(q.range)")!
    let (data, _) = try await URLSession.shared.data(for: yahooRequest(url))
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let result = ((root["chart"] as? [String: Any])?["result"] as? [[String: Any]])?.first,
          let ts = result["timestamp"] as? [Double],
          let closes = (((result["indicators"] as? [String: Any])?["quote"] as? [[String: Any]])?.first)?["close"] as? [Any]
    else { throw QuoteError.badResponse }
    return zip(ts, closes).compactMap { t, c in
        (c as? Double).map { ChartPoint(time: Date(timeIntervalSince1970: t), price: $0) }
    }
}

// MARK: - Price alerts

/// One-shot alerts: "tell me when NVDA goes above $200 / below $150". Stored in UserDefaults.
@MainActor
final class PriceAlerts: ObservableObject {
    static let shared = PriceAlerts()

    struct Alert: Codable, Equatable { var above: Double?; var below: Double? }

    @Published private(set) var alerts: [String: Alert] = [:]
    private let key = "priceAlerts"

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode([String: Alert].self, from: data) { alerts = saved }
    }

    func set(_ symbol: String, above: Double?, below: Double?) {
        alerts[symbol] = (above == nil && below == nil) ? nil : Alert(above: above, below: below)
        save()
        if above != nil || below != nil {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    func check(_ q: Quote) {
        guard var a = alerts[q.symbol] else { return }
        var fired: String?
        if let above = a.above, q.price >= above {
            fired = "\(q.symbol) is above \(formatPrice(above, q.currency))"; a.above = nil
        } else if let below = a.below, q.price <= below {
            fired = "\(q.symbol) is below \(formatPrice(below, q.currency))"; a.below = nil
        }
        guard let fired else { return }
        alerts[q.symbol] = (a.above == nil && a.below == nil) ? nil : a
        save()
        notify(title: fired, body: "\(q.name) is trading at \(formatPrice(q.price, q.currency)) (\(String(format: "%+.2f%%", q.changePct)) today).")
    }

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        NSSound(named: "Glass")?.play()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(alerts) { UserDefaults.standard.set(data, forKey: key) }
    }
}

// MARK: - Symbol picker window

/// A small search window: type a company or ticker, pick a result.
@MainActor
final class StockPicker {
    private static var window: NSWindow?

    static func pick(title: String = "Add a Stock", completion: @escaping (String) -> Void) {
        window?.close()
        let w = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 380),
                        styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = title
        w.isReleasedWhenClosed = false
        w.level = .modalPanel
        w.contentView = NSHostingView(rootView: StockSearchView { symbol in
            w.close()
            completion(symbol)
        } cancel: { w.close() })
        w.center()
        window = w
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }
}

struct StockSearchView: View {
    let pick: (String) -> Void
    let cancel: () -> Void
    @State private var query = ""
    @State private var results: [SymbolMatch] = []
    @State private var searching = false
    @State private var task: Task<Void, Never>?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Company or ticker — e.g. Apple, NVDA, Bitcoin, SAP", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { pick(results.first?.symbol ?? query.uppercased()) }
                .onChange(of: query) { _, q in search(q) }
            List(results) { r in
                Button { pick(r.symbol) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.symbol).fontWeight(.semibold)
                            Text(r.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text([r.exchange, r.type].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .overlay {
                if results.isEmpty {
                    Text(searching ? "Searching…" : query.isEmpty ? "Stocks, ETFs, indexes, crypto, currencies" : "No matches — press Return to use “\(query.uppercased())”")
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Add") { pick(results.first?.symbol ?? query.uppercased()) }
                    .keyboardShortcut(.defaultAction).disabled(query.isEmpty)
            }
        }
        .padding(16)
        .padding(.top, 20)
        .frame(width: 420, height: 380)
        .onAppear { focused = true }
    }

    private func search(_ q: String) {
        task?.cancel()
        let q = q.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { results = []; return }
        searching = true
        task = Task {
            try? await Task.sleep(for: .milliseconds(250))   // debounce typing
            guard !Task.isCancelled else { return }
            let r = (try? await searchSymbols(q)) ?? []
            guard !Task.isCancelled else { return }
            results = r
            searching = false
        }
    }
}

// MARK: - Charts

/// Tiny line chart for the bar.
struct Sparkline: View {
    let points: [Double]
    let color: Color

    var body: some View {
        GeometryReader { g in
            let pts = downsample(points, to: 60)
            if pts.count > 1, let lo = pts.min(), let hi = pts.max() {
                Path { p in
                    for (i, v) in pts.enumerated() {
                        let x = g.size.width * CGFloat(i) / CGFloat(pts.count - 1)
                        let y = hi == lo ? g.size.height / 2 : g.size.height * (1 - CGFloat((v - lo) / (hi - lo)))
                        i == 0 ? p.move(to: CGPoint(x: x, y: y)) : p.addLine(to: CGPoint(x: x, y: y))
                    }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

func downsample(_ v: [Double], to n: Int) -> [Double] {
    guard v.count > n, n > 1 else { return v }
    return (0..<n).map { v[Int(Double($0) * Double(v.count - 1) / Double(n - 1))] }
}

/// Interactive chart with range picker and hover read-out, for the stock popover.
struct PriceChart: View {
    let symbol: String
    let currency: String
    let previousClose: Double
    @State private var range: ChartRange = .day
    @State private var points: [ChartPoint] = []
    @State private var loading = false
    @State private var hover: ChartPoint?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("", selection: $range) {
                ForEach(ChartRange.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()

            ZStack(alignment: .topLeading) {
                chart.frame(height: 110)
                if let h = hover {
                    Text("\(formatPrice(h.price, currency))  ·  \(h.time.formatted(range == .day ? .dateTime.hour().minute() : .dateTime.month().day().year()))")
                        .font(.caption.monospacedDigit()).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.regularMaterial, in: Capsule())
                } else if let f = points.first, let l = points.last, range != .day {
                    let pct = (l.price - f.price) / f.price * 100
                    Text(String(format: "%+.2f%% over %@", pct, range.rawValue))
                        .font(.caption.monospacedDigit()).foregroundStyle(pct >= 0 ? .green : .red)
                }
            }
        }
        .task(id: range) { await load() }
    }

    private var chart: some View {
        GeometryReader { g in
            let prices = points.map(\.price)
            let base = range == .day ? previousClose : (prices.first ?? 0)
            if prices.count > 1, let lo0 = prices.min(), let hi0 = prices.max() {
                let lo = min(lo0, base), hi = max(hi0, base)
                let up = (prices.last ?? 0) >= base
                let color: Color = up ? .green : .red
                let y: (Double) -> CGFloat = { hi == lo ? g.size.height / 2 : g.size.height * (1 - CGFloat(($0 - lo) / (hi - lo))) }
                let x: (Int) -> CGFloat = { g.size.width * CGFloat($0) / CGFloat(prices.count - 1) }
                let line = Path { p in
                    for (i, v) in prices.enumerated() {
                        i == 0 ? p.move(to: CGPoint(x: x(i), y: y(v))) : p.addLine(to: CGPoint(x: x(i), y: y(v)))
                    }
                }
                ZStack {
                    Path { p in
                        p.addPath(line)
                        p.addLine(to: CGPoint(x: g.size.width, y: g.size.height))
                        p.addLine(to: CGPoint(x: 0, y: g.size.height))
                        p.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [color.opacity(0.28), color.opacity(0)], startPoint: .top, endPoint: .bottom))
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: y(base))); p.addLine(to: CGPoint(x: g.size.width, y: y(base)))
                    }
                    .stroke(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    line.stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                    if let h = hover, let i = points.firstIndex(of: h) {
                        Circle().fill(color).frame(width: 7, height: 7).position(x: x(i), y: y(h.price))
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    if case .active(let loc) = phase {
                        let i = Int((loc.x / g.size.width * CGFloat(prices.count - 1)).rounded())
                        hover = points[max(0, min(points.count - 1, i))]
                    } else { hover = nil }
                }
            } else {
                Text(loading ? "Loading chart…" : "No chart data").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func load() async {
        loading = true
        hover = nil
        points = (try? await fetchChart(symbol, range)) ?? []
        loading = false
    }
}
