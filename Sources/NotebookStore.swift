import Foundation
import Combine
import AppKit

struct NotebookFolder: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
}
struct NotebookNote: Codable, Identifiable, Equatable {
    var id = UUID()
    var folderID: UUID
    var title = "新建笔记"
    var markdown = ""
    var createdAt = Date()
    var updatedAt = Date()
    var pinned = false
    var deletedAt: Date?
    var snippet: String {
        let line = markdown.components(separatedBy: .newlines).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? "尚无内容"
        return String(line.prefix(100))
    }
}
struct NotebookLibrary: Codable, Equatable {
    var schema = 1
    var folders: [NotebookFolder]
    var notes: [NotebookNote] = []
    static func empty() -> NotebookLibrary { NotebookLibrary(folders:[NotebookFolder(id:UUID(),name:"备忘录")]) }
    func validate() throws {
        guard schema == 1, !folders.isEmpty, Set(folders.map(\.id)).count == folders.count,
              Set(notes.map(\.id)).count == notes.count,
              folders.allSatisfy({ !$0.name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }),
              notes.allSatisfy({ note in folders.contains{$0.id == note.folderID} }) else {
            throw KitError.message("笔记库格式不受支持或数据损坏，原文件已保留。")
        }
    }
}
enum NotebookDisk {
    static let maximumBytes = 20_000_000
    static var directory: URL {
        FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.visero.devkit.tests")
            .appendingPathComponent("Notebook",isDirectory:true)
    }
    static func load(from directory:URL) throws -> NotebookLibrary {
        let url=directory.appendingPathComponent("Library.json")
        guard FileManager.default.fileExists(atPath:url.path) else { return .empty() }
        let values=try url.resourceValues(forKeys:[.fileSizeKey,.isSymbolicLinkKey])
        guard values.isSymbolicLink != true, (values.fileSize ?? 0)<=maximumBytes else { throw KitError.message("笔记库文件过大或为符号链接，未覆盖原文件。") }
        let result=try JSONDecoder().decode(NotebookLibrary.self,from:Data(contentsOf:url))
        try result.validate();return result
    }
    static func save(_ library:NotebookLibrary,to directory:URL) throws {
        try library.validate()
        let data=try JSONEncoder().encode(library)
        guard data.count<=maximumBytes else { throw KitError.message("笔记库已超过 20 MB，请先缩减内容后重试保存。") }
        let fm=FileManager.default
        if fm.fileExists(atPath:directory.path), (try directory.resourceValues(forKeys:[.isSymbolicLinkKey])).isSymbolicLink == true { throw KitError.message("笔记目录不能为符号链接。") }
        try fm.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try fm.setAttributes([.posixPermissions:0o700],ofItemAtPath:directory.path)
        let temp=directory.appendingPathComponent(".Library-\(UUID().uuidString).tmp")
        defer { try? fm.removeItem(at:temp) }
        guard fm.createFile(atPath:temp.path,contents:data,attributes:[.posixPermissions:0o600]) else { throw KitError.message("无法创建笔记保存文件。") }
        let handle=try FileHandle(forWritingTo:temp);try handle.synchronize();try handle.close()
        let target=directory.appendingPathComponent("Library.json")
        guard rename(temp.path,target.path)==0 else { throw KitError.message("笔记原子保存失败，内存内容仍保留。") }
    }
}
final class NotebookStore: ObservableObject {
    @Published private(set) var library: NotebookLibrary
    @Published var selection: UUID?
    @Published var folderSelection: UUID?
    @Published var search = ""
    @Published var showingTrash = false
    @Published var status = ""
    @Published private(set) var loadFailed = false
    @Published private(set) var dirty = false
    /// Called after every local mutation so the sync engine can mirror the change.
    var onLibraryChange: (() -> Void)?
    private let directory: URL
    private var pending: DispatchWorkItem?
    private var termination: NSObjectProtocol?
    init(directory:URL=NotebookDisk.directory) {
        self.directory=directory
        do { library=try NotebookDisk.load(from:directory) }
        catch { library = .empty();loadFailed=true;status="读取笔记库失败；为保护原文件，已暂停编辑。请先备份并检查 Library.json。" }
        selection=library.notes.filter{$0.deletedAt == nil}.sorted{$0.updatedAt > $1.updatedAt}.first?.id
        termination=NotificationCenter.default.addObserver(forName:NSApplication.willTerminateNotification,object:nil,queue:.main) { [weak self] _ in self?.flush() }
    }
    deinit { pending?.cancel();if let termination=termination { NotificationCenter.default.removeObserver(termination) } }
    var visibleNotes: [NotebookNote] {
        library.notes.filter { note in
            (showingTrash ? note.deletedAt != nil : note.deletedAt == nil) &&
            (folderSelection == nil || note.folderID == folderSelection) &&
            (search.isEmpty || note.title.localizedCaseInsensitiveContains(search) || note.markdown.localizedCaseInsensitiveContains(search))
        }.sorted { a,b in a.pinned != b.pinned ? a.pinned : a.updatedAt>b.updatedAt }
    }
    var current: NotebookNote? { library.notes.first{$0.id == selection} }
    func selectFolder(_ id:UUID?,trash:Bool=false) { folderSelection=id;showingTrash=trash;selection=visibleNotes.first?.id }
    func addNote() {
        guard !loadFailed else { return }
        let note=NotebookNote(folderID:folderSelection ?? library.folders[0].id)
        library.notes.append(note);search="";showingTrash=false;selection=note.id;changed(immediate:true)
    }
    func addFolder(_ name:String) {
        let value=name.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !loadFailed,!value.isEmpty else { return }
        let folder=NotebookFolder(id:UUID(),name:String(value.prefix(80)))
        library.folders.append(folder);selectFolder(folder.id);changed(immediate:true)
    }
    func renameFolder(_ id:UUID,name:String) {
        let value=name.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !loadFailed,!value.isEmpty,let index=library.folders.firstIndex(where:{$0.id == id}) else { return }
        library.folders[index].name=String(value.prefix(80));changed(immediate:true)
    }
    func removeFolder(_ id:UUID) {
        guard !loadFailed, library.folders.count>1,let other=library.folders.first(where:{$0.id != id}) else { return }
        // Folder removal never deletes its notes; all notes, including trash, move safely.
        for index in library.notes.indices where library.notes[index].folderID == id { library.notes[index].folderID=other.id }
        library.folders.removeAll{$0.id == id};selectFolder(other.id);changed(immediate:true)
    }
    func edit(_ id:UUID,title:String?=nil,markdown:String?=nil) {
        guard !loadFailed,let i=library.notes.firstIndex(where:{$0.id == id}),library.notes[i].deletedAt == nil else { return }
        if let markdown=markdown,markdown.utf8.count>1_000_000 { status="单篇笔记最多 1 MB，超限修改未写入。";return }
        if let title=title { library.notes[i].title=String(title.prefix(200)) }
        if let markdown=markdown { library.notes[i].markdown=markdown }
        library.notes[i].updatedAt=Date();changed()
    }
    func togglePin(_ id:UUID) { guard !loadFailed,let i=library.notes.firstIndex(where:{$0.id == id}) else { return };library.notes[i].pinned.toggle();changed(immediate:true) }
    func move(_ id:UUID,to folder:UUID) {
        guard !loadFailed,library.folders.contains(where:{$0.id == folder}),let i=library.notes.firstIndex(where:{$0.id == id}) else { return }
        library.notes[i].folderID=folder;folderSelection=folder;changed(immediate:true)
    }
    func trash(_ id:UUID) {
        guard !loadFailed,let i=library.notes.firstIndex(where:{$0.id == id}) else { return }
        library.notes[i].deletedAt=Date();selection=visibleNotes.first?.id;changed(immediate:true)
    }
    func restore(_ id:UUID) {
        guard !loadFailed,let i=library.notes.firstIndex(where:{$0.id == id}) else { return }
        library.notes[i].deletedAt=nil;showingTrash=false;folderSelection=nil;selection=id;changed(immediate:true)
    }
    private func changed(immediate:Bool=false) {
        dirty=true;status="保存中…";pending?.cancel()
        onLibraryChange?()
        if immediate { flush();return }
        let work=DispatchWorkItem { [weak self] in self?.flush() };pending=work
        DispatchQueue.main.asyncAfter(deadline:.now()+0.35,execute:work)
    }
    func flush() {
        pending?.cancel();pending=nil
        guard dirty,!loadFailed else { return }
        do { try NotebookDisk.save(library,to:directory);dirty=false;status="已保存到本机" }
        catch { status="保存失败：\(error.localizedDescription)；内容仍在内存，可复制后重试。" }
    }
    /// Replace the in-memory library with a merged sync result and write it locally.
    /// The caller guarantees no local edit is in flight.
    func applyRemoteLibrary(_ merged: NotebookLibrary) {
        guard !loadFailed else { return }
        library = merged
        if let selected = selection, !merged.notes.contains(where: { $0.id == selected }) {
            selection = visibleNotes.first?.id
        }
        if let folder = folderSelection, !merged.folders.contains(where: { $0.id == folder }) {
            folderSelection = nil
        }
        do {
            try NotebookDisk.save(merged, to: directory)
            dirty = false
            status = "已从同步文件夹更新"
        } catch {
            dirty = true
            status = "同步内容已载入，但本机保存失败：\(error.localizedDescription)"
        }
    }
}
