import SwiftUI
import AppKit

/// Compile with Sources/*.swift -DBUILD_TEST to inspect the actual production UI
/// without touching the user's notebook, drafts, preferences or iCloud folder.
@main
struct WeeklyPreviewApp: App {
    @StateObject private var store: ToolkitStore
    init() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DevKit-WeeklyPreview")
        CodeDraftStore.testDirectoryOverride = root
        let prefs = UserDefaults.standard
        prefs.set(false,forKey:CloudSyncEngine.enabledKey)
        _store = StateObject(wrappedValue:ToolkitStore(notebookDirectory:root.appendingPathComponent("Notebook"),scheduleDefaults:prefs))
    }
    var body: some Scene {
        WindowGroup("DevKit · 每周倒计时验收") {
            RootView(store:store).frame(minWidth:940,minHeight:660)
        }.defaultSize(width:1200,height:900)
    }
}
