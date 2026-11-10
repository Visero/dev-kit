import SwiftUI
import AppKit

// MARK: - Tones
/// Red-up / green-down at a low key: the hue still carries the meaning, but the
/// saturation and contrast stay quiet so a wall of rows does not glare.
enum StockTone {
    static func dynamic(_ light: (r: CGFloat, g: CGFloat, b: CGFloat),
                        _ dark: (r: CGFloat, g: CGFloat, b: CGFloat)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let parts = isDark ? dark : light
            return NSColor(srgbRed: parts.r, green: parts.g, blue: parts.b, alpha: 1)
        })
    }

    static let up = dynamic((0.66, 0.27, 0.26), (0.78, 0.44, 0.42))
    static let down = dynamic((0.18, 0.46, 0.33), (0.38, 0.64, 0.49))
}

// MARK: - Page
struct StockPage: View {
    @ObservedObject var board: StockBoard

    var body: some View {
        VStack(spacing:12) {
            Panel {
                VStack(spacing:0) {
                    controlBar.padding(.horizontal,14).padding(.vertical,11)
                    if !board.hints.isEmpty || !board.hintError.isEmpty {
                        Divider().opacity(0.5)
                        suggestionList.padding(.horizontal,14).padding(.vertical,7)
                    }
                    if !board.error.isEmpty || !board.info.isEmpty {
                        Divider().opacity(0.5)
                        HStack(spacing:6) {
                            Image(systemName: board.error.isEmpty ? "info.circle" : "exclamationmark.triangle.fill")
                                .font(.system(size:10))
                            Text(board.error.isEmpty ? board.info : board.error)
                                .font(.system(size:10.5)).textSelection(.enabled).lineLimit(2)
                            Spacer(minLength:0)
                            Button { board.error = ""; board.info = "" } label: {
                                Image(systemName:"xmark").font(.system(size:9))
                            }.buttonStyle(.plain).foregroundStyle(.tertiary)
                        }
                        .foregroundStyle(board.error.isEmpty ? Color.secondary : Color.orange)
                        .padding(.horizontal,14).padding(.vertical,7)
                    }
                }
            }

            HStack(alignment:.top, spacing:12) {
                ForEach(StockMarketKind.allCases) { market in
                    StockColumn(market: market, board: board, scale: board.fontScale)
                }
            }
            .frame(maxHeight:.infinity)

            footer
        }
        .onAppear { board.start() }
        .onDisappear { board.stop() }
        .sheet(isPresented: $board.isEditing) { StockBatchEditor(board: board) }
    }

    private var controlBar: some View {
        HStack(spacing:9) {
            HStack(spacing:6) {
                Image(systemName:"magnifyingglass").font(.system(size:11)).foregroundStyle(.secondary)
                TextField("代码或名称，如 600519", text:$board.query)
                    .textFieldStyle(.plain)
                    .font(.system(size:12))
                    .onSubmit { board.add(board.query) }
                    .onChange(of: board.query) { _, value in board.search(value) }
                    .accessibilityLabel("添加自选：代码或名称")
                if !board.query.isEmpty {
                    Button { board.query = ""; board.hints = []; board.hintError = "" } label: {
                        Image(systemName:"xmark.circle.fill").font(.system(size:11)).foregroundStyle(.tertiary)
                    }.buttonStyle(.plain).accessibilityLabel("清空输入")
                }
            }
            .padding(.horizontal,9).padding(.vertical,6)
            .background(Color.primary.opacity(0.05),in:RoundedRectangle(cornerRadius:8))
            .frame(width:230)

            Button { board.add(board.query) } label: {
                Image(systemName:"plus").font(.system(size:11,weight:.semibold))
            }
            .buttonStyle(.borderless)
            .disabled(board.query.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
            .help("添加自选")
            .accessibilityLabel("添加自选")

            Spacer(minLength:8)

            HStack(spacing:3) {
                Button { board.zoomOut() } label: {
                    Text("A−").font(.system(size:10,weight:.semibold,design:.monospaced))
                        .frame(width:16,height:16)
                }
                .buttonStyle(.borderless)
                .disabled(!board.canZoomOut)
                .help("缩小行情字号")
                .accessibilityLabel("缩小行情字号")

                Button { board.zoomIn() } label: {
                    Text("A+").font(.system(size:11.5,weight:.semibold,design:.monospaced))
                        .frame(width:16,height:16)
                }
                .buttonStyle(.borderless)
                .disabled(!board.canZoomIn)
                .help("放大行情字号")
                .accessibilityLabel("放大行情字号")
            }

            Button { board.beginEdit() } label: {
                Label("批量编辑",systemImage:"slider.horizontal.3").font(.system(size:11))
            }
            .buttonStyle(.borderless)
            .help("一次粘贴或修改整份自选列表")
            .accessibilityLabel("批量编辑自选")

            Text(StockFormat.updated(board.lastUpdated))
                .font(.system(size:10,design:.monospaced)).foregroundStyle(.tertiary)
                .help("最近一次刷新时间")

            Picker("间隔",selection:$board.interval) {
                ForEach(StockBoard.intervalOptions, id:\.self) { seconds in
                    Text(StockFormat.intervalLabel(seconds)).tag(seconds)
                }
            }
            .labelsHidden().pickerStyle(.menu).frame(width:92)
            .help("自动刷新间隔")

            Button { board.refresh() } label: {
                if board.loading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName:"arrow.clockwise").font(.system(size:11))
                }
            }
            .buttonStyle(.borderless)
            .disabled(board.loading)
            .help("立即刷新")
            .accessibilityLabel("立即刷新行情")
        }
    }

    private var suggestionList: some View {
        VStack(alignment:.leading,spacing:2) {
            if board.hintError.isEmpty {
                ForEach(board.hints) { hint in
                    Button {
                        board.add(symbol:hint.symbol)
                    } label: {
                        HStack(spacing:8) {
                            Text(hint.market.rawValue)
                                .font(.system(size:9)).foregroundStyle(.tertiary)
                                .frame(width:26,alignment:.leading)
                            Text(hint.name).font(.system(size:12,weight:.medium)).lineLimit(1)
                            Text(hint.code).font(.system(size:10,design:.monospaced)).foregroundStyle(.secondary)
                            Spacer(minLength:0)
                        }
                        .padding(.vertical,4).padding(.horizontal,6)
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            } else {
                Text(board.hintError).font(.system(size:11)).foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack(spacing:8) {
            Text("行情来自腾讯公开接口，本机直连，无账号、无上传；数据可能有延迟，不构成投资建议。")
                .font(.system(size:10)).foregroundStyle(.tertiary).lineLimit(1)
            Spacer(minLength:6)
            if !board.symbols.isEmpty {
                Button("恢复默认自选") { board.resetSymbols() }
                    .buttonStyle(.plain).font(.system(size:10)).foregroundStyle(.tertiary)
            }
        }
    }
}

final class StockPageState: ObservableObject {
    @Published var hovered: String?
}

// MARK: - Column
private struct StockColumn: View {
    let market: StockMarketKind
    @ObservedObject var board: StockBoard
    let scale: CGFloat

    var body: some View {
        let symbols = board.symbols(in: market)
        let phase = board.phase(for: market)
        Panel {
            VStack(spacing:0) {
                HStack(spacing:5) {
                    Text(market.rawValue).font(.system(size:11 * scale,weight:.semibold))
                    Text("\(symbols.count)")
                        .font(.system(size:9 * scale,design:.monospaced)).foregroundStyle(.tertiary)
                    Spacer(minLength:0)
                    Circle().fill(phase.isLive ? Color.teal.opacity(0.85) : Color.secondary.opacity(0.45))
                        .frame(width:5,height:5)
                    Text(phase.rawValue).font(.system(size:9.5 * scale))
                        .foregroundStyle(phase.isLive ? Color.teal : Color.secondary)
                }
                .padding(.horizontal,12 * scale).padding(.top,10).padding(.bottom,8)
                .help("按该交易所本地时间判断盘中 / 午间休市 / 已收盘；不区分法定节假日")

                Divider().opacity(0.5)

                if symbols.isEmpty {
                    VStack(spacing:5) {
                        Text("暂无自选").font(.system(size:10.5 * scale)).foregroundStyle(.tertiary)
                        Text(market.hint).font(.system(size:9.5 * scale)).foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth:.infinity,maxHeight:.infinity).padding(.vertical,24)
                } else {
                    ScrollView {
                        LazyVStack(spacing:0) {
                            ForEach(Array(symbols.enumerated()), id:\.element) { index, symbol in
                                if index > 0 { Divider().padding(.leading,12 * scale) }
                                StockRow(
                                    symbol: symbol,
                                    quote: board.quotes[symbol],
                                    scale: scale,
                                    onRemove: { board.remove(symbol) },
                                    onMoveTop: { board.moveToTop(symbol) }
                                )
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth:.infinity,maxHeight:.infinity)
    }
}

// MARK: - Row
private struct StockRow: View {
    let symbol: String
    let quote: StockQuote?
    let scale: CGFloat
    let onRemove: () -> Void
    let onMoveTop: () -> Void
    @StateObject private var state = RowState()

    private var tint: Color {
        guard let quote = quote, quote.hasPrice else { return .secondary }
        if quote.isUp { return StockTone.up }
        if quote.isDown { return StockTone.down }
        return .secondary
    }

    /// Secondary annotations grow slower than the name and price: at the top
    /// zoom steps they would otherwise crowd the price column and truncate.
    private var secondaryScale: CGFloat { min(scale, 1.25) }
    private var annotationScale: CGFloat { min(scale, 1.3) }

    var body: some View {
        VStack(spacing:5 * scale) {
            HStack(spacing:6 * scale) {
                VStack(alignment:.leading,spacing:2 * scale) {
                    HStack(spacing:4) {
                        Text(quote?.name ?? "加载中…")
                            .font(.system(size:11.5 * scale,weight:.semibold)).lineLimit(1)
                        if quote?.isIndex == true {
                            Text("指数").font(.system(size:8 * scale)).foregroundStyle(.tertiary)
                                .padding(.horizontal,3)
                                .background(Color.primary.opacity(0.06),in:Capsule())
                                .fixedSize()
                        }
                    }
                    Text(secondaryLine).font(.system(size:9 * secondaryScale,design:.monospaced)).foregroundStyle(.tertiary).lineLimit(1)
                }
                Spacer(minLength:4)
                VStack(alignment:.trailing,spacing:1) {
                    Text(quote.map { StockFormat.price($0.price) } ?? "—")
                        .font(.system(size:12.5 * scale,weight:.semibold,design:.rounded))
                        .monospacedDigit().foregroundStyle(tint).lineLimit(1)
                    Text(changeLine).font(.system(size:9 * annotationScale,design:.monospaced)).monospacedDigit()
                        .foregroundStyle(quote?.hasPrice == true ? tint.opacity(0.72) : Color.secondary.opacity(0.55))
                        .lineLimit(1)
                }
                Button(action:onRemove) {
                    Image(systemName:"trash").font(.system(size:10 * scale)).foregroundStyle(.secondary)
                        .frame(width:12,height:14)
                }
                .buttonStyle(.plain)
                .opacity(state.hovered ? 1 : 0.22)
                .help("从自选移除")
                .accessibilityLabel("移除 \(quote?.name ?? symbol)")
            }
            StockRangeBar(quote: quote, tint: tint)
        }
        .padding(.horizontal,12 * scale).padding(.vertical,7 * scale)
        .background(state.hovered ? Color.primary.opacity(0.035) : Color.clear)
        .contentShape(Rectangle())
        .onHover { state.hovered = $0 }
        .contextMenu {
            Button("移到最前") { onMoveTop() }
            Divider()
            Button("从自选移除") { onRemove() }
        }
        .help(detailLine)
        .accessibilityElement(children:.combine)
        .accessibilityLabel(accessibilityText)
    }

    private var secondaryLine: String {
        guard let quote = quote else { return symbol.uppercased() }
        var parts = [quote.displaySymbol]
        if quote.open > 0 { parts.append("开 \(StockFormat.price(quote.open))") }
        // The 昨收 tick is the first thing to go once the type grows: at the top
        // zoom steps it would push the line past the column width.
        if quote.prevClose > 0, scale <= 1.17 { parts.append("昨 \(StockFormat.price(quote.prevClose))") }
        return parts.joined(separator:"  ")
    }

    private var changeLine: String {
        guard let quote = quote else { return "" }
        guard quote.hasPrice else { return "停牌 / 无成交" }
        return "\(StockFormat.signedAmount(quote.change))  \(StockFormat.signedPercent(quote.changePercent))"
    }

    private var detailLine: String {
        guard let quote = quote else { return symbol.uppercased() }
        return [
            "\(quote.market.rawValue) \(quote.displaySymbol)",
            "最低 \(StockFormat.price(quote.low))",
            "最高 \(StockFormat.price(quote.high))",
            quote.market == .aShare || !quote.isIndex ? "成交额 \(StockFormat.amount(quote.amountWan))" : nil,
            quote.isIndex || quote.turnoverPercent == 0 ? nil : "换手 \(String(format:"%.2f%%",quote.turnoverPercent))",
            quote.isIndex || quote.marketCapYi == 0 ? nil : "市值 \(StockFormat.cap(quote.marketCapYi))",
            quote.isIndex ? nil : (quote.pe > 0 ? "市盈 \(String(format:"%.2f",quote.pe))" : nil),
            quote.stamp.isEmpty ? nil : quote.stamp
        ].compactMap { $0 }.joined(separator:" · ")
    }

    private var accessibilityText: String {
        guard let quote = quote else { return "\(symbol) 加载中" }
        return "\(quote.name)，现价 \(StockFormat.price(quote.price))，\(StockFormat.signedPercent(quote.changePercent))"
    }
}

private final class RowState: ObservableObject {
    @Published var hovered = false
}

// MARK: - Intraday band
/// Draws today's low–high band with the latest price marked, plus a faint
/// reference tick at yesterday's close. No minute series is fetched, so this
/// stays correct even when the minute endpoint is unavailable.
private struct StockRangeBar: View {
    let quote: StockQuote?
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 20)
            ZStack(alignment:.leading) {
                Capsule().fill(Color.primary.opacity(0.07)).frame(height:2.5)
                if let quote, quote.hasPrice {
                    if quote.prevClose > 0, quote.high > quote.low {
                        let prev = min(1,max(0,(quote.prevClose - quote.low)/(quote.high - quote.low)))
                        Rectangle().fill(Color.secondary.opacity(0.30))
                            .frame(width:1,height:7)
                            .offset(x:min(width * prev, width - 1))
                    }
                    let position = quote.dayPosition ?? 0.5
                    Capsule().fill(tint.opacity(0.18)).frame(width:max(width * position,1),height:2.5)
                    Circle().fill(tint).frame(width:5,height:5)
                        .offset(x:min(max(width * position - 2.5,0),width - 5))
                }
            }
            .frame(height:7,alignment:.leading)
        }
        .frame(height:7)
        .accessibilityHidden(true)
    }
}

// MARK: - Batch editor
private struct StockBatchEditor: View {
    @ObservedObject var board: StockBoard

    private var preview: (symbols: [String], rejected: [String]) {
        StockParser.parseList(board.editDraft)
    }

    var body: some View {
        let parsed = preview
        VStack(alignment:.leading, spacing:11) {
            Text("批量编辑自选").font(.system(size:14,weight:.semibold))
            Text("一行一个代码，也可以用逗号或空格分隔。A股 6 位（600519）、港股 5 位（00700）、美股字母代码（AAPL）；也认 sh/sz/bj/hk/us 前缀写法。识别不了的行会跳过，不会猜。")
                .font(.system(size:10.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal:false,vertical:true)

            TextEditor(text:$board.editDraft)
                .font(.system(size:11,design:.monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color.primary.opacity(0.05),in:RoundedRectangle(cornerRadius:8))
                .overlay(RoundedRectangle(cornerRadius:8).stroke(Color.primary.opacity(0.07),lineWidth:1))
                .frame(height:180)

            HStack(spacing:6) {
                Text("识别到 \(parsed.symbols.count) 个").font(.system(size:10,design:.monospaced)).foregroundStyle(.tertiary)
                if !parsed.rejected.isEmpty {
                    Text("· 跳过 \(parsed.rejected.count) 个").font(.system(size:10)).foregroundStyle(.orange)
                }
                Spacer(minLength:8)
                Button("取消") { board.cancelEdit() }
                    .keyboardShortcut(.cancelAction)
                Button("应用") { board.applyEdit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(parsed.symbols.isEmpty)
            }
            if !board.editNote.isEmpty {
                Text(board.editNote).font(.system(size:10.5)).foregroundStyle(.orange)
            }
        }
        .padding(18).frame(width:460)
    }
}
