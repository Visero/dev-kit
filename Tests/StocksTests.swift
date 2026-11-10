import Foundation

@main
struct StocksTests {
    static var passed = 0
    static func check(_ name: String, _ condition: Bool) {
        guard condition else { print("FAIL: \(name)"); exit(1) }
        passed += 1
    }

    // One real payload line (abridged, field values kept in their real positions).
    static let quotePayload = """
    v_sh000001="1~上证指数~000001~3668.36~3660.79~3682.04~339878994~0~0~0.00~0~0.00~0~0.00~0~0.00~0~0.00~0~0.00~0~0.00~0~0.00~0~0.00~0~0.00~0~~20261110142039~7.57~0.21~3683.73~3661.60~3668.36/339878994/574974268131~339878994~57497427~0.70~16.65~~3683.73~3661.60~0.60~577122.27~643413.70~0.00~-1~-1~0.78~0~3671.82~~~~~~57497426.8131~0.0000~0~ ~ZS~-7.57~1.67~~~~4258.86~3574.27~0.55~-3.49~-7.52~4864359819725~~5.45~-9.77~4864359819725~~~-8.72~0.06~~CNY~0~~0.00~0~";
    v_sh600519="1~贵州茅台~600519~1442.13~1444.99~1438.23~18975~9574~9400~1442.13~3~1442.12~2~1441.66~2~1441.65~2~1441.62~1~1442.57~1~1442.58~1~1442.60~1~1442.80~1~1442.85~2~~20261110142056~-2.86~-0.20~1443.88~1431.26~1442.13/18975/2730047271~18975~273005~0.15~21.94~~1443.88~1431.26~0.87~18027.80~18027.80~6.65~1589.49~1300.49~0.45";
    """

    /// Builds a synthetic payload line, keeping the feed's real field indexes so
    /// the Hong Kong / US shapes (different stamps and money units) are tested
    /// against the same positions the live feed uses.
    static func line(_ symbol: String, name: String, code: String, price: String, prevClose: String,
                     open: String, stamp: String, change: String, percent: String, high: String, low: String,
                     volume: String, amount: String, turnover: String, pe: String, cap: String) -> String {
        var fields = Array(repeating: "0", count: 50)
        fields[1] = name; fields[2] = code
        fields[3] = price; fields[4] = prevClose; fields[5] = open
        fields[30] = stamp; fields[31] = change; fields[32] = percent
        fields[33] = high; fields[34] = low
        fields[36] = volume; fields[37] = amount
        fields[38] = turnover; fields[39] = pe
        fields[44] = cap; fields[45] = cap
        return "v_\(symbol)=\"" + fields.joined(separator: "~") + "\";"
    }

    static func main() {
        // MARK: - Symbol normalisation
        check("normalize sh code", StockParser.normalize("600519") == "sh600519")
        check("normalize sz code", StockParser.normalize("000001") == "sz000001")
        check("normalize explicit sh index", StockParser.normalize("sh000001") == "sh000001")
        check("normalize uppercase prefix", StockParser.normalize("SH600519") == "sh600519")
        check("normalize padded input", StockParser.normalize("  sz399001 \n") == "sz399001")
        check("normalize bj code", StockParser.normalize("830799") == "bj830799")
        check("normalize rejects name", StockParser.normalize("茅台") == nil)
        check("normalize rejects mixed junk", StockParser.normalize("60051x") == nil)

        // Hong Kong: bare 5 digits, short digits padded, letter codes for indices.
        check("normalize hk five digits", StockParser.normalize("00700") == "hk00700")
        check("normalize hk pads short code", StockParser.normalize("700") == "hk00700")
        check("normalize hk prefix", StockParser.normalize("hk00700") == "hk00700")
        check("normalize hk short prefix", StockParser.normalize("HK700") == "hk00700")
        check("normalize hk index letters", StockParser.normalize("hkHSI") == "hkHSI")
        check("normalize hk rejects long digits", StockParser.normalize("hk1234567") == nil)

        // US: bare tickers, listing suffixes dropped, dotted tickers kept.
        check("normalize us ticker", StockParser.normalize("AAPL") == "usAAPL")
        check("normalize us lowercase", StockParser.normalize("aapl") == "usAAPL")
        check("normalize us suffix dropped", StockParser.normalize("aapl.oq") == "usAAPL")
        check("normalize us prefix", StockParser.normalize("usAAPL") == "usAAPL")
        check("normalize us pink sheet suffix", StockParser.normalize("tcehy.ps") == "usTCEHY")
        check("normalize us dotted ticker", StockParser.normalize("BRK.B") == "usBRK.B")
        check("normalize us index", StockParser.normalize("us.DJI") == "us.DJI")
        check("normalize rejects half-typed code", StockParser.normalize("hs700") == nil)
        check("normalize rejects digit-first ticker", StockParser.normalize("1AAPL") == nil)

        // MARK: - Batch list parsing
        let pasted = StockParser.parseList("600519, 00700   AAPL\n茅台\tus.DJI；hs700")
        check("batch keeps three markets", pasted.symbols == ["sh600519", "hk00700", "usAAPL", "us.DJI"])
        check("batch reports junk tokens", pasted.rejected == ["茅台", "hs700"])
        let batch = StockParser.parseList("600519\n00700\nAAPL\n茅台\n纳斯达克")
        check("batch resolves three markets", batch.symbols == ["sh600519", "hk00700", "usAAPL"])
        check("batch reports rejects", batch.rejected == ["茅台", "纳斯达克"])
        let deduped = StockParser.parseList("600519 600519 sh600519 AAPL aapl")
        check("batch dedupes across spellings", deduped.symbols == ["sh600519", "usAAPL"])
        check("batch ignores separators only", StockParser.parseList(" , \n ").symbols.isEmpty)

        // MARK: - Payload splitting
        let entries = StockParser.entries(quotePayload)
        check("payload yields two entries", entries.count == 2)
        check("payload keeps symbol keys", entries.map(\.symbol) == ["sh000001", "sh600519"])
        check("payload ignores junk", StockParser.entries("garbage without equal sign").isEmpty)

        // MARK: - Quote fields (A shares unchanged)
        let quotes = StockParser.quotes(fromPayload: quotePayload, symbols: ["sh000001", "sh600519"])
        check("two quotes parsed", quotes.count == 2)
        let index = quotes[0]
        check("index name", index.name == "上证指数")
        check("index price", index.price == 3668.36)
        check("index prev close", index.prevClose == 3660.79)
        check("index open", index.open == 3682.04)
        check("index high", index.high == 3683.73)
        check("index low", index.low == 3661.60)
        check("index change", index.change == 7.57)
        check("index change percent", index.changePercent == 0.21)
        check("index amount in 万", index.amountWan == 57497427)
        check("index market", index.market == .aShare)
        check("index flagged as index", index.isIndex)
        check("index stamp formatted", index.stamp == "2026-11-10 14:20:39")
        check("index code", index.code == "000001")
        check("index is up", index.isUp && !index.isDown)

        let stock = quotes[1]
        check("stock name", stock.name == "贵州茅台")
        check("stock price", stock.price == 1442.13)
        check("stock change", stock.change == -2.86)
        check("stock change percent", stock.changePercent == -0.20)
        check("stock turnover", stock.turnoverPercent == 0.15)
        check("stock pe", stock.pe == 21.94)
        check("stock market cap", stock.marketCapYi == 18027.80)
        check("stock volume", stock.volumeLots == 18975)
        check("stock not an index", !stock.isIndex)
        check("stock is down", stock.isDown && !stock.isUp)

        // MARK: - Quote fields (Hong Kong)
        let hkLine = line("hk00700", name: "腾讯控股", code: "00700", price: "418.800", prevClose: "418.400",
                          open: "423.000", stamp: "2026/11/10 14:38:17", change: "0.400", percent: "0.10",
                          high: "425.400", low: "416.600", volume: "10700578.0",
                          amount: "4447384100.392", turnover: "0", pe: "15.28", cap: "38043.6260")
        let hk = StockParser.quote(fromFields: StockParser.entries(hkLine).first?.fields ?? [], symbol: "hk00700")
        check("hk parsed", hk != nil)
        check("hk market", hk?.market == .hk)
        check("hk name", hk?.name == "腾讯控股")
        check("hk code stripped", hk?.code == "00700")
        check("hk price", hk?.price == 418.8)
        check("hk change", hk?.change == 0.4)
        check("hk stamp normalised", hk?.stamp == "2026-11-10 14:38:17")
        check("hk volume converted to 手", abs((hk?.volumeLots ?? 0) - 107005.78) < 0.001)
        check("hk turnover converted to 万元", abs((hk?.amountWan ?? 0) - 444738.4100392) < 0.001)
        check("hk cap in 亿", hk?.marketCapYi == 38043.626)
        check("hk stock is not an index", hk?.isIndex == false)

        // MARK: - Quote fields (US)
        let usLine = line("usAAPL", name: "苹果", code: "AAPL.OQ", price: "350.69", prevClose: "342.37",
                          open: "345.00", stamp: "2026-11-09 16:00:01", change: "8.32", percent: "2.43",
                          high: "352.33", low: "344.78", volume: "48753052",
                          amount: "17078615942", turnover: "0.34", pe: "39.05", cap: "50931.09754")
        let us = StockParser.quote(fromFields: StockParser.entries(usLine).first?.fields ?? [], symbol: "usAAPL")
        check("us parsed", us != nil)
        check("us market", us?.market == .us)
        check("us name", us?.name == "苹果")
        check("us code stripped", us?.code == "AAPL")
        check("us price", us?.price == 350.69)
        check("us percent", us?.changePercent == 2.43)
        check("us stamp hyphens", us?.stamp == "2026-11-09 16:00:01")
        check("us volume converted to 手", abs((us?.volumeLots ?? 0) - 487530.52) < 0.001)
        check("us turnover converted to 万元", abs((us?.amountWan ?? 0) - 1707861.5942) < 0.001)
        check("us cap hidden", us?.marketCapYi == 0)
        check("us stock is not an index", us?.isIndex == false)
        check("us turnover percent kept", us?.turnoverPercent == 0.34)

        // MARK: - Index detection across markets
        check("a share index sh000300", StockParser.isIndex(symbol: "sh000300"))
        check("a share index sz399006", StockParser.isIndex(symbol: "sz399006"))
        check("a share stock is not index", !StockParser.isIndex(symbol: "sh600519"))
        check("bj stock is not index", !StockParser.isIndex(symbol: "bj830799"))
        check("hk index letters", StockParser.isIndex(symbol: "hkHSI"))
        check("hk stock numeric", !StockParser.isIndex(symbol: "hk00700"))
        check("us index dot", StockParser.isIndex(symbol: "us.DJI"))
        check("us index known ticker", StockParser.isIndex(symbol: "usIXIC"))
        check("us stock not index", !StockParser.isIndex(symbol: "usAAPL"))

        // MARK: - Mixed payload keeps order
        let mixed = StockParser.quotes(fromPayload: hkLine + usLine + quotePayload,
                                       symbols: ["usAAPL", "sh600519", "hk00700"])
        check("mixed payload order", mixed.map(\.symbol) == ["usAAPL", "sh600519", "hk00700"])
        check("mixed payload markets", mixed.map(\.market) == [.us, .aShare, .hk])

        // MARK: - Day position
        let position = stock.dayPosition
        check("day position exists", position != nil)
        check("day position in range", (position ?? -1) >= 0 && (position ?? 2) <= 1)
        let expected = (1442.13 - 1431.26) / (1443.88 - 1431.26)
        check("day position matches the band", abs((position ?? 0) - expected) < 0.0001)
        let flat = StockQuote(symbol: "sh600519", name: "贵州茅台", market: .aShare, price: 0,
                          prevClose: 1444.99, open: 0, high: 0, low: 0, volumeLots: 0, amountWan: 0,
                          change: 0, changePercent: 0, turnoverPercent: 0, pe: 0, marketCapYi: 0,
                          stamp: "", isIndex: false)
        check("suspended quote has no price", !flat.hasPrice)
        check("suspended quote has no position", flat.dayPosition == nil)
        let oneTick = StockQuote(symbol: "sh600519", name: "x", market: .aShare, price: 10,
                             prevClose: 10, open: 10, high: 10, low: 10, volumeLots: 1, amountWan: 1,
                             change: 0, changePercent: 0, turnoverPercent: 0, pe: 0, marketCapYi: 0,
                             stamp: "", isIndex: false)
        check("degenerate band has no position", oneTick.dayPosition == nil)

        // MARK: - Order stability
        let reordered = StockParser.quotes(fromPayload: quotePayload, symbols: ["sh600519", "sh000001"])
        check("rows follow request order", reordered.map(\.symbol) == ["sh600519", "sh000001"])
        let missing = StockParser.quotes(fromPayload: quotePayload, symbols: ["sh600519", "sz000002"])
        check("requested-but-absent symbol is dropped", missing.map(\.symbol) == ["sh600519"])
        check("empty payload parses nothing", StockParser.quotes(fromPayload: "", symbols: ["sh600519"]).isEmpty)

        // MARK: - Stamp
        check("stamp short input", StockParser.formatStamp("2026") == "")
        check("stamp non numeric", StockParser.formatStamp("2026111014205X") == "")
        check("stamp full", StockParser.formatStamp("20260101093000") == "2026-01-01 09:30:00")
        check("stamp slashed date", StockParser.formatStamp("2026/11/10 14:38:17") == "2026-11-10 14:38:17")
        check("stamp hyphen date", StockParser.formatStamp("2026-11-09 16:00:01") == "2026-11-09 16:00:01")
        check("stamp rejects half date", StockParser.formatStamp("2026/11/10") == "")
        check("stamp rejects short time", StockParser.formatStamp("2026/11/10 14:3") == "")

        // MARK: - Search hints
        let hintPayload = #"v_hint="sh~600519~\u8d35\u5dde\u8305\u53f0~gzmt~GP-A^sz~000001~\u5e73\u5b89\u94f6\u884c~payh~GP-A""#
        let hints = StockParser.hints(fromPayload: hintPayload)
        check("two hints", hints.count == 2)
        check("hint symbol", hints.first?.symbol == "sh600519")
        check("hint name decoded", hints.first?.name == "贵州茅台")
        check("hint kind", hints.first?.kind == "GP-A")
        check("hint market", hints.first?.market == .aShare)
        check("second hint", hints.count == 2 && hints[1].name == "平安银行")
        check("plain text survives", StockParser.unicodeEscapes("plain") == "plain")
        check("broken escape survives", StockParser.unicodeEscapes("\\x41") == "\\x41")
        check("mixed escapes", StockParser.unicodeEscapes("a\\u0041b") == "aAb")

        let offshoreHints = #"v_hint="hk~00700~\u817e\u8baf\u63a7\u80a1~txkg~GP^us~tctzf.ps~\u817e\u8baf\u63a7\u80a1~txkg~GP^us~aapl.oq~\u82f9\u679c~pg~GP^hk~HSI~\u6052\u751f\u6307\u6570~hszs~ZS""#
        let hkHints = StockParser.hints(fromPayload: offshoreHints)
        check("hk hint resolved", hkHints.first?.symbol == "hk00700")
        check("hk hint padded name", hkHints.first?.name == "腾讯控股")
        check("hk hint market", hkHints.first?.market == .hk)
        check("us hint canonical", hkHints.count >= 3 && hkHints[2].symbol == "usAAPL")
        check("us hint market", hkHints.count >= 3 && hkHints[2].market == .us)
        check("hk index hint", hkHints.contains { $0.symbol == "hkHSI" })
        check("hint rejects unknown market", StockParser.hints(fromPayload: #"v_hint="jp~7203~Toyota~toyota~GP""#).isEmpty)
        check("hint without equal", StockParser.hints(fromPayload: "v_hint").isEmpty)

        // MARK: - Market phase (each exchange's own clock)
        func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int,
                  zone: TimeZone) -> Date {
            var components = DateComponents()
            components.year = year; components.month = month; components.day = day
            components.hour = hour; components.minute = minute
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            return calendar.date(from: components)!
        }
        let beijingZone = TimeZone(secondsFromGMT: 8 * 3600)!

        check("09:00 is pre-open", StockMarket.phase(at: date(2026, 11, 10, 9, 0, zone: beijingZone)) == .preOpen)
        check("09:20 is auction", StockMarket.phase(at: date(2026, 11, 10, 9, 20, zone: beijingZone)) == .auction)
        check("09:30 is trading", StockMarket.phase(at: date(2026, 11, 10, 9, 30, zone: beijingZone)) == .trading)
        check("12:00 is lunch", StockMarket.phase(at: date(2026, 11, 10, 12, 0, zone: beijingZone)) == .lunch)
        check("13:00 is trading", StockMarket.phase(at: date(2026, 11, 10, 13, 0, zone: beijingZone)) == .trading)
        check("14:59 is trading", StockMarket.phase(at: date(2026, 11, 10, 14, 59, zone: beijingZone)) == .trading)
        check("15:01 is closed", StockMarket.phase(at: date(2026, 11, 10, 15, 1, zone: beijingZone)) == .closed)
        check("a-share saturday is closed", StockMarket.phase(at: date(2026, 11, 14, 10, 0, zone: beijingZone)) == .holiday)

        let hkZone = StockMarketKind.hk.timeZone
        check("hk 15:59 is trading",
              StockMarket.phase(for: .hk, at: date(2026, 11, 10, 15, 59, zone: hkZone)) == .trading)
        check("hk 12:30 is lunch",
              StockMarket.phase(for: .hk, at: date(2026, 11, 10, 12, 30, zone: hkZone)) == .lunch)
        check("hk 16:01 is closed",
              StockMarket.phase(for: .hk, at: date(2026, 11, 10, 16, 1, zone: hkZone)) == .closed)
        check("hk sunday is closed",
              StockMarket.phase(for: .hk, at: date(2026, 11, 15, 11, 0, zone: hkZone)) == .holiday)

        let nyZone = StockMarketKind.us.timeZone
        check("us 10:00 is trading",
              StockMarket.phase(for: .us, at: date(2026, 11, 10, 10, 0, zone: nyZone)) == .trading)
        check("us 08:00 is pre-open",
              StockMarket.phase(for: .us, at: date(2026, 11, 10, 8, 0, zone: nyZone)) == .preOpen)
        check("us 16:30 is closed",
              StockMarket.phase(for: .us, at: date(2026, 11, 10, 16, 30, zone: nyZone)) == .closed)
        check("us saturday is closed",
              StockMarket.phase(for: .us, at: date(2026, 11, 14, 10, 0, zone: nyZone)) == .holiday)
        check("phase live flags", StockMarketPhase.trading.isLive && StockMarketPhase.auction.isLive
              && !StockMarketPhase.lunch.isLive && !StockMarketPhase.closed.isLive)

        // MARK: - Formatting
        check("price two decimals", StockFormat.price(1442.1) == "1442.10")
        check("price empty", StockFormat.price(0) == "—")
        check("signed percent plus", StockFormat.signedPercent(1.234) == "+1.23%")
        check("signed percent minus", StockFormat.signedPercent(-0.2) == "-0.20%")
        check("signed amount", StockFormat.signedAmount(7.57) == "+7.57")
        check("amount 万", StockFormat.amount(23705) == "2.37 亿")
        check("amount small", StockFormat.amount(2730) == "2730 万")
        check("amount empty", StockFormat.amount(0) == "—")
        check("cap", StockFormat.cap(18027.8) == "18028 亿")
        check("updated empty", StockFormat.updated(nil) == "尚未更新")
        check("updated clock", StockFormat.updated(Date(timeIntervalSince1970: 0)).count == 8)
        check("interval label seconds", StockFormat.intervalLabel(30) == "30 秒")
        check("interval label one minute", StockFormat.intervalLabel(60) == "1 分钟")
        check("interval label five minutes", StockFormat.intervalLabel(300) == "5 分钟")

        // MARK: - Watchlist persistence contract
        let suite = "DevKit.stocks.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let board = StockBoard(defaults: defaults)
        check("default watchlist", board.symbols == StockBoard.defaultSymbols)
        check("defaults cover three markets", Set(board.symbols.compactMap(StockMarketKind.kind(of:)))
              == Set([StockMarketKind.aShare, .hk, .us]))
        check("default interval", board.interval == 10)
        board.add("600519")
        check("duplicate add is rejected", board.error.contains("已经在自选"))
        board.add(symbol: "sz000002")
        check("add appends", board.symbols.last == "sz000002")
        check("symbols persisted", defaults.stringArray(forKey: StockBoard.watchlistKey)?.last == "sz000002")
        board.add("hkHSI")
        check("hk add resolves", board.symbols.contains("hkHSI"))
        board.add("aapl.oq")
        check("us add canonicalises", board.symbols.contains("usAAPL"))
        check("columns split by market", board.symbols(in: .hk).contains("hk00700"))
        board.moveToTop("sz000002")
        check("move to top", board.symbols.first == "sz000002")
        board.remove("sh000001")
        check("remove drops symbol", !board.symbols.contains("sh000001"))
        check("removal persisted", defaults.stringArray(forKey: StockBoard.watchlistKey)?.contains("sh000001") == false)

        board.interval = 300
        check("long interval accepted", board.interval == 300)
        check("long interval persisted", defaults.integer(forKey: StockBoard.intervalKey) == 300)
        board.interval = 45
        check("interval clamps to a supported value", board.interval == 10)
        check("rejected interval persists the sanitized value", defaults.integer(forKey: StockBoard.intervalKey) == 10)

        // MARK: - Batch edit contract
        board.beginEdit()
        check("batch draft prefilled", board.editDraft.split(separator: "\n").count == board.symbols.count)
        check("batch editor opened", board.isEditing)
        board.cancelEdit()
        check("batch cancel closes", !board.isEditing)

        board.editDraft = "600519\n00700\nAAPL\n茅台"
        board.applyEdit()
        check("batch replaces symbols", board.symbols == ["sh600519", "hk00700", "usAAPL"])
        check("batch closes the sheet", !board.isEditing)
        check("batch reports skipped tokens", board.info.contains("跳过 1 个"))
        check("batch persists", defaults.stringArray(forKey: StockBoard.watchlistKey) == ["sh600519", "hk00700", "usAAPL"])

        board.editDraft = "茅台 纳斯达克"
        board.applyEdit()
        check("batch with nothing usable keeps the list", board.symbols == ["sh600519", "hk00700", "usAAPL"])
        check("batch reports the failure", board.editNote.contains("没有识别到"))

        board.resetSymbols()
        check("reset restores defaults", board.symbols == StockBoard.defaultSymbols)
        board.add("茅台")
        check("name input asks for search", board.error.contains("A股 6 位"))
        board.stop()

        print("PASS: \(passed) stock quote assertions")
    }
}
