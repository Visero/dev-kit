import AppKit
import Foundation

@main
struct CodeReaderTests {
    static var passed = 0
    static func check(_ name: String,_ value: Bool) {
        guard value else { print("FAIL: \(name)");exit(1) };passed += 1
    }
    static func rejects(_ name: String,_ action: () throws -> Void) {
        do { try action();check(name,false) } catch { passed += 1 }
    }
    static func save(_ document: CodeReaderDocument, to url: URL) throws {
        var finished = false, failure: Error?
        document.save(to:url,ofType:"public.plain-text",for:.saveOperation) { error in
            failure = error;finished = true
        }
        let deadline = Date().addingTimeInterval(5)
        while !finished && Date() < deadline {
            RunLoop.main.run(until:Date().addingTimeInterval(0.02))
        }
        if let failure { throw failure }
        guard finished else { throw KitError.message("save test timed out") }
    }
    static func main() throws {
        _ = NSApplication.shared
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("DevKit-reader-test-\(UUID())")
        try fm.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? fm.removeItem(at:root) }
        let source = "let value = \"中文👋\" // note\nprint(42)\n"
        let utf8 = try CodeFileSnapshot.decode(Data(source.utf8))
        check("UTF8 exact",utf8.text == source)
        check("unchanged exact bytes",try utf8.encoded(source) == Data(source.utf8))
        for (encoding,bom) in [(String.Encoding.utf8,Data([0xEF,0xBB,0xBF])),(.utf16LittleEndian,Data([0xFF,0xFE])),(.utf16BigEndian,Data([0xFE,0xFF])),(.utf32LittleEndian,Data([0xFF,0xFE,0,0])),(.utf32BigEndian,Data([0,0,0xFE,0xFF]))] {
            let original = bom + source.data(using:encoding)!
            let decoded = try CodeFileSnapshot.decode(original)
            check("BOM decode \(encoding.rawValue)",decoded.text == source && decoded.bom == bom)
            check("BOM retained \(encoding.rawValue)",try decoded.encoded(source+"// edit") == bom+(source+"// edit").data(using:encoding)!)
        }
        let crlf = try CodeFileSnapshot.decode(Data("a\r\nb\r\n".utf8))
        check("CRLF original preserved",try crlf.encoded(crlf.text) == crlf.originalBytes)
        check("CRLF new lines preserved",try crlf.encoded("a\r\nb\r\nc\n") == Data("a\r\nb\r\nc\r\n".utf8))
        let mixed = try CodeFileSnapshot.decode(Data("a\r\nb\nc\r".utf8))
        check("mixed stays exact",try mixed.encoded(mixed.text) == mixed.originalBytes)
        check("mixed edit not normalized",try mixed.encoded(mixed.text+"d\n") == Data((mixed.text+"d\n").utf8))
        rejects("reject binary") { _ = try CodeFileSnapshot.decode(Data([0,1,2])) }
        rejects("reject invalid utf8") { _ = try CodeFileSnapshot.decode(Data([0xFF,0x80])) }
        rejects("reject oversized") { _ = try CodeFileSnapshot.decode(Data(repeating:65,count:10_000_001)) }
        check("empty file",try CodeFileSnapshot.decode(Data()).text.isEmpty)
        for (text,starts) in [("",[0]),("a",[0]),("a\n",[0,2]),("a\r\nb\r\n",[0,3,6]),("👋\nx",[0,3]),("a\rb",[0,2])] {
            let index = CodeLineIndex(text)
            check("line starts \(text.debugDescription)",index.starts == starts)
            check("line binary lookup",index.lineIndex(at:text.utf16.count) == starts.count-1)
        }
        check("extension overrides detection",CodeFileLanguage.resolve(URL(fileURLWithPath:"/a.swift"),text:"{}") == .swift)
        check("JSX highlighted",CodeFileLanguage.resolve(URL(fileURLWithPath:"/a.jsx"),text:"") == .javascript)
        check("unknown detection",CodeFileLanguage.resolve(URL(fileURLWithPath:"/a"),text:"#!/bin/bash\necho hello") == .shell)
        let prefsName = "DevKit.ReaderTests.\(UUID())"
        let prefs = UserDefaults(suiteName:prefsName)!
        defer { prefs.removePersistentDomain(forName:prefsName) }
        // The temporary suite is never the user's production preference domain.
        let recents = RecentCodeFiles(defaults:prefs)
        for i in 0..<7 { recents.record(root.appendingPathComponent("file\(i).swift")) }
        check("recent limit",recents.urls.count == 5)
        check("recent newest first",recents.urls.first?.lastPathComponent == "file6.swift")
        recents.record(root.appendingPathComponent("file3.swift"))
        check("recent duplicate moves front",recents.urls.count == 5 && recents.urls.first?.lastPathComponent == "file3.swift")
        check("recent restart",RecentCodeFiles(defaults:prefs).urls == recents.urls)
        prefs.removeObject(forKey:RecentCodeFiles.key)
        _ = prefsName
        let url = root.appendingPathComponent("sample.swift")
        try Data(source.utf8).write(to:url)
        let snapshot = try CodeFileSnapshot.read(url)
        rejects("reject directory") { _ = try CodeFileSnapshot.read(root) }
        rejects("reject nonfile URL") { _ = try CodeFileSnapshot.read(URL(string:"https://example.com/test.swift")!) }
        let document = CodeReaderDocument(url:url,snapshot:snapshot)
        document.makeWindowControllers()
        guard let controller = document.windowControllers.compactMap({ $0 as? CodeReaderWindowController }).first else {
            print("FAIL: expected code reader controller; actual \(document.windowControllers.map { String(describing:type(of:$0)) })")
            exit(1)
        }
        let view = controller.editor
        check("independent code-only content",controller.window?.contentView === controller.scroll)
        check("gutter enabled",controller.scroll.rulersVisible && controller.scroll.verticalRulerView is CodeLineRuler)
        check("gutter correct lines",controller.ruler.index.starts.count == 3)
        check("editable plain text",view.isEditable && !view.isRichText)
        check("initial document clean",!document.isDocumentEdited)
        view.setSelectedRange(NSRange(location:4,length:0))
        let originalSelection = view.selectedRange()
        RunLoop.main.run(until:Date().addingTimeInterval(0.4))
        check("highlight preserves selection",view.selectedRange() == originalSelection)
        check("highlight no dirty state",!document.isDocumentEdited)
        check("highlight temporary only",view.layoutManager?.temporaryAttribute(.foregroundColor,atCharacterIndex:0,effectiveRange:nil) is NSColor)
        view.insertText("// changed\n",replacementRange:NSRange(location:0,length:0))
        check("editor updates buffer",document.buffer == view.string && document.buffer.hasPrefix("// changed\n"))
        check("native edit marks dirty",document.isDocumentEdited)
        check("native undo exists",document.undoManager?.canUndo == true)
        document.undoManager?.undo()
        check("undo returns exact source",view.string == source && document.buffer == source)
        check("undo returns clean",!document.isDocumentEdited)
        view.insertText("// saved\n",replacementRange:NSRange(location:0,length:0))
        try save(document,to:url)
        check("save exact disk bytes",try String(contentsOf:url,encoding:.utf8) == document.buffer)
        check("save clean",!document.isDocumentEdited)
        let diskBeforeConflict = Data("// external\n".utf8)
        try diskBeforeConflict.write(to:url)
        document.buffer += "// unsaved"
        rejects("external modification refused") { try save(document,to:url) }
        check("external content preserved",try Data(contentsOf:url) == diskBeforeConflict)
        document.close()
        // Exercise the same file routing used by the sidebar and app delegate.
        let controllerSet = NSDocumentController()
        let manager = CodeReaderManager(defaults:prefs,documents:controllerSet)
        for i in 0..<7 {
            let file = root.appendingPathComponent("opened\(i).swift")
            try Data(source.utf8).write(to:file)
            check("file route \(i)",manager.open(file))
        }
        check("manager recent cap",manager.recent.urls.count == 5)
        check("manager document count",controllerSet.documents.count == 7)
        let opened = controllerSet.documents.last as! CodeReaderDocument
        opened.buffer += "// keep pending edit"
        check("repeat route succeeds",manager.open(opened.fileURL!))
        check("repeat route reuses window",controllerSet.documents.count == 7)
        check("repeat route preserves unsaved",opened.buffer.hasSuffix("// keep pending edit"))
        for doc in controllerSet.documents { doc.close() }
        print("PASS: \(passed) code reader assertions")
    }
}
