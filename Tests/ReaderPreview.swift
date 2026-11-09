import SwiftUI
import AppKit

/// A copy of the production app entry with isolated bundle preferences/data.
@main
struct ReaderPreviewApp: App {
    @NSApplicationDelegateAdaptor(DevKitAppDelegate.self) private var delegate
    @StateObject private var store: ToolkitStore
    init() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DevKit-ReaderPreview")
        CodeDraftStore.testDirectoryOverride = root
        UserDefaults.standard.set(false,forKey:CloudSyncEngine.enabledKey)
        _store = StateObject(wrappedValue:ToolkitStore(notebookDirectory:root.appendingPathComponent("Notebook")))
    }
    var body: some Scene {
        WindowGroup("DevKit · 代码阅读器验收") {
            RootView(store:store).frame(minWidth:940,minHeight:660)
        }.defaultSize(width:1200,height:900)
        .commands {
            CommandGroup(replacing:.newItem) { }
            CommandGroup(after:.newItem) {
                Button("打开代码文件…") { CodeReaderManager.shared.chooseFile() }.keyboardShortcut("o",modifiers:.command)
            }
            CommandGroup(replacing:.saveItem) {
                Button("保存") { NSApp.sendAction(#selector(NSDocument.save(_:)),to:nil,from:nil) }.keyboardShortcut("s",modifiers:.command)
            }
            CommandGroup(after:.saveItem) {
                Button("关闭窗口") { NSApp.keyWindow?.performClose(nil) }.keyboardShortcut("w",modifiers:.command)
            }
        }
    }
}
