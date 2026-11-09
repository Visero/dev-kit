import SwiftUI

final class DiffViewState: ObservableObject {
    /// Inputs collapse by default once a result exists; the user can bring them back.
    @Published var showInputs=false
}

struct DiffPage: View {
    @ObservedObject var store: ToolkitStore
    @StateObject private var viewState=DiffViewState()
    private var leftBinding: Binding<String> { Binding(get:{store.left},set:{store.left=$0;store.invalidateDiff()}) }
    private var rightBinding: Binding<String> { Binding(get:{store.right},set:{store.right=$0;store.invalidateDiff()}) }
    private var hasResult: Bool { store.diffResult != nil }
    private var showInputs: Bool { viewState.showInputs }

    /// Compact control strip. The primary action always sits at the top right.
    private var toolbar: some View {
        HStack(spacing:10) {
            Picker("语法",selection:$store.diffLanguage) {
                ForEach(CodeLanguage.allCases) { Text($0.rawValue).tag($0) }
            }.frame(width:170).help("只改变语法配色，不影响 Diff 比较规则")
            Toggle("忽略行首尾空格",isOn:Binding(get:{store.ignoreWhitespace},set:{store.ignoreWhitespace=$0;store.invalidateDiff()})).toggleStyle(.checkbox).font(.system(size:11))
            if store.diffBusy { ProgressView().controlSize(.small) }
            Spacer(minLength:12)
            if hasResult {
                Button(showInputs ? "收起输入" : "展开输入") { viewState.showInputs.toggle() }.font(.system(size:11))
            } else {
                Button("示例") { store.left="func greet(name: String) {\n    print(\"Hello, \\(name)\")\n}\n";store.right="func greet(name: String) {\n    let message = \"你好，\\(name)\"\n    print(message)\n}\n";store.compare() }
                Button("清空") { store.left="";store.right="";store.invalidateDiff() }
                Button("交换两侧") { let temp=store.left;store.left=store.right;store.right=temp;store.invalidateDiff() }
            }
            Button { store.compare() } label:{
                Label(store.diffBusy ? "比较中…" : (hasResult ? "重新比较" : "开始比较"),systemImage:"arrow.left.arrow.right")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(store.diffBusy || store.left.isEmpty || store.right.isEmpty)
            .help("按当前语法与空白规则比较两侧代码")
        }
    }

    private var editors: some View {
        HStack(spacing:14) {
            EditorPanel(title:"原始代码",badge:"ORIGINAL",text:leftBinding,language:store.diffLanguage)
            EditorPanel(title:"修改后的代码",badge:"MODIFIED",text:rightBinding,language:store.diffLanguage)
        }
    }

    /// One-line summary that replaces the editors after a comparison.
    private var collapsedInputs: some View {
        HStack(spacing:8) {
            Image(systemName:"rectangle.compress.vertical").foregroundStyle(.secondary)
            Text("原始 \(lineCount(store.left)) 行 · 修改 \(lineCount(store.right)) 行").font(.system(size:11,design:.monospaced)).foregroundStyle(.secondary)
            Spacer(minLength:8)
            Text("输入已收起").font(.system(size:10)).foregroundStyle(.tertiary)
        }.padding(.horizontal,12).padding(.vertical,7)
            .background(Color.primary.opacity(0.04),in:RoundedRectangle(cornerRadius:10))
    }

    private func lineCount(_ text: String) -> Int { text.isEmpty ? 0 : text.components(separatedBy:"\n").count }

    private var resultArea: some View {
        Panel {
            HStack(spacing:10) {
                Text("差异结果").font(.system(size:12,weight:.semibold))
                if let result=store.diffResult {
                    if result.identical { Text("两侧一致").foregroundStyle(.teal) }
                    else {
                        Text("+\(result.added) 新增").foregroundStyle(.green)
                        Text("−\(result.removed) 删除").foregroundStyle(.red)
                    }
                }
                Spacer()
                Text("按行比较 · 对齐显示").foregroundStyle(.secondary)
            }.font(.system(size:11,design:.monospaced)).padding(.horizontal,14).padding(.vertical,9)
            Divider()
            if store.diffBusy {
                ProgressView().frame(maxWidth:.infinity,maxHeight:.infinity)
            } else if let result=store.diffResult {
                if result.identical {
                    VStack(spacing:10) { Image(systemName:"checkmark.seal").font(.system(size:30));Text(store.ignoreWhitespace ? "按当前规则，两侧内容一致" : "两侧内容完全一致").font(.system(size:14,weight:.medium)) }.foregroundStyle(.teal).frame(maxWidth:.infinity,maxHeight:.infinity)
                } else {
                    GeometryReader { geometry in
                        ScrollView([.vertical,.horizontal]) {
                            LazyVStack(spacing:0) {
                                ForEach(result.rows) { row in
                                    HStack(alignment:.top,spacing:0) {
                                        diffCell(number:row.leftNumber,text:row.left,changed:row.changed,plus:false,width:max(360,(geometry.size.width-1)/2))
                                        Rectangle().fill(Color.primary.opacity(0.08)).frame(width:1)
                                        diffCell(number:row.rightNumber,text:row.right,changed:row.changed,plus:true,width:max(360,(geometry.size.width-1)/2))
                                    }.fixedSize(horizontal:false,vertical:true)
                                }
                            }.padding(.vertical,6)
                        }
                    }
                }
            } else {
                VStack(spacing:10) { Image(systemName:"text.alignleft").font(.system(size:30)).foregroundStyle(.teal.opacity(0.7));Text("粘贴两段代码，点击「开始比较」").font(.system(size:13)).foregroundStyle(.secondary) }.frame(maxWidth:.infinity,maxHeight:.infinity)
            }
        }.frame(minHeight:160,maxHeight:.infinity)
    }

    var body: some View {
        GeometryReader { geo in
            VStack(alignment:.leading,spacing:10) {
                toolbar
                Notice(text:store.diffError,error:true)
                if hasResult && !showInputs {
                    // Compared: inputs collapse into a summary bar, the result takes the page.
                    collapsedInputs
                    resultArea
                } else {
                    if hasResult {
                        editors.frame(height:max(160,geo.size.height*0.36))
                    } else {
                        // Editing: both editors stretch to fill the page.
                        editors.frame(maxHeight:.infinity)
                    }
                    if hasResult {
                        resultArea
                    } else {
                        Text("绿色为新增，红色为删除；修改行并排显示。每侧最多 4,000 行，合计最多 2 MB。").font(.system(size:10)).foregroundStyle(.tertiary)
                            .fixedSize(horizontal:false,vertical:true)
                    }
                }
            }
            .frame(width:geo.size.width,height:geo.size.height,alignment:.topLeading)
        }
    }
    func highlights(number:Int?,plus:Bool) -> [SyntaxSpan] {
        guard let number=number else { return [] }
        let lines=plus ? store.rightHighlights : store.leftHighlights
        return number>0 && number<=lines.count ? lines[number-1] : []
    }
    func diffCell(number: Int?,text: String?,changed: Bool,plus: Bool,width:CGFloat) -> some View {
        HStack(alignment:.top,spacing:10) {
            Text(number.map(String.init) ?? "").foregroundStyle(.tertiary).frame(width:30,alignment:.trailing)
            Text(changed && text != nil ? (plus ? "+" : "−") : " ").foregroundStyle(plus ? .green : .red)
            HighlightedCode(text:text ?? " ",spans:highlights(number: number,plus:plus))
        }.font(.system(size:12,design:.monospaced)).padding(.horizontal,8).padding(.vertical,5).frame(width:width,alignment:.leading)
            .background(changed ? (text == nil ? Color.primary.opacity(0.03) : (plus ? Color.green.opacity(0.10) : Color.red.opacity(0.10))) : Color.clear)
    }
}

struct CodeFormatPage: View {
    @ObservedObject var store: ToolkitStore
    /// The language used for highlighting the single editor.
    private var editorLanguage: CodeLanguage {
        if store.codeLanguage != .automatic { return store.codeLanguage }
        return store.codeDetected.language == .plain ? .automatic : store.codeDetected.language
    }
    /// Detection hint text shown next to the language picker.
    private var detectionHint: String {
        if store.codeLanguage != .automatic { return "手动：\(store.codeLanguage.rawValue)" }
        switch store.codeDetected.language {
        case .plain: return store.codeInput.isEmpty ? "等待输入" : "未能识别"
        default:
            let pct = Int(store.codeDetected.confidence * 100)
            return "检测到 \(store.codeDetected.language.rawValue) · \(pct)%"
        }
    }
    private var detectionColor: Color {
        if store.codeLanguage != .automatic { return .secondary }
        if store.codeInput.isEmpty { return .secondary }
        return store.codeDetected.confidence >= 0.7 ? .teal : .orange
    }

    private var primaryActions: some View {
        HStack(spacing:9) {
            Button { store.formatCode() } label: {
                Label(store.codeBusy ? "格式化中…" : "格式化", systemImage: "text.alignleft")
            }.buttonStyle(.borderedProminent).disabled(store.codeBusy || store.codeInput.isEmpty)

            Button("撤销") { store.undoFormat() }
                .disabled(!store.codeCanUndo)
                .help("撤销上一次格式化")

            CopyButton(text: store.codeInput, label: "复制")
        }
    }
    private var sampleButtons: some View {
        HStack(spacing:9) {
            Button("示例") {
                store.isProgrammaticReplace = true
                store.codeInput = "{\"name\":\"DevKit\",\"version\":1,\"features\":[\"diff\",\"format\",\"time\"],\"active\":true,\"config\":{\"indent\":2,\"strict\":false}}"
                store.isProgrammaticReplace = false
                store.codeCanUndo = false
                store.codePreviousText = ""
                store.refreshCodeDetection()
            }
            Button("清空") {
                store.clearCode()
                store.refreshCodeDetection()
            }
        }
    }
    private var languagePicker: some View {
        Picker("语言", selection: $store.codeLanguage) {
            ForEach(CodeLanguage.allCases) { Text($0.rawValue).tag($0) }
        }.frame(width:190)
    }
    private var detectionLabel: some View {
        Text(detectionHint)
            .font(.system(size:11,weight:.medium,design:.monospaced))
            .foregroundStyle(detectionColor)
            .lineLimit(1)
    }
    private var indentPicker: some View {
        Picker("缩进", selection: $store.codeIndent) {
            Text("2 空格").tag("2")
            Text("4 空格").tag("4")
            Text("Tab").tag("tab")
        }.frame(width:118)
    }

    var body: some View {
        GeometryReader { geo in
            VStack(alignment:.leading,spacing:10) {
                // Controls: one row when there is room, two compact rows on narrow windows.
                ViewThatFits(in:.horizontal) {
                    HStack(spacing:9) {
                        primaryActions
                        Divider().frame(height:16)
                        languagePicker
                        detectionLabel
                        Spacer(minLength:8)
                        indentPicker
                        sampleButtons
                    }
                    VStack(alignment:.leading,spacing:8) {
                        HStack(spacing:9) { primaryActions; Spacer(minLength:8); sampleButtons }
                        HStack(spacing:9) { languagePicker; detectionLabel; Spacer(minLength:8); indentPicker }
                    }
                }

                // Single editable code editor with in-place undo support.
                // It takes every pixel left between the controls and the bottom status line.
                Panel {
                    HStack {
                        Text("代码").font(.system(size:12,weight:.semibold))
                        Spacer()
                        Text("EDITOR").font(.system(size:10,design:.monospaced)).foregroundStyle(.secondary)
                    }.padding(.horizontal,14).padding(.vertical,9)
                    Divider()
                    CodeEditor(
                        text: Binding(
                            get: { store.codeInput },
                            set: {
                                store.codeInput = $0
                                // Only invalidate when the user typed, not on programmatic replace.
                                if !store.isProgrammaticReplace { store.invalidateCode() }
                            }
                        ),
                        label: "代码编辑器",
                        language: editorLanguage,
                        onReady: { coordinator in
                            // Wire the store's replacement handler to this editor's undo-aware coordinator.
                            store.codeReplaceHandler = { [weak coordinator] newText in
                                coordinator?.performReplacement(newText)
                            }
                        }
                    )
                    .frame(maxHeight:.infinity)
                    .clipShape(UnevenRoundedRectangle(bottomLeadingRadius:16,bottomTrailingRadius:16))
                }
                .frame(minHeight:200,maxHeight:.infinity)

                if store.codeBusy { ProgressView().controlSize(.small) }
                Notice(text: store.codeError, error: true)
                Notice(text: store.codeStatus)
                if !store.codeDraftNotice.isEmpty {
                    Label(store.codeDraftNotice, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11)).foregroundStyle(.orange)
                }

                Text("自动识别 JSON / JS / TS / HTML / CSS / Python / Go / Swift / Java / C / C++ / SQL / Shell / Rust · 最大 2 MB · 仅在本地运行").font(.system(size:10)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal:false,vertical:true)
            }
            .frame(width:geo.size.width,height:geo.size.height,alignment:.topLeading)
        }
    }
}
