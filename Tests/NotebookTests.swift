import Foundation
import AppKit
import SwiftUI

@main
struct NotebookTests {
    static var count=0
    static func check(_ name:String,_ value:Bool) { if !value { print("FAIL: \(name)");exit(1) };count+=1 }
    static func main() throws {
        _=NSApplication.shared
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("DevKit-notebook-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at:root) }
        let store=NotebookStore(directory:root)
        check("fresh empty",store.library.notes.isEmpty && store.library.folders.count==1)
        check("load has no writes",!FileManager.default.fileExists(atPath:root.path))
        store.addNote();let first=store.selection!
        store.edit(first,title:"学习笔记",markdown:"# 中文 👩🏽‍💻\n**bold** and *italic*\n- [ ] task\n```swift\nlet x = 1\n```\n")
        store.flush()
        let reopened=NotebookStore(directory:root)
        check("restart title",reopened.current?.title=="学习笔记")
        check("restart unicode markdown",reopened.current?.markdown==store.current?.markdown)
        check("file perms",(try FileManager.default.attributesOfItem(atPath:root.appendingPathComponent("Library.json").path)[.posixPermissions] as? Int)==0o600)
        check("directory perms",(try FileManager.default.attributesOfItem(atPath:root.path)[.posixPermissions] as? Int)==0o700)
        store.addFolder("项目");let folder=store.folderSelection!
        store.addNote();let second=store.selection!
        store.edit(second,title:"第二篇",markdown:"Needle 123");store.flush()
        store.selectFolder(nil);store.search="needle"
        check("search content",store.visibleNotes.map(\.id)==[second])
        store.search="学习"
        check("search title",store.visibleNotes.map(\.id)==[first])
        store.search="";store.togglePin(first)
        check("pin first",store.visibleNotes.first?.id==first)
        store.move(first,to:folder)
        check("move folder",store.library.notes.first{$0.id==first}?.folderID==folder)
        store.renameFolder(folder,name:"  项目 A  ")
        check("rename folder",store.library.folders.first{$0.id==folder}?.name=="项目 A")
        store.trash(first)
        check("soft delete",store.library.notes.count==2 && !store.visibleNotes.contains{$0.id==first})
        store.selectFolder(nil,trash:true)
        check("trash list",store.visibleNotes.map(\.id)==[first])
        store.restore(first)
        check("restore",store.current?.id==first && store.current?.deletedAt==nil)
        store.removeFolder(folder)
        check("remove folder preserves notes",store.library.folders.count==1 && store.library.notes.count==2 && store.library.notes.allSatisfy{$0.folderID==store.library.folders[0].id})
        let remaining=store.library.folders[0].id;store.removeFolder(remaining)
        check("retain last folder",store.library.folders.count==1)
        for i in 0..<50 { store.edit(first,markdown:"Latest \(i)") }
        store.flush();check("latest write wins",try NotebookDisk.load(from:root).notes.first{$0.id==first}?.markdown=="Latest 49")
        store.edit(first,markdown:"");store.flush()
        check("empty persists",try NotebookDisk.load(from:root).notes.first{$0.id==first}?.markdown=="")
        let bad=root.appendingPathComponent("corrupt");try FileManager.default.createDirectory(at:bad,withIntermediateDirectories:true)
        let badFile=bad.appendingPathComponent("Library.json"),badData=Data("not json".utf8);try badData.write(to:badFile)
        let broken=NotebookStore(directory:bad);broken.addNote();broken.flush()
        check("corruption read only",broken.loadFailed && broken.library.notes.isEmpty)
        check("corrupt original preserved",try Data(contentsOf:badFile)==badData)
        let noteText="# 标题 👋\n**bold** and *italic* and ~~gone~~\n`<script>`\n[链接](https://example.com)\n- [ ] todo\n> quote\n```swift\n# not heading\n```\n"
        let all=NSRange(location:0,length:noteText.utf16.count)
        let paints=MarkdownStyler.paints(noteText,activeRange:NSRange(location:0,length:0),dark:false)
        check("markdown ranges",paints.allSatisfy{$0.range.location>=0 && NSMaxRange($0.range)<=all.length})
        check("nonactive markers hidden",paints.contains{($0.attributes[.foregroundColor] as? NSColor)==NSColor.clear})
        check("heading style",paints.contains{($0.attributes[.font] as? NSFont)?.pointSize==28})
        check("inline bold style",paints.contains{($0.attributes[.font] as? NSFont)==NSFont.boldSystemFont(ofSize:15)})
        check("strike style",paints.contains{$0.attributes[.strikethroughStyle] != nil})
        let firstLine=(noteText as NSString).lineRange(for:NSRange(location:0,length:0))
        let active=MarkdownStyler.paints(noteText,activeRange:firstLine,dark:true)
        check("active heading marker revealed",!active.contains{$0.range.location==0 && ($0.attributes[.foregroundColor] as? NSColor)==NSColor.clear})
        check("fenced heading not interpreted",!paints.contains{$0.range.location==(noteText as NSString).range(of:"not heading").location && ($0.attributes[.font] as? NSFont)?.pointSize==28})
        var bound=noteText
        let editor=MarkdownEditor(text:Binding(get:{bound},set:{bound=$0}))
        let coordinator=MarkdownEditor.Coordinator(editor)
        let view=MarkdownTextView(frame:NSRect(x:0,y:0,width:500,height:500))
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:500,height:500),styleMask:[.titled],backing:.buffered,defer:false)
        window.contentView=view;view.isRichText=false;view.allowsUndo=true;view.string=noteText;view.delegate=coordinator;coordinator.view=view
        view.setSelectedRange(NSRange(location:4,length:0));let selection=view.selectedRange();coordinator.render()
        check("render source unchanged",view.string==noteText)
        check("render selection unchanged",view.selectedRange()==selection)
        check("render no undo",view.undoManager?.canUndo != true)
        view.setSelectedRange((noteText as NSString).range(of:"bold"));coordinator.insert(prefix:"**",suffix:"**")
        check("toolbar inserts",bound.contains("****bold****"))
        check("toolbar undo registered",view.undoManager?.canUndo == true)
        view.undoManager?.undo();check("undo restores source",view.string==noteText)
        coordinator.parent.sourceMode=true;coordinator.render()
        check("source mode marker visible",view.textStorage?.attribute(.foregroundColor,at:0,effectiveRange:nil) as? NSColor == .labelColor)
        for t in ["", "## ", "**未结束", "👩🏽‍💻 **文本**", "```\n# h\n", "a\n"] {
            view.string=t;view.setSelectedRange(NSRange(location:t.utf16.count,length:0));coordinator.parent.sourceMode=false;coordinator.render()
            check("edge render source",view.string==t)
        }
        check("default tools",ToolPage.defaultOrder == [.clock,.diff,.json,.notes,.reader,.stocks])
        check("order migration",ToolPage.migratedOrder(["json","epoch","clock","diff","json","unknown"]) == [.json,.clock,.diff,.notes,.reader,.stocks])
        check("time name",ToolPage.clock.title=="时间中心")
        print("PASS: \(count) notebook/Markdown/navigation assertions")
    }
}
