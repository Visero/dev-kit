import Foundation

// MARK: - Model
/// One real-time A-share / index snapshot, parsed from the Tencent quote feed.
/// Numbers stay as parsed text values; no currency conversion, no persistence.
struct StockQuote: Equatable, Sendable, Identifiable {
    let symbol: String          // "sh600519"
    let name: String
    let price: Double
    let prevClose: Double
    let open: Double
    let high: Double
    let low: Double
    let volumeLots: Double       // 手
    let amountWan: Double        // 万元
    let change: Double
    let changePercent: Double
    let turnoverPercent: Double
    let pe: Double
    let marketCapYi: Double      // 总市值（亿元）
    let stamp: String            // "2026-11-10 14:20:56"
    let isIndex: Bool

    var id: String { symbol }

    var isUp: Bool { change > 0 }
    var isDown: Bool { change < 0 }
    var isFlat: Bool { change == 0 }

    // A suspended or untraded symbol reports price 0.
    var hasPrice: Bool { price > 0 }

    /// Where the current price sits inside today's low–high band, 0...1.
    /// nil when the band is degenerate (no trading, or a one-tick range).
    var dayPosition: Double? {
        guard hasPrice, high > low else { return nil }
        return min(1, max(0, (price - low) / (high - low)))
    }

    var displaySymbol: String { symbol.uppercased() }
}

// MARK: - Parsing
enum StockFeedError: LocalizedError, Sendable {
    case emptyResponse
    case undecodable
    case noMatch(String)
    case transport(String)
    var errorDescription: String? {
        switch self {
        case .emptyResponse: return "行情接口没有返回内容，请稍后重试。"
        case .undecodable: return "行情数据无法解码，请稍后重试。"
        case .noMatch(let raw): return "没有找到「\(raw)」，请换一个代码或名称试试。"
        case .transport(let message): return "网络请求失败：\(message)"
        }
    }
}

enum StockParser {
    /// Accepts "600519", "sh600519", "SH600519", "000001", "bj830799".
    /// Six bare digits are prefixed by exchange rules; ambiguous codes such as
    /// 000001 resolve to Shenzhen (平安银行) — indices need the explicit sh prefix.
    static func normalize(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["sh", "sz", "bj"] where text.hasPrefix(prefix) {
            let digits = text.dropFirst(prefix.count)
            guard digits.count == 6, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return String(text)
        }
        guard text.count == 6, text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        if text.hasPrefix("92") || text.hasPrefix("8") || text.hasPrefix("4") { return "bj\(text)" }
        if text.hasPrefix("6") || text.hasPrefix("9") || text.hasPrefix("5") { return "sh\(text)" }
        return "sz\(text)"
    }

    /// Splits a quote payload into (symbol, fields) pairs.
    /// Payload shape: v_sh600519="1~贵州茅台~600519~1442.13~...";v_sz000001="...";
    static func entries(_ text: String) -> [(symbol: String, fields: [String])] {
        text.components(separatedBy: ";").compactMap { chunk in
            let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("v_"), let equals = trimmed.firstIndex(of: "=") else { return nil }
            let head = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)..<equals])
            let value = trimmed[trimmed.index(after: equals)...]
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"\n\r "))
            guard value.contains("~") else { return nil }
            return (head, value.components(separatedBy: "~"))
        }
    }

    static func quote(fromFields fields: [String], symbol: String) -> StockQuote? {
        guard fields.count > 34,
              let price = Double(fields[3]),
              let prevClose = Double(fields[4]) else { return nil }
        let name = fields[1].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        func number(_ index: Int) -> Double {
            index < fields.count ? (Double(fields[index]) ?? 0) : 0
        }
        return StockQuote(
            symbol: symbol,
            name: name,
            price: price,
            prevClose: prevClose,
            open: number(5),
            high: number(33),
            low: number(34),
            volumeLots: number(36),
            amountWan: number(37),
            change: number(31),
            changePercent: number(32),
            turnoverPercent: number(38),
            pe: number(39),
            marketCapYi: number(45),
            stamp: formatStamp(fields.count > 30 ? fields[30] : ""),
            isIndex: symbol.hasPrefix("sh000") || symbol.hasPrefix("sz399") || symbol.hasPrefix("bj")
        )
    }

    /// Parses a whole response; rows come back in the requested order so a
    /// symbol the server skipped never reshuffles the list.
    static func quotes(fromPayload text: String, symbols: [String]) -> [StockQuote] {
        let parsed = entries(text).compactMap { quote(fromFields: $0.fields, symbol: $0.symbol) }
        guard !symbols.isEmpty else { return parsed }
        // Anything the server returned that was not asked for is ignored rather
        // than smuggled into the list.
        return symbols.compactMap { code in parsed.first { $0.symbol == code } }
    }

    /// "20261110142056" → "2026-11-10 14:20:56"
    static func formatStamp(_ raw: String) -> String {
        guard raw.count == 14, raw.allSatisfy({ $0.isASCII && $0.isNumber }) else { return "" }
        let parts = [raw.prefix(4), raw.dropFirst(4).prefix(2), raw.dropFirst(6).prefix(2)]
        let time = [raw.dropFirst(8).prefix(2), raw.dropFirst(10).prefix(2), raw.dropFirst(12).prefix(2)]
        return "\(parts[0])-\(parts[1])-\(parts[2]) \(time[0]):\(time[1]):\(time[2])"
    }

    /// Search hints: v_hint="sh~600519~贵州茅台~gzmt~GP-A^sz~000001~平安银行~payh~GP-A"
    struct Hint: Equatable, Sendable, Identifiable {
        let symbol: String
        let name: String
        let kind: String
        var id: String { symbol }
    }

    static func hints(fromPayload text: String, limit: Int = 6) -> [Hint] {
        guard let equals = text.firstIndex(of: "=") else { return [] }
        let body = text[text.index(after: equals)...]
            .trimmingCharacters(in: CharacterSet(charactersIn: "\";\n\r "))
        var result: [Hint] = []
        for entry in body.components(separatedBy: "^") {
            let parts = entry.components(separatedBy: "~")
            guard parts.count >= 5 else { continue }
            let market = parts[0].trimmingCharacters(in: .whitespaces)
            let code = parts[1].trimmingCharacters(in: .whitespaces)
            let name = unicodeEscapes(parts[2]).trimmingCharacters(in: .whitespaces)
            guard ["sh", "sz", "bj"].contains(market), code.count == 6, !name.isEmpty else { continue }
            guard !result.contains(where: { $0.symbol == market + code }) else { continue }
            result.append(Hint(symbol: market + code, name: name, kind: parts[4]))
            if result.count >= limit { break }
        }
        return result
    }

    /// smartbox encodes Chinese as \\uXXXX escapes.
    static func unicodeEscapes(_ raw: String) -> String {
        guard raw.contains("\\u") else { return raw }
        var output = ""
        var index = raw.startIndex
        while index < raw.endIndex {
            if raw[index] == "\\",
               let marker = raw.index(index, offsetBy: 1, limitedBy: raw.endIndex),
               marker < raw.endIndex, raw[marker] == "u" {
                let digitsStart = raw.index(after: marker)
                let digitsEnd = raw.index(digitsStart, offsetBy: 4, limitedBy: raw.endIndex) ?? raw.endIndex
                if digitsEnd > digitsStart,
                   let value = UInt32(raw[digitsStart..<digitsEnd], radix: 16),
                   let scalar = UnicodeScalar(value) {
                    output.unicodeScalars.append(scalar)
                    index = digitsEnd
                    continue
                }
            }
            output.append(raw[index])
            index = raw.index(after: index)
        }
        return output
    }
}

// MARK: - Market phase (Beijing time, weekday session windows, no holiday calendar)
enum StockMarketPhase: String, Sendable {
    case preOpen = "未开盘"
    case auction = "集合竞价"
    case trading = "盘中"
    case lunch = "午间休市"
    case closed = "已收盘"
    case holiday = "休市"

    var isLive: Bool { self == .trading || self == .auction }
}

enum StockMarket {
    static let beijingOffsetMinutes = 480

    static func phase(at now: Date) -> StockMarketPhase {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: beijingOffsetMinutes * 60)!
        let weekday = calendar.component(.weekday, from: now)   // 1 = Sunday
        guard weekday != 1 && weekday != 7 else { return .holiday }
        let hour = calendar.component(.hour, from: now)
        let minute = calendar.component(.minute, from: now)
        let clock = hour * 60 + minute
        switch clock {
        case ..<(9 * 60 + 15): return .preOpen
        case (9 * 60 + 15)..<(9 * 60 + 30): return .auction
        case (9 * 60 + 30)..<(11 * 60 + 30): return .trading
        case (11 * 60 + 30)..<(13 * 60): return .lunch
        case (13 * 60)...(15 * 60): return .trading
        default: return .closed
        }
    }
}

// MARK: - Network feed (server: Tencent quote endpoints, GB18030 text)
final class StockFeed {
    static let quoteEndpoint = "https://qt.gtimg.cn/q="
    static let suggestEndpoint = "https://smartbox.gtimg.cn/s3/?v=2&t=all&q="

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.httpAdditionalHeaders = ["User-Agent": "DevKit/1.6 (macOS)"]
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    static func gb18030(_ data: Data) -> String? {
        let encoding = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        return String(data: data, encoding: String.Encoding(rawValue: encoding))
    }

    /// Fetches quotes for the given symbols; completion runs on the main queue.
    static func quotes(for symbols: [String], completion: @escaping (Result<[StockQuote], Error>) -> Void) {
        guard !symbols.isEmpty else { completion(.success([])); return }
        guard let url = URL(string: quoteEndpoint + symbols.joined(separator: ",")) else {
            completion(.failure(StockFeedError.transport("地址无效"))); return
        }
        request(url) { data in
            guard let text = gb18030(data), !text.isEmpty else {
                completion(.failure(StockFeedError.undecodable)); return
            }
            let parsed = StockParser.quotes(fromPayload: text, symbols: symbols)
            completion(parsed.isEmpty ? .failure(StockFeedError.emptyResponse) : .success(parsed))
        }
    }

    /// Name / code search; completion runs on the main queue.
    static func hints(for query: String, completion: @escaping (Result<[StockParser.Hint], Error>) -> Void) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { completion(.success([])); return }
        guard let escaped = trimmed.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              let url = URL(string: suggestEndpoint + escaped) else {
            completion(.success([])); return
        }
        request(url) { data in
            let text = gb18030(data) ?? String(decoding: data, as: UTF8.self)
            completion(.success(StockParser.hints(fromPayload: text)))
        }
    }

    private static func request(_ url: URL, handler: @escaping (Data) -> Void) {
        session.dataTask(with: url) { data, _, error in
            DispatchQueue.main.async {
                guard let data = data, error == nil else {
                    handler(Data())
                    return
                }
                handler(data)
            }
        }.resume()
    }
}

// MARK: - Watchlist state
/// Holds the user's symbols, the latest snapshots and the refresh timer.
/// All mutation happens on the main queue; nothing is written to disk except
/// the symbol list and the refresh interval, both as plain preferences.
final class StockBoard: ObservableObject {
    static let watchlistKey = "DevKit.stockWatchlist"
    static let intervalKey = "DevKit.stockRefreshInterval"
    static let defaultSymbols = ["sh000001", "sz399001", "sh600519"]
    static let defaultInterval = 10

    @Published private(set) var symbols: [String]
    @Published private(set) var quotes: [String: StockQuote] = [:]
    @Published private(set) var loading = false
    @Published var error = ""
    @Published private(set) var lastUpdated: Date?
    @Published var interval: Int {
        didSet {
            guard [5, 10, 30].contains(interval) else { interval = Self.defaultInterval; return }
            defaults.set(interval, forKey: Self.intervalKey)
            if running { restartTimer() }
        }
    }
    @Published var phase: StockMarketPhase = StockMarket.phase(at: Date())
    @Published var query = ""
    @Published var hints: [StockParser.Hint] = []
    @Published var hintError = ""

    private let defaults: UserDefaults
    private var timer: Timer?
    private var running = false
    private var hintGeneration = UUID()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.stringArray(forKey: Self.watchlistKey) ?? Self.defaultSymbols
        symbols = saved.isEmpty ? [] : saved
        let savedInterval = defaults.integer(forKey: Self.intervalKey)
        interval = [5, 10, 30].contains(savedInterval) ? savedInterval : Self.defaultInterval
    }

    var ordered: [StockQuote] { symbols.compactMap { quotes[$0] } }

    func start() {
        guard !running else { return }
        running = true
        refresh()
        restartTimer()
    }

    func stop() {
        running = false
        timer?.invalidate()
        timer = nil
    }

    private func restartTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(interval), repeats: true) { [weak self] _ in
            self?.refresh()
        }
        timer?.tolerance = 0.5
    }

    func refresh() {
        phase = StockMarket.phase(at: Date())
        guard !symbols.isEmpty else {
            quotes = [:]; lastUpdated = Date(); error = ""; loading = false
            return
        }
        loading = true
        let requested = symbols
        StockFeed.quotes(for: requested) { [weak self] result in
            guard let self = self else { return }
            self.loading = false
            switch result {
            case .success(let list):
                self.error = ""
                var byCode: [String: StockQuote] = [:]
                for quote in list { byCode[quote.symbol] = quote }
                // Keep a stale snapshot visible rather than blanking a row the
                // feed refused to report this cycle.
                for code in requested where byCode[code] == nil {
                    byCode[code] = self.quotes[code]
                }
                self.quotes = byCode.compactMapValues { $0 }
                self.lastUpdated = Date()
            case .failure(let failure):
                self.error = failure.localizedDescription
            }
        }
    }

    func add(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let symbol = StockParser.normalize(trimmed) else {
            error = "请输入 6 位代码（如 600519）或用名称搜索。"
            return
        }
        add(symbol: symbol)
    }

    func add(symbol: String) {
        guard !symbols.contains(symbol) else {
            error = "已经在自选列表里了。"
            query = ""; hints = []
            return
        }
        symbols.append(symbol)
        persistSymbols()
        error = ""
        query = ""; hints = []; hintError = ""
        if running { refresh() }
    }

    func remove(_ symbol: String) {
        symbols.removeAll { $0 == symbol }
        quotes[symbol] = nil
        persistSymbols()
        if running { refresh() }
    }

    func moveToTop(_ symbol: String) {
        guard let index = symbols.firstIndex(of: symbol), index > 0 else { return }
        symbols.remove(at: index)
        symbols.insert(symbol, at: 0)
        persistSymbols()
    }

    func resetSymbols() {
        symbols = Self.defaultSymbols
        persistSymbols()
        if running { refresh() }
    }

    /// Debounced name search for the add field.
    func search(_ text: String) {
        let generation = UUID()
        hintGeneration = generation
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, StockParser.normalize(trimmed) == nil else {
            hints = []; hintError = ""
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self = self, self.hintGeneration == generation else { return }
            StockFeed.hints(for: trimmed) { [weak self] result in
                guard let self = self, self.hintGeneration == generation else { return }
                switch result {
                case .success(let list):
                    self.hints = list
                    self.hintError = list.isEmpty ? "没有匹配的代码或名称。" : ""
                case .failure:
                    self.hints = []
                    self.hintError = "搜索失败，请检查网络。"
                }
            }
        }
    }

    /// Exposed for the page: a symbol added while the page is on screen should
    /// show data immediately, but off-screen mutations stay silent.
    var isRunning: Bool { running }

    private func persistSymbols() {
        defaults.set(symbols, forKey: Self.watchlistKey)
    }
}

// MARK: - Formatting helpers
enum StockFormat {
    static func price(_ value: Double) -> String {
        value > 0 ? String(format: "%.2f", value) : "—"
    }

    static func signedPercent(_ value: Double) -> String {
        String(format: "%+.2f%%", value)
    }

    static func signedAmount(_ value: Double) -> String {
        String(format: "%+.2f", value)
    }

    /// 万元 → 万 / 亿
    static func amount(_ wan: Double) -> String {
        guard wan > 0 else { return "—" }
        if wan >= 10_000 { return String(format: "%.2f 亿", wan / 10_000) }
        return String(format: "%.0f 万", wan)
    }

    static func cap(_ yi: Double) -> String {
        guard yi > 0 else { return "—" }
        return String(format: "%.0f 亿", yi)
    }

    static func updated(_ date: Date?) -> String {
        guard let date = date else { return "尚未更新" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}
