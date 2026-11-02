import SwiftUI
import AppKit

extension Notification.Name {
    static let devKitSelectPage = Notification.Name("DevKit.selectPage")
}

@main
struct DevKitApp: App {
    @StateObject private var store = ToolkitStore()
    var body: some Scene {
        WindowGroup("DevKit · 开发工具箱") {
            RootView(store:store).frame(minWidth:940,minHeight:660)
                .preferredColorScheme(store.appearance == "dark" ? .dark : store.appearance == "light" ? .light : nil)
        }
        .defaultSize(width:1200,height:820).windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing:.newItem) { }
            CommandMenu("工具") {
                ForEach(Array(ToolkitStore.savedOrder().enumerated()), id: \.element) { idx, page in
                    Button(page.title) {
                        // We need to update the store; this is a bit hacky but works via NotificationCenter
                        NotificationCenter.default.post(name: .devKitSelectPage, object: page)
                    }
                    .keyboardShortcut(KeyEquivalent(Character(String(idx+1))), modifiers:.command)
                }
            }
        }
    }
}
enum ToolPage: String, CaseIterable, Identifiable, Sendable {
    case diff, json, epoch, clock
    var id: String { rawValue }
    var title: String {
        switch self {
        case .diff: return "代码 Diff"
        case .json: return "JSON 格式化"
        case .epoch: return "Unix 时间戳"
        case .clock: return "UTC 时钟"
        }
    }
    var symbol: String {
        switch self {
        case .diff: return "arrow.left.arrow.right"
        case .json: return "curlybraces"
        case .epoch: return "clock.arrow.2.circlepath"
        case .clock: return "globe"
        }
    }
    var subtitle: String {
        switch self {
        case .diff: return "并排比较两段代码，变化一目了然。"
        case .json: return "整理与校验 JSON，保留每一位数字。"
        case .epoch: return "在 Unix 时间戳与日期之间精确转换。"
        case .clock: return "同时查看 UTC 与北京时间，掌握距离下班的每一秒。"
        }
    }
    var eyebrow: String {
        switch self {
        case .diff: return "COMPARE"
        case .json: return "FORMAT"
        case .epoch: return "CONVERT"
        case .clock: return "WORLD TIME"
        }
    }
    static let defaultOrder: [ToolPage] = [.clock, .diff, .json, .epoch]
}
final class ToolkitStore: ObservableObject {
    @Published var page: ToolPage = .clock
    @Published var appearance=UserDefaults.standard.string(forKey:"DevKit.appearance") ?? "system" {
        didSet { UserDefaults.standard.set(appearance,forKey:"DevKit.appearance") }
    }
    @Published var savedOffset=UserDefaults.standard.string(forKey:"DevKit.utcOffset") ?? "0" {
        didSet { UserDefaults.standard.set(savedOffset,forKey:"DevKit.utcOffset") }
    }
    @Published var workEndTime: String = {
        let saved = UserDefaults.standard.string(forKey:"DevKit.workEndTime") ?? WorkdayCountdown.defaultTime
        return (try? WorkdayCountdown.parseTime(saved)) != nil ? saved : WorkdayCountdown.defaultTime
    }() {
        didSet { UserDefaults.standard.set(workEndTime,forKey:"DevKit.workEndTime") }
    }
    @Published var toolOrder: [ToolPage] = {
        let saved = UserDefaults.standard.stringArray(forKey: "DevKit.toolOrder") ?? []
        if saved.isEmpty { return ToolPage.defaultOrder }
        let all = ToolPage.allCases
        var result: [ToolPage] = []
        for raw in saved {
            if let p = ToolPage(rawValue: raw), !result.contains(p) {
                result.append(p)
            }
        }
        for p in all where !result.contains(p) {
            result.append(p)
        }
        return result
    }() {
        didSet {
            UserDefaults.standard.set(toolOrder.map { $0.rawValue }, forKey: "DevKit.toolOrder")
        }
    }
    func position(of page: ToolPage) -> Int {
        toolOrder.firstIndex(of: page) ?? 0
    }
    func movePage(from source: IndexSet, to destination: Int) {
        toolOrder.move(fromOffsets: source, toOffset: destination)
    }
    static func savedOrder() -> [ToolPage] {
        let saved = UserDefaults.standard.stringArray(forKey: "DevKit.toolOrder") ?? []
        if saved.isEmpty { return ToolPage.defaultOrder }
        let all = ToolPage.allCases
        var result: [ToolPage] = []
        for raw in saved {
            if let p = ToolPage(rawValue: raw), !result.contains(p) {
                result.append(p)
            }
        }
        for p in all where !result.contains(p) {
            result.append(p)
        }
        return result
    }
    private var cancellable: Any?
    init() {
        cancellable = NotificationCenter.default.addObserver(forName: .devKitSelectPage, object: nil, queue: .main) { note in
            if let page = note.object as? ToolPage {
                DispatchQueue.main.async { self.page = page }
            }
        }
    }
    @Published var left=""
    @Published var right=""
    @Published var diffResult: DiffResult?
    @Published var diffError=""
    @Published var diffBusy=false
    @Published var ignoreWhitespace=false
    var diffGeneration=UUID()
    @Published var jsonInput=""
    @Published var jsonOutput=""
    @Published var jsonError=""
    @Published var jsonStatus=""
    @Published var jsonIndent="2"
    @Published var jsonBusy=false
    var jsonGeneration=UUID()
    @Published var epochInput=""
    @Published var dateInput=""
    @Published var epochUnit: EpochUnit = .seconds
    @Published var epochResult=""
    @Published var dateResult=""
    @Published var epochError=""
    @Published var dateError=""
    func compare() {
        let a=left,b=right,ignore=ignoreWhitespace,id=UUID()
        diffGeneration=id; diffBusy=true; diffError=""; diffResult=nil
        DispatchQueue.global(qos:.userInitiated).async {
            let result=Result { try DiffEngine.compare(a,b,ignoreWhitespace:ignore) }
            DispatchQueue.main.async {
                guard self.diffGeneration==id else { return }
                self.diffBusy=false
                switch result { case .success(let value):self.diffResult=value; case .failure(let error):self.diffError=error.localizedDescription }
            }
        }
    }
    func invalidateDiff() { diffGeneration=UUID(); diffBusy=false; diffResult=nil; diffError="" }
    func formatJSON(compact: Bool) {
        let text=jsonInput,indent=jsonIndent == "tab" ? "\t" : String(repeating:" ",count:Int(jsonIndent) ?? 2),id=UUID()
        jsonGeneration=id; jsonBusy=true; jsonError=""; jsonOutput=""; jsonStatus=""
        DispatchQueue.global(qos:.userInitiated).async {
            let result=Result { try JSONTools.format(text,indent:indent,compact:compact) }
            DispatchQueue.main.async {
                guard self.jsonGeneration==id else { return }
                self.jsonBusy=false
                switch result {
                case .success(let output):self.jsonOutput=output;self.jsonStatus=compact ? "有效 JSON · 已压缩" : "有效 JSON · 已格式化"
                case .failure(let error):self.jsonError=error.localizedDescription
                }
            }
        }
    }
    func invalidateJSON() { jsonGeneration=UUID();jsonBusy=false;jsonOutput="";jsonStatus="";jsonError="" }
}

struct RootView: View {
    @ObservedObject var store: ToolkitStore
    var body: some View {
        NavigationSplitView {
            VStack(alignment:.leading,spacing:24) {
                HStack(spacing:12) {
                    Image(systemName:"square.stack.3d.up.fill").font(.system(size:26,weight:.medium)).foregroundStyle(.teal)
                    VStack(alignment:.leading,spacing:2) {
                        Text("DevKit").font(.system(size:25,weight:.bold,design:.rounded))
                        Text("开发者的随手工具箱").font(.system(size:11)).foregroundStyle(.secondary)
                    }
                }.padding(.horizontal,18).padding(.top,32)
                List {
                    ForEach(Array(store.toolOrder.enumerated()), id: \.element) { idx, page in
                        Button { store.page=page } label: {
                            HStack(spacing:11) {
                                Image(systemName:page.symbol).frame(width:22).font(.system(size:17,weight:.medium))
                                Text(page.title).font(.system(size:14,weight:store.page==page ? .semibold : .regular))
                                Spacer()
                                Text("⌘\(idx+1)").font(.system(size:10,design:.monospaced)).opacity(0.6)
                            }.padding(.horizontal,13).padding(.vertical,13)
                            .foregroundStyle(store.page==page ? Color.white : Color.primary)
                            .background(store.page==page ? Color.teal : Color.clear,in:RoundedRectangle(cornerRadius:12))
                        }.buttonStyle(.plain).accessibilityLabel(page.title)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .contextMenu {
                                Button {
                                    if idx > 0 {
                                        store.movePage(from: IndexSet(integer: idx), to: idx)
                                    }
                                } label: {
                                    Label("上移", systemImage: "arrow.up")
                                }.disabled(idx == 0)
                                Button {
                                    if idx < store.toolOrder.count - 1 {
                                        store.movePage(from: IndexSet(integer: idx), to: idx + 1)
                                    }
                                } label: {
                                    Label("下移", systemImage: "arrow.down")
                                }.disabled(idx == store.toolOrder.count - 1)
                                Divider()
                                Button {
                                    store.toolOrder = ToolPage.defaultOrder
                                } label: {
                                    Label("恢复默认顺序", systemImage: "arrow.counterclockwise")
                                }
                            }
                    }
                    .onMove { source, destination in
                        store.movePage(from: source, to: destination)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .padding(.horizontal,10)
                Spacer()
                VStack(alignment:.leading,spacing:9) {
                    Label("仅在本机处理",systemImage:"lock.shield").font(.system(size:12,weight:.medium))
                    Text("无账号 · 无上传 · 无打扰").font(.system(size:11)).foregroundStyle(.secondary)
                    Divider().padding(.vertical,5)
                    Text("DEVKIT  /  \(Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "—")").font(.system(size:10,weight:.medium,design:.monospaced)).tracking(1.5).foregroundStyle(.tertiary)
                }.padding(20)
            }.navigationSplitViewColumnWidth(min:218,ideal:232,max:270)
        } detail: {
            VStack(alignment:.leading,spacing:0) {
                HStack(alignment:.top) {
                    VStack(alignment:.leading,spacing:7) {
                        Text(store.page.eyebrow).font(.system(size:10,weight:.semibold,design:.monospaced)).tracking(2.4).foregroundStyle(.teal)
                        Text(store.page.title).font(.system(size:29,weight:.bold))
                        Text(store.page.subtitle).font(.system(size:13)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("外观",selection:$store.appearance) {
                        Image(systemName:"circle.lefthalf.filled").tag("system")
                        Image(systemName:"sun.max").tag("light")
                        Image(systemName:"moon").tag("dark")
                    }.pickerStyle(.segmented).labelsHidden().frame(width:120).help("外观：跟随系统 / 浅色 / 深色")
                }.padding(.horizontal,28).padding(.top,32).padding(.bottom,22)
                Group {
                    switch store.page {
                    case .diff: DiffPage(store:store)
                    case .json: JSONPage(store:store)
                    case .epoch: EpochPage(store:store)
                    case .clock: ClockPage(store:store)
                    }
                }.padding(.horizontal,28).padding(.bottom,24)
            }.background(Color(nsColor:.windowBackgroundColor))
        }.tint(.teal)
    }
}
