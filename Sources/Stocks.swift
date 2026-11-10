import Foundation

// MARK: - Markets
/// The three markets the page groups into columns. A symbol carries its market
/// in its prefix, so no extra bookkeeping is needed per row.
enum StockMarketKind: String, CaseIterable, Sendable, Identifiable {
    case aShare = "A股"
    case hk = "港股"
    case us = "美股"

    var id: String { rawValue }

    /// "sh600519" / "sz399001" / "bj830799" are A shares, "hk00700" is Hong
    /// Kong, "usAAPL" and "us.DJI" are US listings and indices.
    static func kind(of symbol: String) -> StockMarketKind? {
        let text = symbol.lowercased()
        if text.hasPrefix("hk") { return .hk }
        if text.hasPrefix("us") { return .us }
        if ["sh", "sz", "bj"].contains(where: text.hasPrefix) { return .aShare }
        return nil
    }

    /// The exchange's own clock decides the session, so US daylight saving and
    /// Hong Kong hours need no arithmetic here.
    var timeZone: TimeZone {
        switch self {
        case .aShare: return TimeZone(secondsFromGMT: 8 * 60 * 60) ?? .current
        case .hk: return TimeZone(identifier: "Asia/Hong_Kong") ?? TimeZone(secondsFromGMT: 8 * 60 * 60) ?? .current
        case .us: return TimeZone(identifier: "America/New_York") ?? TimeZone(secondsFromGMT: -5 * 60 * 60) ?? .current
        }
    }

    var hint: String {
        switch self {
        case .aShare: return "6 位代码，如 600519"
        case .hk: return "5 位代码，如 00700"
        case .us: return "字母代码，如 AAPL"
        }
    }
}

// MARK: - Model
/// One real-time snapshot, parsed from the Tencent quote feed. Money and volume
/// are normalised to 万元 and 手 so the formatter and the tests stay uniform
/// across the three markets.
struct StockQuote: Equatable, Sendable, Identifiable {
    let symbol: String          // "sh600519" / "hk00700" / "usAAPL"
    let name: String
    let market: StockMarketKind
    let price: Double
    let prevClose: Double
    let open: Double
    let high: Double
    let low: Double
    let volumeLots: Double       // 手 (HK/US share counts divided by 100)
    let amountWan: Double        // 万元 (HK/US turnover divided by 10,000)
    let change: Double
    let changePercent: Double
    let turnoverPercent: Double
    let pe: Double
    let marketCapYi: Double      // 总市值（亿元）; 0 when the feed gives nothing usable
    let stamp: String            // "2026-11-10 14:20:56"
    let isIndex: Bool

    var id: String { symbol }

    var isUp: Bool { change > 0 }
    var isDown: Bool { change < 0 }
    var isFlat: Bool { change == 0 }

    // A suspended or untraded symbol reports price 0.
    var hasPrice: Bool { price > 0 }

    /// "600519" — the market prefix is already implied by the column.
    var code: String { String(symbol.dropFirst(2)) }

    var displaySymbol: String { code.uppercased() }

    /// Where the current price sits inside today's low–high band, 0...1.
    /// nil when the band is degenerate (no trading, or a one-tick range).
    var dayPosition: Double? {
        guard hasPrice, high > low else { return nil }
        return min(1, max(0, (price - low) / (high - low)))
    }
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
    /// Listing suffixes the feed appends to US codes in its payload
    /// ("AAPL.OQ", "BABA.N", "TCTZF.PS"). They are not valid quote keys, so a
    /// ticker drops them; "BRK.B" keeps its own dot because "B" is no venue.
    static let listingSuffixes: Set<String> = ["OQ", "N", "PS", "NY", "US", "NASDAQ", "AMEX", "PK", "OB", "OTC", "NX"]

    static func isDigit(_ character: Character) -> Bool { character.isASCII && character.isNumber }

    /// Uppercases a ticker, drops a listing suffix, validates the shape.
    /// Accepts "AAPL", "aapl.oq", "BRK.B", ".DJI". Digits are refused so a
    /// half-typed code such as "hs700" is reported rather than turned into a
    /// bogus US symbol.
    static func ticker(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !text.isEmpty, text.count <= 12 else { return nil }
        guard text.allSatisfy({ $0.isASCII && ($0.isLetter || $0 == ".") }) else { return nil }
        guard let first = text.first, (first.isASCII && first.isLetter) || first == "." else { return nil }
        if first == ".", text.count < 2 { return nil }
        while let dot = text.lastIndex(of: ".") {
            let head = String(text[text.startIndex..<dot])
            let suffix = String(text[text.index(after: dot)...])
            guard !head.isEmpty, listingSuffixes.contains(suffix) else { break }
            text = head
        }
        guard !text.isEmpty, text != ".", text.count <= 10 else { return nil }
        return text
    }

    /// Accepts A-share codes ("600519", "sh600519"), Hong Kong codes ("00700",
    /// "hk700", "hkHSI") and US tickers ("AAPL", "aapl.oq", "us.DJI").
    /// Ambiguous bare codes are resolved by length: six digits are A shares,
    /// five are Hong Kong; letters are US.
    static func normalize(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return nil }

        if text.hasPrefix("hk") {
            let rest = String(text.dropFirst(2))
            guard rest.count >= 1, rest.count <= 6 else { return nil }
            if rest.count <= 5, rest.allSatisfy(isDigit) {
                return "hk" + String(repeating: "0", count: 5 - rest.count) + rest
            }
            guard let code = ticker(rest), !code.contains(".") else { return nil }
            return "hk" + code
        }
        if text.hasPrefix("us") {
            guard let code = ticker(String(text.dropFirst(2))) else { return nil }
            return "us" + code
        }
        for prefix in ["sh", "sz", "bj"] where text.hasPrefix(prefix) {
            let digits = text.dropFirst(prefix.count)
            guard digits.count == 6, digits.allSatisfy(isDigit) else { return nil }
            return text
        }
        if text.count == 6, text.allSatisfy(isDigit) {
            if text.hasPrefix("92") || text.hasPrefix("8") || text.hasPrefix("4") { return "bj\(text)" }
            if text.hasPrefix("6") || text.hasPrefix("9") || text.hasPrefix("5") { return "sh\(text)" }
            return "sz\(text)"
        }
        if text.count <= 5, text.count >= 1, text.allSatisfy(isDigit) {
            return "hk" + String(repeating: "0", count: 5 - text.count) + text
        }
        if let code = ticker(text) { return "us\(code)" }
        return nil
    }

    /// Splits a pasted list into canonical symbols, in order, duplicates
    /// removed; anything unrecognised is reported back instead of guessed.
    static func parseList(_ text: String) -> (symbols: [String], rejected: [String]) {
        let separators = CharacterSet(charactersIn: " \t\r\n,;，、；　")
        var symbols: [String] = []
        var rejected: [String] = []
        for token in text.components(separatedBy: separators) where !token.isEmpty {
            if let symbol = normalize(token) {
                if !symbols.contains(symbol) { symbols.append(symbol) }
            } else {
                rejected.append(token)
            }
        }
        return (symbols, rejected)
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
        let market = StockMarketKind.kind(of: symbol) ?? .aShare
        func text(_ index: Int) -> String { index < fields.count ? fields[index] : "" }
        func number(_ index: Int) -> Double { Double(text(index)) ?? 0 }

        let isAShare = market == .aShare
        let rawVolume = number(36)
        let rawAmount = number(37)
        return StockQuote(
            symbol: symbol,
            name: name,
            market: market,
            price: price,
            prevClose: prevClose,
            open: number(5),
            high: number(33),
            low: number(34),
            volumeLots: isAShare ? rawVolume : rawVolume / 100,
            amountWan: isAShare ? rawAmount : rawAmount / 10_000,
            change: number(31),
            changePercent: number(32),
            turnoverPercent: number(38),
            pe: number(39),
            // The feed's market-cap field means different things per market and
            // is plainly wrong for US listings, so it is kept only where it is
            // the total in 亿元.
            marketCapYi: market == .us ? 0 : number(45),
            stamp: formatStamp(text(30)),
            isIndex: isIndex(symbol: symbol)
        )
    }

    /// A-share indices are "sh000…" and "sz399…"; Hong Kong indices use letter
    /// codes (HSI, HSTECH); US indices keep a leading dot (".DJI", ".INX").
    static func isIndex(symbol: String) -> Bool {
        let code = String(symbol.dropFirst(2)).uppercased()
        switch StockMarketKind.kind(of: symbol) ?? .aShare {
        case .aShare:
            return (symbol.hasPrefix("sh") && code.hasPrefix("000"))
                || (symbol.hasPrefix("sz") && code.hasPrefix("399"))
        case .hk:
            return !code.allSatisfy(isDigit)
        case .us:
            return code.hasPrefix(".")
                || ["DJI", "INX", "IXIC", "NDX", "SPX", "VIX", "RUT", "SOX"].contains(code)
        }
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

    /// A shares use a 14-digit stamp; Hong Kong and US use readable dates.
    /// Both are normalised to "2026-11-10 14:20:56".
    static func formatStamp(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        if text.count == 14, text.allSatisfy(isDigit) {
            let parts = [text.prefix(4), text.dropFirst(4).prefix(2), text.dropFirst(6).prefix(2)]
            let time = [text.dropFirst(8).prefix(2), text.dropFirst(10).prefix(2), text.dropFirst(12).prefix(2)]
            return "\(parts[0])-\(parts[1])-\(parts[2]) \(time[0]):\(time[1]):\(time[2])"
        }
        let halves = text.split(separator: " ")
        guard halves.count == 2 else { return "" }
        let date = halves[0].replacingOccurrences(of: "/", with: "-")
        let dateParts = date.split(separator: "-")
        let timeParts = halves[1].split(separator: ":")
        guard dateParts.count == 3, timeParts.count == 3,
              dateParts[0].count == 4, dateParts[1].count == 2, dateParts[2].count == 2,
              timeParts.allSatisfy({ $0.count == 2 && $0.allSatisfy(isDigit) }),
              dateParts.allSatisfy({ $0.allSatisfy(isDigit) }) else { return "" }
        return "\(date) \(halves[1])"
    }

    /// Search hints: v_hint="sh~600519~贵州茅台~gzmt~GP-A^hk~00700~腾讯控股~txkg~GP"
    struct Hint: Equatable, Sendable, Identifiable {
        let symbol: String
        let name: String
        let kind: String
        var id: String { symbol }
        var market: StockMarketKind { StockMarketKind.kind(of: symbol) ?? .aShare }
        var code: String { String(symbol.dropFirst(2)).uppercased() }
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
            guard !name.isEmpty else { continue }
            let symbol: String?
            switch market {
            case "sh", "sz", "bj":
                symbol = code.count == 6 && code.allSatisfy(isDigit) ? market + code : nil
            case "hk", "us":
                symbol = normalize(market + code)
            default:
                symbol = nil
            }
            guard let resolved = symbol else { continue }
            guard !result.contains(where: { $0.symbol == resolved }) else { continue }
            result.append(Hint(symbol: resolved, name: name, kind: parts[4]))
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

// MARK: - Market phase (each exchange's own clock, weekday windows, no holiday calendar)
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
    static func phase(at now: Date) -> StockMarketPhase { phase(for: .aShare, at: now) }

    /// Sessions per market, read on that market's clock so US daylight saving
    /// needs no special case. Legal holidays are not modelled.
    static func phase(for market: StockMarketKind, at now: Date) -> StockMarketPhase {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = market.timeZone
        let weekday = calendar.component(.weekday, from: now)   // 1 = Sunday
        guard weekday != 1 && weekday != 7 else { return .holiday }
        let clock = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        switch market {
        case .aShare:
            switch clock {
            case ..<(9 * 60 + 15): return .preOpen
            case (9 * 60 + 15)..<(9 * 60 + 30): return .auction
            case (9 * 60 + 30)..<(11 * 60 + 30): return .trading
            case (11 * 60 + 30)..<(13 * 60): return .lunch
            case (13 * 60)...(15 * 60): return .trading
            default: return .closed
            }
        case .hk:
            switch clock {
            case ..<(9 * 60 + 15): return .preOpen
            case (9 * 60 + 15)..<(9 * 60 + 30): return .auction
            case (9 * 60 + 30)..<(12 * 60): return .trading
            case (12 * 60)..<(13 * 60): return .lunch
            case (13 * 60)..<(16 * 60): return .trading
            default: return .closed
            }
        case .us:
            switch clock {
            case (9 * 60 + 30)..<(16 * 60): return .trading
            case (16 * 60)...: return .closed
            default: return .preOpen
            }
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
        config.httpAdditionalHeaders = ["User-Agent": "DevKit/1.7 (macOS)"]
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    static func gb18030(_ data: Data) -> String? {
        let encoding = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        return String(data: data, encoding: String.Encoding(rawValue: encoding))
    }

    /// Fetches quotes for the given symbols; completion runs on the main queue.
    /// One request carries every market, so a page refresh stays a single call.
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
    static let intervalOptions = [5, 10, 30, 60, 300]
    static let defaultSymbols = ["sh000001", "sz399001", "sh600519", "hk00700", "usAAPL"]
    static let defaultInterval = 10

    @Published private(set) var symbols: [String]
    @Published private(set) var quotes: [String: StockQuote] = [:]
    @Published private(set) var phases: [StockMarketKind: StockMarketPhase] = [:]
    @Published private(set) var loading = false
    @Published var error = ""
    @Published var info = ""
    @Published private(set) var lastUpdated: Date?
    @Published var interval: Int {
        didSet {
            guard Self.intervalOptions.contains(interval) else { interval = Self.defaultInterval; return }
            defaults.set(interval, forKey: Self.intervalKey)
            if running { restartTimer() }
        }
    }
    @Published var query = ""
    @Published var hints: [StockParser.Hint] = []
    @Published var hintError = ""
    @Published var isEditing = false
    @Published var editDraft = ""
    @Published var editNote = ""

    private let defaults: UserDefaults
    private var timer: Timer?
    private var running = false
    private var hintGeneration = UUID()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.stringArray(forKey: Self.watchlistKey) ?? Self.defaultSymbols
        symbols = saved.isEmpty ? [] : saved
        let savedInterval = defaults.integer(forKey: Self.intervalKey)
        interval = Self.intervalOptions.contains(savedInterval) ? savedInterval : Self.defaultInterval
        phases = [:]
    }

    var ordered: [StockQuote] { symbols.compactMap { quotes[$0] } }

    func symbols(in market: StockMarketKind) -> [String] {
        symbols.filter { StockMarketKind.kind(of: $0) == market }
    }

    func phase(for market: StockMarketKind) -> StockMarketPhase {
        phases[market] ?? StockMarket.phase(for: market, at: Date())
    }

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
        let now = Date()
        var current: [StockMarketKind: StockMarketPhase] = [:]
        for market in StockMarketKind.allCases { current[market] = StockMarket.phase(for: market, at: now) }
        phases = current
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
            error = "请输入代码或用名称搜索：A股 6 位（600519）、港股 5 位（00700）、美股字母代码（AAPL）。"
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
        error = ""; info = ""
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

    // MARK: Batch edit

    func beginEdit() {
        editDraft = symbols.joined(separator: "\n")
        editNote = ""
        isEditing = true
    }

    func cancelEdit() {
        isEditing = false
        editNote = ""
    }

    /// Replaces the watchlist with whatever the draft resolves to. Unrecognised
    /// tokens are reported, never guessed, and the list is left untouched when
    /// nothing resolves.
    func applyEdit() {
        let result = StockParser.parseList(editDraft)
        guard !result.symbols.isEmpty else {
            editNote = "没有识别到任何代码，列表没有改动。"
            return
        }
        symbols = result.symbols
        quotes = quotes.filter { symbols.contains($0.key) }
        persistSymbols()
        info = result.rejected.isEmpty
            ? ""
            : "批量编辑跳过 \(result.rejected.count) 个无法识别的项：\(result.rejected.prefix(3).joined(separator: "、"))"
        editNote = ""
        isEditing = false
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

    static func intervalLabel(_ seconds: Int) -> String {
        switch seconds {
        case 60: return "1 分钟"
        case 300: return "5 分钟"
        default: return "\(seconds) 秒"
        }
    }
}
