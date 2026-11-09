import AppKit
import Foundation

/// Integration test: real ToolkitStore + real CodeEditor.Coordinator + NSTextView.
/// Verifies format → canUndo → undo path works end-to-end through store state.
@main
struct StoreIntegrationTests {
    static var passed = 0
    static func check(_ name: String, _ condition: Bool) {
        guard condition else { print("FAIL: \(name)"); exit(1) }
        passed += 1
    }

    static func main() throws {
        // Prevent CodeDraftStore from touching real Application Support.
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("store-int-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        CodeDraftStore.testDirectoryOverride = tmp

        // Real window + text view (matches CodeEditor.makeView).
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        let scrollView = NSTextView.scrollableTextView()
        scrollView.frame = window.contentView!.bounds
        window.contentView?.addSubview(scrollView)
        let view = scrollView.documentView as! NSTextView
        view.isEditable = true; view.allowsUndo = true; view.isRichText = false

        // Real store with isolated preferences (never enable the user's sync in tests).
        let suiteName = "DevKit.StoreTests.\(UUID().uuidString)"
        let prefs = UserDefaults(suiteName:suiteName)!
        defer { prefs.removePersistentDomain(forName:suiteName) }
        prefs.set("19:45",forKey:WorkSchedulePreferences.legacyKey)
        let store = ToolkitStore(notebookDirectory:tmp.appendingPathComponent("Notebook"),scheduleDefaults:prefs)
        check("store weekly migration", store.workWeekSchedule[.monday].time == "19:45")
        var week = store.workWeekSchedule
        week[.friday].time = "18:30"
        week[.saturday] = WorkDaySetting(isWorkday:true,time:"15:00")
        try store.setWorkWeekSchedule(week)
        check("store weekly saved", WorkSchedulePreferences.load(from:prefs) == week)
        check("store weekly sync timestamp", prefs.double(forKey:CloudSyncEngine.settingsStampKey) > 0)
        do { try store.setWorkWeekSchedule(WorkWeekSchedule(days:[]));check("reject malformed week",false) }
        catch { check("reject malformed week keeps store",store.workWeekSchedule == week) }
        let reloaded = ToolkitStore(notebookDirectory:tmp.appendingPathComponent("Notebook2"),scheduleDefaults:prefs)
        check("store weekly restart",reloaded.workWeekSchedule == week)

        // Wire replacement handler (same as CodeFormatPage onReady).
        store.codeReplaceHandler = { newText in
            let r = NSRange(location: 0, length: (view.string as NSString).length)
            _ = view.shouldChangeText(in: r, replacementString: newText)
            view.replaceCharacters(in: r, with: newText)
            view.didChangeText()
        }

        // Set JSON input.
        let input = "{\"name\":\"test\",\"count\":42}"
        store.codeInput = input

        // Run format (JSON uses built-in formatter, synchronous internally).
        store.formatCode()

        // Pump runloop for async completion.
        let runloop = RunLoop.main
        let deadline = Date().addingTimeInterval(3)
        while store.codeBusy && Date() < deadline {
            runloop.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }

        // 1. Format completed, not busy.
        check("format not busy", !store.codeBusy)
        check("format no error", store.codeError.isEmpty)

        // 2. Undo state set.
        check("canUndo true", store.codeCanUndo)
        check("previousText = original", store.codePreviousText == input)

        // 3. codeInput is formatted (pretty-printed JSON).
        check("codeInput formatted", store.codeInput != input)
        check("codeInput has newline", store.codeInput.contains("\n"))

        // 4. View text matches store.
        check("view matches store", view.string == store.codeInput)

        // 5. Undo restores original.
        store.undoFormat()
        check("undo restores input", store.codeInput == input)
        check("canUndo false after undo", !store.codeCanUndo)
        check("view restored", view.string == input)

        // 6. Clear.
        store.clearCode()
        check("clear empties input", store.codeInput.isEmpty)
        check("clear no undo", !store.codeCanUndo)

        print("PASS: \(passed) store integration assertions")
    }
}
