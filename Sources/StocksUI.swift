import SwiftUI
import AppKit

// MARK: - Page
struct StockPage: View {
    @ObservedObject var board: StockBoard
    @StateObject private var ui = StockPageState()

    var body: some View {
        VStack(spacing:14) {
            Panel {
                VStack(spacing:0) {
                    controlBar.padding(.horizontal,14).padding(.vertical,12)
                    if !board.hints.isEmpty || !board.hintError.isEmpty {
                        Divider().opacity(0.5)
                        suggestionList.padding(.horizontal,14).padding(.vertical,8)
                    }
                    if !board.error.isEmpty {
                        Divider().opacity(0.5)
                        HStack(spacing:6) {
                            Image(systemName:"exclamationmark.triangle.fill").font(.system(size:11))
                            Text(board.error).font(.system(size:11)).textSelection(.enabled)
                            Spacer()
                        }.foregroundStyle(.orange).padding(.horizontal,14).padding(.vertical,8)
                    }
                }
            }
            Panel {
                if board.symbols.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVStack(spacing:0) {
                            ForEach(Array(board.symbols.enumerated()), id:\.element) { index, symbol in
                                if index > 0 { Divider().padding(.leading,14) }
                                StockRow(
                                    symbol: symbol,
                                    quote: board.quotes[symbol],
                                    onRemove: { board.remove(symbol) },
                                    onMoveTop: { board.moveToTop(symbol) }
                                )
                            }
                        }
                    }
                }
            }
            HStack(spacing:8) {
                Text("行情来自腾讯公开接口，本机直连，无账号、无上传；数据可能有延迟，不构成投资建议。")
                    .font(.system(size:10)).foregroundStyle(.tertiary)
                Spacer()
                if !board.symbols.isEmpty {
                    Button("恢复默认自选") { board.resetSymbols() }
                        .buttonStyle(.plain).font(.system(size:10)).foregroundStyle(.tertiary)
                }
            }
        }
        .onAppear { board.start() }
        .onDisappear { board.stop() }
    }

    private var controlBar: some View {
        HStack(spacing:10) {
            HStack(spacing:6) {
                Image(systemName:"magnifyingglass").font(.system(size:11)).foregroundStyle(.secondary)
                TextField("代码或名称，如 600519、茅台", text:$board.query)
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
            .padding(.horizontal,10).padding(.vertical,7)
            .background(Color.primary.opacity(0.05),in:RoundedRectangle(cornerRadius:8))
            .frame(width:250)

            Button { board.add(board.query) } label: {
                Label("添加",systemImage:"plus").font(.system(size:12))
            }
            .disabled(board.query.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)

            Spacer()

            HStack(spacing:6) {
                Circle().fill(board.phase.isLive ? Color.teal : Color.secondary.opacity(0.5))
                    .frame(width:6,height:6)
                Text(board.phase.rawValue).font(.system(size:11,weight:.medium)).foregroundStyle(board.phase.isLive ? Color.teal : Color.secondary)
            }
            .help("按北京时间判断盘中 / 午间休市 / 已收盘；不区分法定节假日")

            Text("更新 \(StockFormat.updated(board.lastUpdated))")
                .font(.system(size:10,design:.monospaced)).foregroundStyle(.tertiary)

            Picker("间隔",selection:$board.interval) {
                Text("5 秒").tag(5)
                Text("10 秒").tag(10)
                Text("30 秒").tag(30)
            }
            .labelsHidden().pickerStyle(.menu).frame(width:86)
            .help("刷新间隔")

            Button { board.refresh() } label: {
                if board.loading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName:"arrow.clockwise")
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
                            Text(hint.name).font(.system(size:12,weight:.medium))
                            Text(hint.symbol.uppercased()).font(.system(size:10,design:.monospaced)).foregroundStyle(.secondary)
                            Spacer()
                            Text(hint.kind).font(.system(size:9)).foregroundStyle(.tertiary)
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

    private var emptyState: some View {
        VStack(spacing:10) {
            Image(systemName:"chart.line.uptrend.xyaxis").font(.system(size:26)).foregroundStyle(.tertiary)
            Text("还没有自选").font(.system(size:13,weight:.medium))
            Text("在上方输入 6 位代码或股票名称，回车或点「添加」。").font(.system(size:11)).foregroundStyle(.secondary)
            Button("恢复默认自选") { board.resetSymbols() }.font(.system(size:11))
        }
        .frame(maxWidth:.infinity).padding(.vertical,48)
    }
}

final class StockPageState: ObservableObject {
    @Published var hovered: String?
}

// MARK: - Row
private struct StockRow: View {
    let symbol: String
    let quote: StockQuote?
    let onRemove: () -> Void
    let onMoveTop: () -> Void
    @StateObject private var state = RowState()

    private var tint: Color {
        guard let quote = quote, quote.hasPrice else { return .secondary }
        if quote.isUp { return .red }
        if quote.isDown { return .green }
        return .secondary
    }

    var body: some View {
        HStack(spacing:12) {
            VStack(alignment:.leading,spacing:3) {
                HStack(spacing:6) {
                    Text(quote?.name ?? "加载中…").font(.system(size:14,weight:.semibold)).lineLimit(1)
                    if let quote = quote, quote.isIndex {
                        Text("指数").font(.system(size:9)).foregroundStyle(.tertiary)
                            .padding(.horizontal,4).padding(.vertical,1)
                            .background(Color.primary.opacity(0.06),in:Capsule())
                    }
                }
                Text(secondaryLine).font(.system(size:10,design:.monospaced)).foregroundStyle(.tertiary).lineLimit(1)
            }
            .frame(width:296,alignment:.leading)

            if let quote = quote, quote.hasPrice {
                StockRangeBar(quote:quote, tint:tint).frame(height:26)
                    .frame(maxWidth:.infinity)
            } else {
                Rectangle().fill(Color.primary.opacity(0.04)).frame(height:3)
                    .frame(maxWidth:.infinity).padding(.horizontal,8)
            }

            VStack(alignment:.trailing,spacing:2) {
                Text(quote.map { StockFormat.price($0.price) } ?? "—")
                    .font(.system(size:17,weight:.semibold,design:.rounded))
                    .monospacedDigit().foregroundStyle(tint)
                Text(changeLine).font(.system(size:10,design:.monospaced)).monospacedDigit().foregroundStyle(tint.opacity(quote?.hasPrice == true ? 0.85 : 0.4))
            }
            .frame(width:118,alignment:.trailing)

            Button(action:onRemove) {
                Image(systemName:"trash").font(.system(size:12)).foregroundStyle(.secondary)
                    .frame(width:18,height:18)
            }
            .buttonStyle(.plain)
            .opacity(state.hovered ? 1 : 0.25)
            .help("从自选移除")
            .accessibilityLabel("移除 \(quote?.name ?? symbol)")
        }
        .padding(.horizontal,14).padding(.vertical,10)
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
        if quote.open > 0 { parts.append("今开 \(StockFormat.price(quote.open))") }
        if quote.prevClose > 0 { parts.append("昨收 \(StockFormat.price(quote.prevClose))") }
        return parts.joined(separator:"  ·  ")
    }

    private var changeLine: String {
        guard let quote = quote else { return "" }
        guard quote.hasPrice else { return "停牌 / 无成交" }
        return "\(StockFormat.signedAmount(quote.change))  \(StockFormat.signedPercent(quote.changePercent))"
    }

    private var detailLine: String {
        guard let quote = quote else { return symbol.uppercased() }
        return [
            "最低 \(StockFormat.price(quote.low))",
            "最高 \(StockFormat.price(quote.high))",
            "成交额 \(StockFormat.amount(quote.amountWan))",
            quote.isIndex ? nil : "换手 \(String(format:"%.2f%%",quote.turnoverPercent))",
            quote.isIndex ? nil : "市值 \(StockFormat.cap(quote.marketCapYi))",
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
    let quote: StockQuote
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width - 104, 30)
            let position = quote.dayPosition ?? 0.5
            HStack(spacing:5) {
                Text(StockFormat.price(quote.low))
                    .font(.system(size:9,design:.monospaced)).monospacedDigit().foregroundStyle(.tertiary)
                    .lineLimit(1).fixedSize()
                    .frame(width:46,alignment:.leading)
                ZStack(alignment:.leading) {
                    Capsule().fill(Color.primary.opacity(0.07)).frame(height:3)
                    if quote.prevClose > 0, quote.high > quote.low {
                        let prev = min(1,max(0,(quote.prevClose - quote.low)/(quote.high - quote.low)))
                        Rectangle().fill(Color.secondary.opacity(0.35))
                            .frame(width:1,height:9)
                            .offset(x:width * prev)
                    }
                    Capsule().fill(tint.opacity(0.22)).frame(width:max(width * position,1),height:3)
                    Circle().fill(tint).frame(width:6,height:6)
                        .offset(x:min(max(width * position - 3,0),width - 6))
                }
                .frame(width:width,height:10)
                Text(StockFormat.price(quote.high))
                    .font(.system(size:9,design:.monospaced)).monospacedDigit().foregroundStyle(.tertiary)
                    .lineLimit(1).fixedSize()
                    .frame(width:46,alignment:.trailing)
            }
        }
        .accessibilityHidden(true)
    }
}
