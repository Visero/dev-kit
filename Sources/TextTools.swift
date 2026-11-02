import SwiftUI

struct DiffPage: View {
    @ObservedObject var store: ToolkitStore
    private var leftBinding: Binding<String> { Binding(get:{store.left},set:{store.left=$0;store.invalidateDiff()}) }
    private var rightBinding: Binding<String> { Binding(get:{store.right},set:{store.right=$0;store.invalidateDiff()}) }
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            HStack(spacing:12) {
                Button { store.compare() } label:{Label(store.diffBusy ? "比较中…" : "比较代码",systemImage:"arrow.left.arrow.right")}.buttonStyle(.borderedProminent).disabled(store.diffBusy)
                Button("交换两侧") { let temp=store.left;store.left=store.right;store.right=temp;store.invalidateDiff() }
                Button("示例") { store.left="func greet(name: String) {\n    print(\"Hello, \\(name)\")\n}\n";store.right="func greet(name: String) {\n    let message = \"你好，\\(name)\"\n    print(message)\n}\n";store.compare() }
                Button("清空") { store.left="";store.right="";store.invalidateDiff() }
                Spacer()
                Toggle("忽略行首尾空格",isOn:Binding(get:{store.ignoreWhitespace},set:{store.ignoreWhitespace=$0;store.invalidateDiff()})).toggleStyle(.checkbox).font(.system(size:11))
            }
            HStack(spacing:14) {
                EditorPanel(title:"原始代码",badge:"ORIGINAL",text:leftBinding)
                EditorPanel(title:"修改后的代码",badge:"MODIFIED",text:rightBinding)
            }.frame(minHeight:175,maxHeight:250)
            Notice(text:store.diffError,error:true)
            Panel {
                HStack {
                    Text("差异结果").font(.system(size:12,weight:.semibold))
                    Spacer()
                    if let result=store.diffResult {
                        Text("+\(result.added) 新增").foregroundStyle(.green)
                        Text("−\(result.removed) 删除").foregroundStyle(.red)
                    } else { Text("按行比较 · 对齐显示").foregroundStyle(.secondary) }
                }.font(.system(size:11,design:.monospaced)).padding(14)
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
                    VStack(spacing:10) { Image(systemName:"text.alignleft").font(.system(size:30)).foregroundStyle(.teal.opacity(0.7));Text("粘贴两段代码，点击「比较代码」").font(.system(size:13)).foregroundStyle(.secondary) }.frame(maxWidth:.infinity,maxHeight:.infinity)
                }
            }.frame(minHeight:160)
            Text("绿色为新增，红色为删除；修改行并排显示。每侧最多 4,000 行，合计最多 2 MB。").font(.system(size:10)).foregroundStyle(.tertiary)
        }
    }
    func diffCell(number: Int?,text: String?,changed: Bool,plus: Bool,width:CGFloat) -> some View {
        HStack(alignment:.top,spacing:10) {
            Text(number.map(String.init) ?? "").foregroundStyle(.tertiary).frame(width:30,alignment:.trailing)
            Text(changed && text != nil ? (plus ? "+" : "−") : " ").foregroundStyle(plus ? .green : .red)
            Text(text ?? " ").textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)
        }.font(.system(size:12,design:.monospaced)).padding(.horizontal,8).padding(.vertical,5).frame(width:width,alignment:.leading)
            .background(changed ? (text == nil ? Color.primary.opacity(0.03) : (plus ? Color.green.opacity(0.10) : Color.red.opacity(0.10))) : Color.clear)
    }
}
struct JSONPage: View {
    @ObservedObject var store: ToolkitStore
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            HStack(spacing:10) {
                Button { store.formatJSON(compact:false) } label:{Label("格式化",systemImage:"text.alignleft")}.buttonStyle(.borderedProminent).disabled(store.jsonBusy)
                Button("压缩") { store.formatJSON(compact:true) }.disabled(store.jsonBusy)
                Picker("缩进",selection:$store.jsonIndent) { Text("2 空格").tag("2");Text("4 空格").tag("4");Text("Tab").tag("tab") }.frame(width:145)
                Spacer()
                Button("示例") { store.jsonInput="{\"name\":\"DevKit\",\"localOnly\":true,\"tools\":[\"diff\",\"json\",\"time\"],\"largeInteger\":9007199254740993}";store.invalidateJSON() }
                Button("清空") { store.jsonInput="";store.invalidateJSON() }
            }
            HStack(spacing:14) {
                EditorPanel(title:"输入 JSON",badge:"INPUT",text:Binding(get:{store.jsonInput},set:{store.jsonInput=$0;store.invalidateJSON()}))
                EditorPanel(title:"处理结果",badge:"OUTPUT",text:$store.jsonOutput,editable:false)
            }
            if store.jsonBusy { ProgressView().controlSize(.small) }
            Notice(text:store.jsonError,error:true)
            Notice(text:store.jsonStatus)
            Text("严格 JSON 校验 · 错误行列定位 · 保留键顺序、数字精度及转义内容 · 最大 2 MB").font(.system(size:10)).foregroundStyle(.tertiary)
        }
    }
}
