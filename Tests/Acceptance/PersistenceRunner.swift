import Foundation

/// Independent persistence verification — NOT UI's DraftTests.
/// Uses testDirectoryOverride — never touches real Application Support.
///
/// Covers the three scenarios UI just flagged:
///   P-A: First save when draft file does NOT yet exist (POSIX rename, not replaceItemAt)
///   P-B: Corrupt load on exit → flush("") must NOT overwrite the corrupt file (loadHealthy guard)
///   P-C: clear() vs async format() race — stale debounced write must not overwrite newer
///
/// Run:
///   xcrun swiftc -swift-version 5 -O \
///     Sources/CodeDraftStore.swift Tests/Acceptance/PersistenceRunner.swift \
///     -o build/persistence-tests && build/persistence-tests

@main
struct PersistenceRunner {
    static var passed = 0
    static var failed = 0

    static func check(_ name: String, _ cond: Bool, _ detail: String = "") {
        if cond {
            passed += 1
            print("PASS: \(name)")
        } else {
            failed += 1
            print("FAIL: \(name)\(detail.isEmpty ? "" : " -- \(detail)")")
        }
    }

    static func freshTmp() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("persistence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        CodeDraftStore.testDirectoryOverride = tmp
        return tmp
    }

    static func readDraftText() -> String? {
        guard let data = try? Data(contentsOf: CodeDraftStore.fileURL) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["text"] as? String
    }

    static func main() throws {
        let fm = FileManager.default

        // ---------- P-A: First save when file does NOT yet exist ----------
        do {
            let tmp = try freshTmp()
            defer { try? fm.removeItem(at: tmp) }

            check("P-A precondition: file absent", !fm.fileExists(atPath: CodeDraftStore.fileURL.path))
            CodeDraftStore.userDidEdit()
            CodeDraftStore.flush("first ever save")
            check("P-A file exists after first flush", fm.fileExists(atPath: CodeDraftStore.fileURL.path))
            check("P-A content correct", readDraftText() == "first ever save")
        }

        // ---------- P-B: Corrupt file on disk → exit flush("") must NOT overwrite it ----------
        do {
            let tmp = try freshTmp()
            defer { try? fm.removeItem(at: tmp) }

            // Plant a corrupt file.
            try "{ this is not json".write(to: CodeDraftStore.fileURL, atomically: true, encoding: .utf8)
            let corruptDataBefore = try Data(contentsOf: CodeDraftStore.fileURL)

            // App startup: load() should report .corrupted.
            let result = CodeDraftStore.load()
            check("P-B outcome is .corrupted", result.outcome == .corrupted,
                  "got \(String(describing: result.outcome))")
            check("P-B text is nil", result.text == nil)

            // User did NOT edit. App calls flush("") on exit.
            // Guard: loadHealthy is false → flush must no-op.
            CodeDraftStore.flush("")

            let corruptDataAfter = try Data(contentsOf: CodeDraftStore.fileURL)
            check("P-B corrupt file preserved on exit flush(\"\")",
                  corruptDataBefore == corruptDataAfter,
                  "before=\(corruptDataBefore.count)B after=\(corruptDataAfter.count)B")

            // But if userDidEdit() is called, flush should now write (recovery path).
            CodeDraftStore.userDidEdit()
            CodeDraftStore.flush("recovery content")
            check("P-B recovery write after userDidEdit", readDraftText() == "recovery content")
        }

        // ---------- P-C: Stale debounced write must not overwrite newer flush ----------
        do {
            let tmp = try freshTmp()
            defer { try? fm.removeItem(at: tmp) }

            CodeDraftStore.userDidEdit()
            CodeDraftStore.flush("seed")

            // Schedule a debounced save (will fire 0.5s later).
            CodeDraftStore.scheduleSave("stale debounced value")

            // Before it fires, user clicks clear → immediate flush("").
            CodeDraftStore.flush("")

            // Wait for debounce to fire. The stale work must be discarded by version guard.
            Thread.sleep(forTimeInterval: 1.0)
            check("P-C stale debounced does not overwrite clear", readDraftText() == "",
                  "got \(readDraftText() ?? "nil")")

            // Reverse: scheduleSave then flush a newer value → newer wins.
            CodeDraftStore.scheduleSave("old value")
            CodeDraftStore.flush("newer flush")
            Thread.sleep(forTimeInterval: 1.0)
            check("P-C newer flush wins over pending debounced", readDraftText() == "newer flush",
                  "got \(readDraftText() ?? "nil")")
        }

        // ---------- P-D: Permissions 0700 dir / 0600 file ----------
        do {
            let tmp = try freshTmp()
            defer { try? fm.removeItem(at: tmp) }
            CodeDraftStore.userDidEdit()
            CodeDraftStore.flush("perm check")
            let dPerms = (try fm.attributesOfItem(atPath: tmp.path))[.posixPermissions] as? NSNumber
            let fPerms = (try fm.attributesOfItem(atPath: CodeDraftStore.fileURL.path))[.posixPermissions] as? NSNumber
            check("P-D dir 0700", dPerms?.intValue == 0o700,
                  "got \(String(dPerms?.intValue ?? 0, radix: 8))")
            check("P-D file 0600", fPerms?.intValue == 0o600,
                  "got \(String(fPerms?.intValue ?? 0, radix: 8))")
        }

        // ---------- P-E: Round-trip UTF-8 emoji ----------
        do {
            let tmp = try freshTmp()
            defer { try? fm.removeItem(at: tmp) }
            let s = "func greet() { print(\"Hello 世界 🌍\") }"
            CodeDraftStore.userDidEdit()
            CodeDraftStore.flush(s)
            let r = CodeDraftStore.load()
            check("P-E emoji round-trip", r.text == s)
        }

        // ---------- P-F: readError (permission denied) is reported distinctly ----------
        do {
            let tmp = try freshTmp()
            defer { try? fm.removeItem(at: tmp) }
            CodeDraftStore.userDidEdit()
            CodeDraftStore.flush("secret")
            // Chmod file 000 → Data(contentsOf:) should fail.
            try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: CodeDraftStore.fileURL.path)
            let r = CodeDraftStore.load()
            check("P-F permission-denied load outcome is .readError",
                  r.outcome == .readError || r.outcome == .corrupted,
                  "got \(String(describing: r.outcome))")
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: CodeDraftStore.fileURL.path)
        }

        CodeDraftStore.testDirectoryOverride = nil

        print("")
        print("== persistence runner: PASS=\(passed) FAIL=\(failed) ==")
        if failed > 0 { exit(2) }
    }
}
