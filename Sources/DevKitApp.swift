import SwiftUI
import AppKit

extension Notification.Name {
    static let devKitSelectPage = Notification.Name("DevKit.selectPage")
}

#if !BUILD_TEST
@main
struct DevKitApp: App {
    @NSApplicationDelegateAdaptor(DevKitAppDelegate.self) private var delegate
    @StateObject private var store = ToolkitStore()
    var body: some Scene {
        WindowGroup("DevKit · 开发工具箱") {
            RootView(store:store).frame(minWidth:940,minHeight:660)
                .background(WindowSizeMigration().frame(width:0,height:0))
                .preferredColorScheme(store.appearance == "dark" ? .dark : store.appearance == "light" ? .light : nil)
        }
        .defaultSize(width:1440,height:960).windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing:.newItem) { }
            CommandGroup(after:.newItem) {
                Button("打开代码文件…") { CodeReaderManager.shared.chooseFile() }
                    .keyboardShortcut("o",modifiers:.command)
            }
            CommandGroup(replacing:.saveItem) {
                Button("保存") { NSApp.sendAction(#selector(NSDocument.save(_:)),to:nil,from:nil) }
                    .keyboardShortcut("s",modifiers:.command)
            }
            CommandGroup(after:.saveItem) {
                Button("关闭窗口") { NSApp.keyWindow?.performClose(nil) }
                    .keyboardShortcut("w",modifiers:.command)
            }
            CommandMenu("工具") {
                ForEach(Array(store.toolOrder.enumerated()), id: \.element) { idx, page in
                    Button(page.title) {
                        NotificationCenter.default.post(name: .devKitSelectPage, object: page)
                    }
                    .keyboardShortcut(KeyEquivalent(Character(String(idx+1))), modifiers:.command)
                }
            }
        }
    }
}
#endif

enum ToolPage: String, CaseIterable, Identifiable, Sendable {
    case clock, diff, json, notes, reader
    var id: String { rawValue }
    var title: String {
        switch self {
        case .diff: return "代码 Diff"
        case .json: return "代码格式化"
        case .notes: return "记事本"
        case .reader: return "代码阅读器"
        case .clock: return "时间中心"
        }
    }
    var symbol: String {
        switch self {
        case .diff: return "arrow.left.arrow.right"
        case .json: return "curlybraces"
        case .notes: return "note.text"
        case .reader: return "doc.text.magnifyingglass"
        case .clock: return "clock"
        }
    }
    var subtitle: String {
        switch self {
        case .diff: return "并排比较两段代码，变化一目了然。"
        case .json: return "自动识别并格式化多种语言代码，仅在本地运行。"
        case .notes: return "用 Markdown 记录灵感，笔记自动保存在本机。"
        case .reader: return "在独立窗口阅读与编辑代码，保留行号和语法高亮。"
        case .clock: return "世界时钟、下班倒计时与 Unix 时间戳转换。"
        }
    }
    var eyebrow: String {
        switch self {
        case .diff: return "COMPARE"
        case .json: return "FORMAT"
        case .notes: return "NOTEBOOK"
        case .reader: return "CODE READER"
        case .clock: return "TIME CENTER"
        }
    }
    static let defaultOrder: [ToolPage] = [.clock, .diff, .json, .notes, .reader]
    static func migratedOrder(_ saved:[String]) -> [ToolPage] {
        // Keep the clock's existing position; epoch is retired, not a second time page.
        var result:[ToolPage]=[]
        for raw in saved {
            if raw == "epoch" { continue }
            if let page=ToolPage(rawValue:raw),!result.contains(page) { result.append(page) }
        }
        for page in defaultOrder where !result.contains(page) { result.append(page) }
        return result
    }
}
final class ToolkitStore: ObservableObject {
    @Published var page: ToolPage = .clock
    @Published var appearance=UserDefaults.standard.string(forKey:"DevKit.appearance") ?? "system" {
        didSet { UserDefaults.standard.set(appearance,forKey:"DevKit.appearance");sync.localSettingsChanged() }
    }
    @Published var savedOffset=UserDefaults.standard.string(forKey:"DevKit.utcOffset") ?? "0" {
        didSet { UserDefaults.standard.set(savedOffset,forKey:"DevKit.utcOffset");sync.localSettingsChanged() }
    }
    @Published var workEndTime: String = {
        let saved = UserDefaults.standard.string(forKey:"DevKit.workEndTime") ?? WorkdayCountdown.defaultTime
        return (try? WorkdayCountdown.parseTime(saved)) != nil ? saved : WorkdayCountdown.defaultTime
    }() {
        didSet { UserDefaults.standard.set(workEndTime,forKey:"DevKit.workEndTime");sync.localSettingsChanged() }
    }
    @Published private(set) var workWeekSchedule: WorkWeekSchedule
    private let scheduleDefaults: UserDefaults

    func setWorkWeekSchedule(_ schedule: WorkWeekSchedule) throws {
        let valid = try schedule.validated()
        try WorkSchedulePreferences.save(valid, to: scheduleDefaults)
        workWeekSchedule = valid
        sync.localSettingsChanged()
    }

    @Published var toolOrder: [ToolPage] = ToolkitStore.savedOrder() {
        didSet { UserDefaults.standard.set(toolOrder.map(\.rawValue),forKey:"DevKit.toolOrder");sync.localSettingsChanged() }
    }
    func position(of page: ToolPage) -> Int { toolOrder.firstIndex(of:page) ?? 0 }
    func movePage(from source:IndexSet,to destination:Int) { toolOrder.move(fromOffsets:source,toOffset:destination) }
    static func savedOrder() -> [ToolPage] {
        ToolPage.migratedOrder(UserDefaults.standard.stringArray(forKey:"DevKit.toolOrder") ?? [])
    }
    let notebook: NotebookStore
    let sync: CloudSyncEngine
    private var cancellable: Any?
    init(notebookDirectory:URL?=nil, scheduleDefaults: UserDefaults = .standard) {
        self.scheduleDefaults = scheduleDefaults
        workWeekSchedule = WorkSchedulePreferences.load(from: scheduleDefaults)
        notebook=NotebookStore(directory:notebookDirectory ?? NotebookDisk.directory)
        sync=CloudSyncEngine(defaults: scheduleDefaults)
        isLoadingDraft = true
        let draft = CodeDraftStore.load()
        codeInput = draft.text ?? ""
        isLoadingDraft = false
        switch draft.outcome {
        case .noFile: break
        case .loaded: break
        case .corrupted: codeDraftNotice = "草稿文件已损坏，已保留当前编辑。"
        case .readError: codeDraftNotice = "草稿文件读取失败，不影响当前编辑。"
        }
        CodeDraftStore.onSaveComplete = { success in
            self.codeDraftNotice = success ? "" : "草稿保存失败，请检查磁盘权限。"
        }
        cancellable = NotificationCenter.default.addObserver(forName: .devKitSelectPage, object: nil, queue: .main) { note in
            if let page = note.object as? ToolPage {
                DispatchQueue.main.async { self.page = page }
            }
        }
        notebook.onLibraryChange = { [weak self] in self?.sync.localNotebookChanged() }
        sync.attach(store: self)
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            CodeDraftStore.flush(self.codeInput)
            self.sync.flushOnTerminate()
        }
    }
    @Published var left="" {
        didSet { sync.localDraftChanged(.diffLeft, text: left) }
    }
    @Published var diffLanguage: CodeLanguage = .automatic {
        didSet { refreshDiffHighlights();sync.localSettingsChanged() }
    }
    @Published var leftHighlights: [[SyntaxSpan]] = []
    @Published var rightHighlights: [[SyntaxSpan]] = []
    private var highlightGeneration=UUID()
    func refreshDiffHighlights() {
        let id=UUID(),a=left,b=right,language=diffLanguage
        highlightGeneration=id
        guard diffResult != nil else { return }
        DispatchQueue.global(qos:.userInitiated).async {
            let lhs=SyntaxLexer.lineSpans(a,language:language),rhs=SyntaxLexer.lineSpans(b,language:language)
            DispatchQueue.main.async {
                guard self.highlightGeneration==id else { return }
                self.leftHighlights=lhs;self.rightHighlights=rhs
            }
        }
    }
    @Published var right="" {
        didSet { sync.localDraftChanged(.diffRight, text: right) }
    }
    @Published var diffResult: DiffResult?
    @Published var diffError=""
    @Published var diffBusy=false
    @Published var ignoreWhitespace=false
    var diffGeneration=UUID()

    // MARK: - Code formatting page
    @Published var codeInput="" {
        didSet {
            guard !isLoadingDraft else { return }
            CodeDraftStore.userDidEdit()
            CodeDraftStore.scheduleSave(codeInput)
            scheduleCodeDetectionRefresh()
            sync.localDraftChanged(.formatter, text: codeInput)
        }
    }
    @Published var codeLanguage: CodeLanguage = .automatic {
        didSet { refreshCodeDetection();sync.localSettingsChanged() }
    }
    @Published var codeDetected: DetectionResult = .unknown
    @Published var codeBusy=false
    @Published var codeError=""
    @Published var codeStatus=""
    @Published var codeIndent="2" {
        didSet { sync.localSettingsChanged() }
    }
    @Published var codeCanUndo=false
    @Published var codeDraftNotice=""
    var codeGeneration=UUID()
    var codeDetectionGeneration=UUID()
    var codePreviousText=""
    /// True while performReplacement flows through binding — skip invalidateCode.
    var isProgrammaticReplace=false
    private var isLoadingDraft=false
    var codeReplaceHandler: ((String) -> Void)?

    private func scheduleCodeDetectionRefresh() {
        let id = UUID()
        codeDetectionGeneration = id
        let text = codeInput
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.2) {
            let result = SyntaxLexer.detect(text)
            DispatchQueue.main.async {
                guard self.codeDetectionGeneration == id else { return }
                self.codeDetected = result
            }
        }
    }

    func refreshCodeDetection() {
        guard codeLanguage == .automatic else {
            codeDetected = DetectionResult(language: codeLanguage, confidence: 1.0)
            return
        }
        scheduleCodeDetectionRefresh()
    }

    func formatCode() {
        let text = codeInput
        guard !text.isEmpty else {
            codeError = "请输入代码后再格式化。"
            return
        }
        // indent is passed as a spaces string ("  " or "    ") or tab character.
        // Engine wrappers receive this via {indent} and convert as needed.
        let indent = codeIndent == "tab" ? "\t" : String(repeating: " ", count: Int(codeIndent) ?? 2)
        let id = UUID()
        codeGeneration = id
        codeBusy = true; codeError = ""; codeStatus = ""

        // Resolve which language to format.
        let targetLanguage: CodeLanguage
        if codeLanguage != .automatic {
            targetLanguage = codeLanguage
        } else {
            let detection = SyntaxLexer.detect(text)
            codeDetected = detection
            guard detection.confidence >= 0.5 else {
                codeBusy = false
                codeError = "无法识别代码语言，请从右侧手动选择。"
                return
            }
            targetLanguage = detection.language
        }

        DispatchQueue.global(qos:.userInitiated).async {
            let result = Result { try CodeFormatEngine.format(text, language: targetLanguage, indent: indent) }
            DispatchQueue.main.async {
                guard self.codeGeneration == id else { return }
                // User may have typed during format; don't overwrite newer input.
                guard self.codeInput == text else {
                    self.codeBusy = false
                    return
                }
                self.codeBusy = false
                switch result {
                case .success(let output):
                    guard output != text else {
                        self.codeStatus = "内容已符合格式，无需调整。"
                        return
                    }
                    self.codePreviousText = text
                    self.codeCanUndo = true
                    // Prevent binding setter from invalidating undo state.
                    self.isProgrammaticReplace = true
                    self.codeReplaceHandler?(output)
                    self.codeInput = output
                    self.isProgrammaticReplace = false
                    CodeDraftStore.flush(output)
                    let langLabel = targetLanguage == .json ? "JSON" : targetLanguage.rawValue
                    self.codeStatus = "已格式化 \(langLabel) · 可撤销"
                case .failure(let error):
                    self.codeError = error.localizedDescription
                }
            }
        }
    }

    func undoFormat() {
        guard codeCanUndo else { return }
        let prev = codePreviousText
        isProgrammaticReplace = true
        codeReplaceHandler?(prev)
        codeInput = prev
        isProgrammaticReplace = false
        CodeDraftStore.flush(prev)
        codeCanUndo = false
        codeStatus = "已撤销格式化"
        codeError = ""
    }

    /// Clear the code input and persist empty state.
    func clearCode() {
        codeGeneration = UUID()
        codeInput = ""
        CodeDraftStore.flush("")
        codeCanUndo = false
        codePreviousText = ""
        codeError = ""
        codeStatus = ""
    }

    func invalidateCode() {
        codeGeneration = UUID()
        codeBusy = false
        codeError = ""
        codeStatus = ""
        codeCanUndo = false
        codePreviousText = ""
    }

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
                switch result { case .success(let value):self.diffResult=value;self.refreshDiffHighlights(); case .failure(let error):self.diffError=error.localizedDescription }
            }
        }
    }
    func invalidateDiff() { diffGeneration=UUID();highlightGeneration=UUID();diffBusy=false;diffResult=nil;leftHighlights=[];rightHighlights=[];diffError="" }

    // MARK: - Applied only by the sync engine, after validation
    func applySyncSettings(_ record: SyncSettingsRecord) {
        if ["system","light","dark"].contains(record.appearance) { appearance = record.appearance }
        if (try? TimeTools.offsetMinutes(record.utcOffset)) != nil { savedOffset = record.utcOffset }
        if (try? WorkdayCountdown.parseTime(record.workEndTime)) != nil { workEndTime = record.workEndTime }
        // Old peers have no weekly field: do not reset an already customized week.
        if let schedule = record.workWeekSchedule { try? setWorkWeekSchedule(schedule) }
        else if scheduleDefaults.data(forKey: WorkSchedulePreferences.key) == nil {
            try? setWorkWeekSchedule(.migrated(legacyTime: record.workEndTime))
        }
        let order = ToolPage.migratedOrder(record.toolOrder)
        if !order.isEmpty { toolOrder = order }
        if ["2","4","tab"].contains(record.codeIndent) { codeIndent = record.codeIndent }
        if let language = CodeLanguage(rawValue: record.codeLanguage) { codeLanguage = language }
        if let language = CodeLanguage(rawValue: record.diffLanguage) { diffLanguage = language }
    }

    func applySyncDraft(_ text: String) {
        isProgrammaticReplace = true
        codeReplaceHandler?(text)
        codeInput = text
        isProgrammaticReplace = false
        invalidateCode()
    }
}

final class RootUIState: ObservableObject {
    @Published var syncSheet = false
}

struct RootView: View {
    @ObservedObject var store: ToolkitStore
    @StateObject private var ui = RootUIState()
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
                            .contentShape(RoundedRectangle(cornerRadius:12))
                            .background(store.page==page ? Color.teal : Color.clear,in:RoundedRectangle(cornerRadius:12))
                        }.buttonStyle(.plain).accessibilityLabel(page.title)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .contextMenu {
                                Button {
                                    if idx > 0 {
                                        store.movePage(from: IndexSet(integer: idx), to: idx - 1)
                                    }
                                } label: {
                                    Label("上移", systemImage: "arrow.up")
                                }.disabled(idx == 0)
                                Button {
                                    if idx < store.toolOrder.count - 1 {
                                        store.movePage(from: IndexSet(integer: idx), to: idx + 2)
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
                    SyncFooterButton(engine: store.sync) { ui.syncSheet = true }
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
                }.padding(.horizontal,28).padding(.top,store.page == .json ? 16 : 32).padding(.bottom,store.page == .json ? 12 : 22)
                Group {
                    switch store.page {
                    case .diff: DiffPage(store:store)
                    case .json: CodeFormatPage(store:store)
                    case .notes: NotebookPage(notes:store.notebook)
                    case .reader: CodeReaderPage(manager:CodeReaderManager.shared)
                    case .clock: ClockPage(store:store)
                    }
                }.padding(.horizontal,28).padding(.bottom,store.page == .json ? 14 : 24)
            }.background(Color(nsColor:.windowBackgroundColor))
        }.tint(.teal)
        .sheet(isPresented:$ui.syncSheet) { SyncSheet(engine:store.sync) }
    }
}
