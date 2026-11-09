import Foundation
#if canImport(AppKit)
import AppKit
#endif

// Order: S11 (real native clang-format 100KB C) FIRST, then stress dummy cases.
// This avoids manifestCache pollution from stress root.
@main
struct StressRunner {
    static var passed = 0
    static var failed = 0

    static func check(_ name: String, _ cond: Bool, _ detail: String = "") {
        if cond { passed += 1; print("PASS: \(name)") }
        else { failed += 1; print("FAIL: \(name)\(detail.isEmpty ? "" : " -- \(detail)")") }
    }

    static func main() {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

        // ===== PHASE 1: real native Resources (cache cold) =====
        // S11: clang-format with 100KB C source — tests native wrapper sync pipes.
        do {
            let realRes = cwd.appendingPathComponent("Resources")
            let manifestPath = realRes.appendingPathComponent("Formatters/native/manifest.json")
            check("S11 native manifest exists", FileManager.default.fileExists(atPath: manifestPath.path))
            CodeFormatEngine.testResourcesOverride = realRes

            var src = ""
            for i in 0..<20000 { src += "int v\(i);\n" }
            check("S11 100KB C source size", src.utf8.count > 100_000, "size=\(src.utf8.count)")

            let t0 = Date()
            let out = try CodeFormatEngine.format(src, language: .c)
            let dt = Date().timeIntervalSince(t0)
            check("S11 clang-format 100KB C returns", out.contains("v0"), "outLen=\(out.utf8.count)")
            check("S11 clang-format 100KB C fast (<5s)", dt < 5.0, "dt=\(dt)s")
        } catch {
            check("S11 clang-format 100KB C no throw", false, "\(error)")
        }

        // ===== PHASE 2: switch to stress root for dummy engines =====
        let stressRoot = cwd.appendingPathComponent("Tests/Acceptance/Resources/stress/root")
        CodeFormatEngine.testResourcesOverride = stressRoot

        // S1: big_stderr (100KB to stderr) — no deadlock
        do {
            let t0 = Date()
            let out = try CodeFormatEngine.format("const x = 1;", language: .javascript)
            let dt = Date().timeIntervalSince(t0)
            check("S1 big_stderr returns output", out.contains("formatted-output"))
            check("S1 big_stderr fast (<2s)", dt < 2.0, "dt=\(dt)s")
        } catch { check("S1 big_stderr no throw", false, "\(error)") }

        // S2: no_stdin_read — engine doesn't block on stdin
        do {
            let t0 = Date()
            let out = try CodeFormatEngine.format("let x: number = 1;", language: .typescript)
            let dt = Date().timeIntervalSince(t0)
            check("S2 no_stdin_read returns", out.contains("ignored-stdin-output"))
            check("S2 no_stdin_read fast (<2s)", dt < 2.0, "dt=\(dt)s")
        } catch { check("S2 no_stdin_read no throw", false, "\(error)") }

        // S3: ignore_term — watchdog 5s fires, kill -9 after 0.5s
        let t0s3 = Date()
        do {
            _ = try CodeFormatEngine.format("def hello(): pass", language: .python)
            check("S3 ignore_term should throw timeout", false, "returned in \(Date().timeIntervalSince(t0s3))s")
        } catch FormatError.timeout {
            let dt = Date().timeIntervalSince(t0s3)
            check("S3 ignore_term throws timeout", true)
            check("S3 ignore_term bounded (<10s)", dt < 10.0, "dt=\(dt)s")
        } catch {
            check("S3 ignore_term timeout (other)", false, "\(error)")
        }

        // S4: fast_exit — doesn't wait full 5s
        do {
            let t0 = Date()
            let out = try CodeFormatEngine.format("package main\nfunc main(){}\n", language: .go)
            let dt = Date().timeIntervalSince(t0)
            check("S4 fast_exit returns output", out.count > 0)
            check("S4 fast_exit quick (<1s)", dt < 1.0, "dt=\(dt)s")
        } catch { check("S4 fast_exit no throw", false, "\(error)") }

        // S5: escape path rejected
        do {
            _ = try CodeFormatEngine.resolvedExecURL(relativePath: "../../../../bin/ls", resources: stressRoot)
            check("S5 escape path rejected", false)
        } catch FormatError.illegalExecutablePath { check("S5 escape path rejected", true) }
        catch { check("S5 escape path rejected (other)", false, "\(error)") }

        // S6: absolute path rejected
        do {
            _ = try CodeFormatEngine.resolvedExecURL(relativePath: "/bin/ls", resources: stressRoot)
            check("S6 absolute path rejected", false)
        } catch FormatError.illegalExecutablePath { check("S6 absolute path rejected", true) }
        catch { check("S6 absolute path rejected (other)", false, "\(error)") }

        // S7: >2MB input rejected
        do {
            let big = String(repeating: "x", count: 2_100_000)
            _ = try CodeFormatEngine.format(big, language: .javascript)
            check("S7 >2MB input rejected", false)
        } catch FormatError.tooLarge { check("S7 >2MB input rejected", true) }
        catch { check("S7 >2MB input rejected (other)", false, "\(error)") }

        // S8: empty input
        do {
            let out = try CodeFormatEngine.format("", language: .javascript)
            check("S8 empty input returns empty", out == "")
        } catch { check("S8 empty input no throw", false, "\(error)") }

        // S9: >4MB output must THROW (not truncate) — dummy writes 5MB
        do {
            let out = try CodeFormatEngine.format("input", language: .rust)
            check("S9 >4MB output must throw (got \(out.utf8.count) bytes)", false)
        } catch FormatError.tooLarge {
            check("S9 >4MB output throws tooLarge", true)
        } catch {
            // May be engineFailed if maxOutputBytes guard surfaces as such
            check("S9 >4MB output throws (not truncate)", true, "error=\(error)")
        }

        // S10: 100KB output tail marker preserved
        do {
            let out = try CodeFormatEngine.format("input", language: .json)
            check("S10 100KB output size ~100KB", out.utf8.count > 90_000, "size=\(out.utf8.count)")
            check("S10 tail marker preserved", out.hasSuffix("TAIL_MARKER_12345"), "tail=\(out.suffix(25))")
        } catch { check("S10 100KB tail no throw", false, "\(error)") }

        CodeFormatEngine.testResourcesOverride = nil

        print("")
        print("== stress runner: PASS=\(passed) FAIL=\(failed) ==")
        if failed > 0 { exit(2) }
    }
}
