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

    static func main() {
        // MARK: - Symbol normalisation
        check("normalize sh code", StockParser.normalize("600519") == "sh600519")
        check("normalize sz code", StockParser.normalize("000001") == "sz000001")
        check("normalize explicit sh index", StockParser.normalize("sh000001") == "sh000001")
        check("normalize uppercase prefix", StockParser.normalize("SH600519") == "sh600519")
        check("normalize padded input", StockParser.normalize("  sz399001 \n") == "sz399001")
        check("normalize bj code", StockParser.normalize("830799") == "bj830799")
        check("normalize rejects short code", StockParser.normalize("60051") == nil)
        check("normalize rejects letters", StockParser.normalize("60051x") == nil)
        check("normalize rejects name", StockParser.normalize("茅台") == nil)
        check("normalize rejects bad prefix", StockParser.normalize("hk00700") == nil)

        // MARK: - Payload splitting
        let entries = StockParser.entries(quotePayload)
        check("payload yields two entries", entries.count == 2)
        check("payload keeps symbol keys", entries.map(\.symbol) == ["sh000001", "sh600519"])
        check("payload ignores junk", StockParser.entries("garbage without equal sign").isEmpty)

        // MARK: - Quote fields
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
        check("index flagged as index", index.isIndex)
        check("index stamp formatted", index.stamp == "2026-11-10 14:20:39")
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

        // MARK: - Day position
        let position = stock.dayPosition
        check("day position exists", position != nil)
        check("day position in range", (position ?? -1) >= 0 && (position ?? 2) <= 1)
        let expected = (1442.13 - 1431.26) / (1443.88 - 1431.26)
        check("day position matches the band", abs((position ?? 0) - expected) < 0.0001)
        let flat = StockQuote(symbol: "sh600519", name: "贵州茅台", price: 0, prevClose: 1444.99, open: 0,
                          high: 0, low: 0, volumeLots: 0, amountWan: 0, change: 0, changePercent: 0,
                          turnoverPercent: 0, pe: 0, marketCapYi: 0, stamp: "", isIndex: false)
        check("suspended quote has no price", !flat.hasPrice)
        check("suspended quote has no position", flat.dayPosition == nil)
        let oneTick = StockQuote(symbol: "sh600519", name: "x", price: 10, prevClose: 10, open: 10,
                             high: 10, low: 10, volumeLots: 1, amountWan: 1, change: 0, changePercent: 0,
                             turnoverPercent: 0, pe: 0, marketCapYi: 0, stamp: "", isIndex: false)
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

        // MARK: - Search hints
        let hintPayload = #"v_hint="sh~600519~\u8d35\u5dde\u8305\u53f0~gzmt~GP-A^sz~000001~\u5e73\u5b89\u94f6\u884c~payh~GP-A""#
        let hints = StockParser.hints(fromPayload: hintPayload)
        check("two hints", hints.count == 2)
        check("hint symbol", hints.first?.symbol == "sh600519")
        check("hint name decoded", hints.first?.name == "贵州茅台")
        check("hint kind", hints.first?.kind == "GP-A")
        check("second hint", hints.count == 2 && hints[1].name == "平安银行")
        check("plain text survives", StockParser.unicodeEscapes("plain") == "plain")
        check("broken escape survives", StockParser.unicodeEscapes("\\x41") == "\\x41")
        check("mixed escapes", StockParser.unicodeEscapes("a\\u0041b") == "aAb")
        check("hint rejects unknown market", StockParser.hints(fromPayload: #"v_hint="us~AAPL~Apple~aapl~GP-US""#).isEmpty)
        check("hint without equal", StockParser.hints(fromPayload: "v_hint").isEmpty)

        // MARK: - Market phase (Beijing time)
        func beijing(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
            var components = DateComponents()
            components.year = year; components.month = month; components.day = day
            components.hour = hour; components.minute = minute
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
            return calendar.date(from: components)!
        }
        check("09:00 is pre-open", StockMarket.phase(at: beijing(2026, 11, 10, 9, 0)) == .preOpen)
        check("09:20 is auction", StockMarket.phase(at: beijing(2026, 11, 10, 9, 20)) == .auction)
        check("09:30 is trading", StockMarket.phase(at: beijing(2026, 11, 10, 9, 30)) == .trading)
        check("12:00 is lunch", StockMarket.phase(at: beijing(2026, 11, 10, 12, 0)) == .lunch)
        check("13:00 is trading", StockMarket.phase(at: beijing(2026, 11, 10, 13, 0)) == .trading)
        check("14:59 is trading", StockMarket.phase(at: beijing(2026, 11, 10, 14, 59)) == .trading)
        check("15:01 is closed", StockMarket.phase(at: beijing(2026, 11, 10, 15, 1)) == .closed)
        check("saturday is closed", StockMarket.phase(at: beijing(2026, 11, 14, 10, 0)) == .holiday)
        check("sunday is closed", StockMarket.phase(at: beijing(2026, 11, 15, 10, 0)) == .holiday)
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

        // MARK: - Watchlist persistence contract
        let suite = "DevKit.stocks.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let board = StockBoard(defaults: defaults)
        check("default watchlist", board.symbols == StockBoard.defaultSymbols)
        check("default interval", board.interval == 10)
        board.add("600519")
        check("duplicate add is rejected", board.error.contains("已经在自选"))
        board.add(symbol: "sz000002")
        check("add appends", board.symbols.last == "sz000002")
        check("symbols persisted", defaults.stringArray(forKey: StockBoard.watchlistKey)?.last == "sz000002")
        board.moveToTop("sz000002")
        check("move to top", board.symbols.first == "sz000002")
        board.remove("sh000001")
        check("remove drops symbol", !board.symbols.contains("sh000001"))
        check("removal persisted", defaults.stringArray(forKey: StockBoard.watchlistKey)?.contains("sh000001") == false)
        board.interval = 30
        check("interval persisted", defaults.integer(forKey: StockBoard.intervalKey) == 30)
        board.interval = 7
        check("interval clamps to a supported value", board.interval == 10)
        check("rejected interval persists the sanitized value", defaults.integer(forKey: StockBoard.intervalKey) == 10)
        board.resetSymbols()
        check("reset restores defaults", board.symbols == StockBoard.defaultSymbols)
        board.add("茅台")
        check("name input asks for search", board.error.contains("6 位代码"))
        board.stop()

        print("PASS: \(passed) stock quote assertions")
    }
}
