import Foundation

@main
struct DraftTests {
    static var passed = 0
    static func check(_ name: String, _ condition: Bool) {
        guard condition else { print("FAIL: \(name)"); exit(1) }
        passed += 1
    }

    static func main() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("draft-tests-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        CodeDraftStore.testDirectoryOverride = tmp

        // 1. Fresh load = noFile.
        let r1 = CodeDraftStore.load()
        check("fresh load = noFile", r1.outcome == .noFile)
        check("fresh text nil", r1.text == nil)

        // 2. Flush writes file (first save, target doesn't exist).
        CodeDraftStore.flush("hello world")
        check("file exists after flush", fm.fileExists(atPath: CodeDraftStore.fileURL.path))

        // 3. Reload returns saved text.
        let r2 = CodeDraftStore.load()
        check("reload = loaded", r2.outcome == .loaded("hello world"))
        check("reload text correct", r2.text == "hello world")

        // 4. Directory 0700, file 0600.
        let dp = (try fm.attributesOfItem(atPath: tmp.path))[.posixPermissions] as? NSNumber
        check("dir 0700", dp == 0o700)
        let fp = (try fm.attributesOfItem(atPath: CodeDraftStore.fileURL.path))[.posixPermissions] as? NSNumber
        check("file 0600", fp == 0o600)

        // 5. Flush empty (clear) persists.
        CodeDraftStore.flush("")
        let r3 = CodeDraftStore.load()
        check("empty flush loaded", r3.text == "")

        // 6. Debounce coalesces: latest wins.
        CodeDraftStore.scheduleSave("first")
        CodeDraftStore.scheduleSave("second")
        CodeDraftStore.scheduleSave("third")
        Thread.sleep(forTimeInterval: 1.0)
        let r4 = CodeDraftStore.load()
        check("debounce keeps latest", r4.text == "third")

        // 7. Corrupt file = corrupted outcome, NOT loaded.
        try "not valid json".write(to: CodeDraftStore.fileURL, atomically: true, encoding: .utf8)
        let r5 = CodeDraftStore.load()
        check("corrupt = corrupted", r5.outcome == .corrupted)
        check("corrupt text nil", r5.text == nil)

        // 8. After corrupt load, flush refuses to overwrite (protects file).
        //    Re-load corrupt first, then flush should be a no-op.
        try "still corrupt".write(to: CodeDraftStore.fileURL, atomically: true, encoding: .utf8)
        _ = CodeDraftStore.load()  // sets loadHealthy=false
        CodeDraftStore.flush("should not overwrite")
        let afterFlush = try String(contentsOf: CodeDraftStore.fileURL, encoding: .utf8)
        check("corrupt file not overwritten by flush", afterFlush == "still corrupt")

        // 9. userDidEdit() allows subsequent writes.
        CodeDraftStore.userDidEdit()
        CodeDraftStore.flush("recovered")
        let r6 = CodeDraftStore.load()
        check("recovery after userDidEdit", r6.text == "recovered")

        // 10. Missing "text" key = corrupted.
        try "{\"version\":1,\"other\":42}".write(to: CodeDraftStore.fileURL, atomically: true, encoding: .utf8)
        let r7 = CodeDraftStore.load()
        check("missing text key = corrupted", r7.outcome == .corrupted)

        // 11. Large text round-trip.
        let large = String(repeating: "line of code ", count: 3000)
        CodeDraftStore.userDidEdit()
        CodeDraftStore.flush(large)
        check("100KB round-trip", CodeDraftStore.load().text == large)

        // 12. UTF-8 emoji round-trip.
        CodeDraftStore.flush("print(\"Hello 世界 🌍\")")
        check("UTF-8 round-trip", CodeDraftStore.load().text?.contains("🌍") == true)

        print("PASS: \(passed) draft persistence assertions")
    }
}
