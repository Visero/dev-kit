import SwiftUI
import AppKit

private final class NotebookViewState:ObservableObject {
    @Published var showList=true
    @Published var sourceMode=false
    @Published var folderPrompt=false
    @Published var folderName=""
    @Published var renamingFolder:UUID?
    weak var editor:MarkdownEditor.Coordinator?
}
struct NotebookPage:View {
    @ObservedObject var notes:NotebookStore
    @StateObject private var state=NotebookViewState()
    var body:some View {
        VStack(spacing:10) {
            HStack(spacing:10) {
                Button { state.showList.toggle() } label:{ Image(systemName:"sidebar.left") }.help("显示/隐藏笔记列表")
                Spacer()
                Button { notes.addNote() } label:{ Label("新建笔记",systemImage:"square.and.pencil") }.buttonStyle(.borderedProminent).disabled(notes.loadFailed)
            }
            HSplitView {
                if state.showList { noteList.frame(minWidth:190,idealWidth:240,maxWidth:300) }
                detail.frame(minWidth:260,maxWidth:.infinity,maxHeight:.infinity)
            }
            HStack {
                Text(notes.loadFailed ? notes.status : (notes.status.isEmpty ? "本地笔记 · 自动保存" : notes.status))
                    .foregroundStyle(notes.loadFailed || notes.status.hasPrefix("保存失败") ? Color.red : Color.secondary)
                Spacer()
                if notes.dirty { Button("重试保存") { notes.flush() }.buttonStyle(.borderless) }
                Text("Markdown · 仅存本机").foregroundStyle(.tertiary)
            }.font(.system(size:11)).lineLimit(2)
        }.onDisappear { notes.flush() }
        .popover(isPresented:$state.folderPrompt) {
            VStack(alignment:.leading,spacing:14) {
                Text(state.renamingFolder == nil ? "新建文件夹" : "重命名文件夹").font(.headline)
                TextField("文件夹名称",text:$state.folderName).textFieldStyle(.roundedBorder).onSubmit(saveFolder)
                HStack { Button("取消") { state.folderPrompt=false };Spacer();Button("保存",action:saveFolder).buttonStyle(.borderedProminent).disabled(state.folderName.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty) }
            }.padding(20).frame(width:280)
        }
    }
    private var folderTitle:String {
        if notes.showingTrash { return "最近删除" }
        return notes.library.folders.first{$0.id == notes.folderSelection}?.name ?? "全部笔记"
    }
    private var folderMenu:some View {
        Menu {
            Button { notes.selectFolder(nil) } label:{ Label("全部笔记",systemImage:notes.folderSelection == nil && !notes.showingTrash ? "checkmark" : "tray") }
            ForEach(notes.library.folders) { folder in
                Button { notes.selectFolder(folder.id) } label:{ Label(folder.name,systemImage:notes.folderSelection == folder.id && !notes.showingTrash ? "checkmark" : "folder") }
            }
            Divider()
            Button { notes.selectFolder(nil,trash:true) } label:{ Label("最近删除",systemImage:"trash") }
        } label:{ Text(folderTitle).font(.system(size:13,weight:.semibold)).lineLimit(1) }
        .menuStyle(.borderlessButton).accessibilityLabel("选择笔记文件夹")
    }
    private var folderActions:some View {
        Menu {
            Button { state.folderName="";state.renamingFolder=nil;state.folderPrompt=true } label:{ Label("新建文件夹",systemImage:"folder.badge.plus") }
            if let id=notes.folderSelection,!notes.showingTrash {
                Button("重命名当前文件夹") { state.renamingFolder=id;state.folderName=folderTitle;state.folderPrompt=true }
                Button("移除当前文件夹（保留笔记）") { notes.removeFolder(id) }.disabled(notes.library.folders.count<=1)
            }
        } label:{ Image(systemName:"ellipsis.circle") }
        .menuStyle(.borderlessButton).fixedSize().help("文件夹管理").accessibilityLabel("文件夹管理").disabled(notes.loadFailed)
    }
    private var noteList:some View {
        VStack(alignment:.leading,spacing:0) {
            HStack(spacing:8) {
                folderMenu
                Spacer(minLength:4)
                Text("\(notes.visibleNotes.count)").font(.system(size:11)).foregroundStyle(.secondary)
                folderActions
            }.padding(12)
            TextField("搜索笔记",text:$notes.search).textFieldStyle(.roundedBorder).accessibilityLabel("搜索笔记").padding(.horizontal,10).padding(.bottom,10)
            Divider()
            ScrollView {
                LazyVStack(spacing:4) {
                    ForEach(notes.visibleNotes) { note in
                        Button { notes.selection=note.id } label: {
                            VStack(alignment:.leading,spacing:7) {
                                HStack(spacing:4) { if note.pinned { Image(systemName:"pin.fill").font(.system(size:10)).foregroundStyle(.teal) };Text(note.title.isEmpty ? "无标题笔记" : note.title).font(.system(size:13,weight:.semibold)).lineLimit(1) }
                                Text(note.snippet).font(.system(size:11)).foregroundStyle(.secondary).lineLimit(2)
                                Text(note.updatedAt,style:.date).font(.system(size:10)).foregroundStyle(.tertiary)
                            }.frame(maxWidth:.infinity,alignment:.leading).padding(12)
                                .background(notes.selection == note.id ? Color.teal.opacity(0.13) : Color.clear,in:RoundedRectangle(cornerRadius:10))
                        }.buttonStyle(.plain).accessibilityLabel("笔记：\(note.title)")
                        .contextMenu {
                            if note.deletedAt != nil { Button("恢复笔记") { notes.restore(note.id) } }
                            else { Button(note.pinned ? "取消置顶" : "置顶") { notes.togglePin(note.id) };Button("移到最近删除") { notes.trash(note.id) } }
                        }
                    }
                }.padding(5)
                if notes.visibleNotes.isEmpty { Text(notes.search.isEmpty ? "暂无笔记" : "没有匹配的笔记").font(.system(size:12)).foregroundStyle(.secondary).padding(20) }
            }
        }.background(Color.primary.opacity(0.025),in:RoundedRectangle(cornerRadius:12))
    }
    @ViewBuilder private var detail:some View {
        if let note=notes.current {
            VStack(alignment:.leading,spacing:0) {
                HStack(spacing:8) {
                    TextField("无标题笔记",text:Binding(get:{notes.library.notes.first{$0.id == note.id}?.title ?? ""},set:{notes.edit(note.id,title:$0)}))
                        .font(.system(size:23,weight:.bold)).textFieldStyle(.plain).accessibilityLabel("笔记标题").disabled(note.deletedAt != nil || notes.loadFailed)
                    Spacer(minLength:0)
                    if note.deletedAt != nil { Button("恢复") { notes.restore(note.id) } }
                    else {
                        Button { notes.togglePin(note.id) } label:{Image(systemName:note.pinned ? "pin.fill" : "pin")}.help("置顶笔记")
                        Menu { ForEach(notes.library.folders) { folder in Button(folder.name) { notes.move(note.id,to:folder.id) } } } label:{Image(systemName:"folder")}.help("移动到文件夹")
                        Button { notes.trash(note.id) } label:{Image(systemName:"trash")}.help("移到最近删除，可恢复")
                    }
                }.padding(16)
                HStack(spacing:10) {
                    Text(note.updatedAt,style:.date).foregroundStyle(.secondary)
                    Spacer()
                    Picker("编辑模式",selection:$state.sourceMode) { Text("即时渲染").tag(false);Text("源码").tag(true) }.pickerStyle(.segmented).labelsHidden().frame(width:155)
                }.font(.system(size:11)).padding(.horizontal,16).padding(.bottom,12)
                if note.deletedAt == nil {
                    HStack(spacing:12) {
                        formatButton("标题",symbol:"textformat.size",prefix:"## ")
                        formatButton("加粗",symbol:"bold",prefix:"**",suffix:"**")
                        formatButton("斜体",symbol:"italic",prefix:"*",suffix:"*")
                        formatButton("清单",symbol:"checklist",prefix:"- [ ] ")
                        formatButton("列表",symbol:"list.bullet",prefix:"- ")
                        formatButton("代码",symbol:"curlybraces",prefix:"```\n",suffix:"\n```")
                        Spacer(minLength:0)
                        CopyButton(text:note.markdown,label:"复制 Markdown").labelStyle(.iconOnly).help("复制 Markdown 原文")
                    }.buttonStyle(.borderless).padding(.horizontal,16).padding(.bottom,12)
                }
                Divider()
                MarkdownEditor(text:Binding(get:{notes.library.notes.first{$0.id == note.id}?.markdown ?? ""},set:{notes.edit(note.id,markdown:$0)}),editable:note.deletedAt == nil && !notes.loadFailed,sourceMode:state.sourceMode,onReady:{state.editor=$0})
                    .id(note.id)
                HStack { Text("\(note.markdown.count) 字符");Spacer();Text(note.deletedAt != nil ? "已删除 · 可恢复" : "当前编辑行显示语法标记") }.font(.system(size:10)).foregroundStyle(.secondary).padding(12)
            }.background(Color(nsColor:.textBackgroundColor),in:RoundedRectangle(cornerRadius:14)).clipShape(RoundedRectangle(cornerRadius:14))
        } else {
            VStack(spacing:14) { Image(systemName:"note.text").font(.system(size:36)).foregroundStyle(.teal);Text("随手记，安心存").font(.system(size:18,weight:.semibold));Text("选择一篇笔记，或新建你的第一篇。\n支持 Markdown 即时样式，本机自动保存。").font(.system(size:12)).multilineTextAlignment(.center).foregroundStyle(.secondary);Button("新建笔记") { notes.addNote() }.disabled(notes.loadFailed) }.frame(maxWidth:.infinity,maxHeight:.infinity)
        }
    }
    private func formatButton(_ title:String,symbol:String,prefix:String,suffix:String="")->some View {
        Button { state.editor?.insert(prefix:prefix,suffix:suffix) } label:{Image(systemName:symbol)}.help(title).accessibilityLabel(title)
    }
    private func saveFolder() {
        if let id=state.renamingFolder { notes.renameFolder(id,name:state.folderName) } else { notes.addFolder(state.folderName) }
        state.folderPrompt=false
    }
}
