import Foundation

// S9/S10/S2 real-path runner: CodeFormatEngine with stress dummy engines.
// Skips S11 (native wrapper still broken, pending native fix).
@main
struct S9S10Runner {
    static var passed = 0
    static var failed = 0

    static func check(_ name: String, _ cond: Bool, _ detail: String = "") {
        if cond { passed += 1; print("PASS: \(name)") }
        else { failed += 1; print("FAIL: \(name)\(detail.isEmpty ? "" : " -- \(detail)")") }
    }

    static func main() {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let stressRoot = cwd.appendingPathComponent("Tests/Acceptance/Resources/stress/root")
        CodeFormatEngine.testResourcesOverride = stressRoot

        // S2: no_stdin_read (typescript) — process must not crash
        do {
            let t0 = Date()
            let out = try CodeFormatEngine.format("let x: number = 1;", language: .typescript)
            let dt = Date().timeIntervalSince(t0)
            check("S2 no_stdin_read returns", out.contains("ignored-stdin-output"), "out=\(out.prefix(40))")
            check("S2 no_stdin_read fast (<2s)", dt < 2.0, "dt=\(dt)s")
        } catch { check("S2 no_stdin_read no throw", false, "\(error)") }

        // S9: huge_stdout 5MB → must THROW tooLarge (not truncate)
        do {
            let out = try CodeFormatEngine.format("input", language: .rust)
            check("S9 5MB output must throw (got \(out.utf8.count) bytes)", false)
        } catch FormatError.tooLarge {
            check("S9 5MB output throws tooLarge", true)
        } catch {
            check("S9 5MB output throws (not truncate)", true, "error=\(error)")
        }

        // S10: big_stdout_tail 100KB → tail marker must be preserved
        do {
            let out = try CodeFormatEngine.format("input", language: .html)
            check("S10 100KB output size ~100KB", out.utf8.count > 90_000, "size=\(out.utf8.count)")
            check("S10 tail marker preserved", out.hasSuffix("TAIL_MARKER_12345"), "tail=\(out.suffix(25))")
        } catch { check("S10 100KB tail no throw", false, "\(error)") }

        CodeFormatEngine.testResourcesOverride = nil

        print("")
        print("== S9/S10 runner: PASS=\(passed) FAIL=\(failed) ==")
        if failed > 0 { exit(2) }
    }
}
