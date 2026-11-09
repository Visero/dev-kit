import AppKit
import Foundation

// Standalone test for the native formatter engine bundle.
// Run: xcrun swiftc -O Tests/NativeFormatterEngineTests.swift -o build/native-formatter-tests && build/native-formatter-tests
// It locates Resources/Formatters/native/ relative to the project root (two levels up from the test binary).

@main
struct NativeFormatterEngineTests {
    static var passed = 0
    static var failed = 0

    static func check(_ name: String, _ condition: Bool, _ detail: String = "") {
        if condition {
            passed += 1
        } else {
            failed += 1
            print("FAIL: \(name)\(detail.isEmpty ? "" : " -- \(detail)")")
        }
    }

    /// Locate the native formatter root: <project>/Resources/Formatters/native
    static func nativeRoot() -> URL {
        let fm = FileManager.default
        // Try relative to cwd
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
        // Walk up to find project root (contains Resources/)
        var dir = cwd
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent("Resources/Formatters/native")
            if fm.fileExists(atPath: candidate.appendingPathComponent("manifest.json").path) {
                return candidate
            }
            dir.deleteLastPathComponent()
        }
        // Fallback: relative to test binary
        let exec = URL(fileURLWithPath: fm.currentDirectoryPath)
        return exec.appendingPathComponent("Resources/Formatters/native")
    }

    /// Run a formatter binary with stdin input.
    /// Returns (stdoutString, stderrString, exitCode).
    static func runFormatter(exec: String, args: [String], input: String, root: URL) -> (String, String, Int32) {
        let proc = Process()
        proc.executableURL = root.appendingPathComponent(exec)
        proc.arguments = args
        proc.environment = [:]  // clean environment for offline isolation test

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        do {
            try proc.run()
        } catch {
            return ("", "failed to launch \(exec): \(error)", -1)
        }

        stdinPipe.fileHandleForWriting.write(input.data(using: .utf8)!)
        try? stdinPipe.fileHandleForWriting.close()

        proc.waitUntilExit()

        let outData = (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data()
        let errData = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
        return (
            String(data: outData, encoding: .utf8) ?? "",
            String(data: errData, encoding: .utf8) ?? "",
            proc.terminationStatus
        )
    }

    static func main() {
        let root = nativeRoot()
        let fm = FileManager.default
        check("native root exists", fm.fileExists(atPath: root.path), root.path)
        check("manifest.json exists", fm.fileExists(atPath: root.appendingPathComponent("manifest.json").path))

        // ---------- Python (ruff) ----------
        do {
            let (out, err, code) = runFormatter(
                exec: "bin/ruff",
                args: ["format", "--isolated", "-"],
                input: "x=1\ny=2\nprint(x+y)\n",
                root: root
            )
            check("python: formats unformatted", code == 0 && out.contains("x = 1"), "code=\(code) out=\(out) err=\(err)")
            check("python: idempotent", {
                let (out2, _, code2) = runFormatter(exec: "bin/ruff", args: ["format", "--isolated", "-"], input: out, root: root)
                return code2 == 0 && out2 == out
            }())
            let (badOut, badErr, badCode) = runFormatter(
                exec: "bin/ruff",
                args: ["format", "--isolated", "-"],
                input: "def broken(:\n",
                root: root
            )
            check("python: rejects syntax error", badCode != 0 && badOut.isEmpty, "code=\(badCode) out=\(badOut)")
            // string/semicolon sensitivity
            let (strOut, _, _) = runFormatter(
                exec: "bin/ruff",
                args: ["format", "--isolated", "-"],
                input: "s = \"hello ; world\"\n",
                root: root
            )
            check("python: preserves string semicolons", strOut.contains("hello ; world"), strOut)
        }

        // ---------- Go (gofmt) ----------
        do {
            let input = "package main\nimport \"fmt\"\nfunc main(){x:=1;fmt.Println(x)}\n"
            let (out, err, code) = runFormatter(exec: "bin/gofmt", args: [], input: input, root: root)
            check("go: formats unformatted", code == 0 && out.contains("func main()"), "code=\(code) err=\(err)")
            check("go: idempotent", {
                let (out2, _, code2) = runFormatter(exec: "bin/gofmt", args: [], input: out, root: root)
                return code2 == 0 && out2 == out
            }())
            let (badOut, _, badCode) = runFormatter(
                exec: "bin/gofmt", args: [],
                input: "package main\nfunc main( { x := 1 }\n",
                root: root
            )
            check("go: rejects syntax error", badCode != 0 && badOut.isEmpty, "code=\(badCode)")
        }

        // ---------- Swift (swift-format) ----------
        do {
            let (out, err, code) = runFormatter(
                exec: "bin/swift-format", args: ["format", "-"],
                input: "let x=1\nprint(x)\n", root: root
            )
            check("swift: formats unformatted", code == 0 && out.contains("let x = 1"), "code=\(code) err=\(err)")
            check("swift: idempotent", {
                let (out2, _, code2) = runFormatter(exec: "bin/swift-format", args: ["format", "-"], input: out, root: root)
                return code2 == 0 && out2 == out
            }())
            let (badOut, _, badCode) = runFormatter(
                exec: "bin/swift-format", args: ["format", "-"],
                input: "let x = \n", root: root
            )
            check("swift: rejects syntax error", badCode != 0 && badOut.isEmpty, "code=\(badCode)")
            let (strOut, _, _) = runFormatter(
                exec: "bin/swift-format", args: ["format", "-"],
                input: "let s = \"hello ; world\"\n", root: root
            )
            check("swift: preserves string semicolons", strOut.contains("hello ; world"), strOut)
        }

        // ---------- C (clang-format-safe wrapper) ----------
        do {
            let (out, err, code) = runFormatter(
                exec: "bin/clang-format-safe", args: ["--style=LLVM"],
                input: "int main(){int x=1;return x;}\n", root: root
            )
            check("c: formats unformatted", code == 0 && out.contains("int main() {"), "code=\(code) err=\(err)")
            check("c: idempotent", {
                let (out2, _, code2) = runFormatter(exec: "bin/clang-format-safe", args: ["--style=LLVM"], input: out, root: root)
                return code2 == 0 && out2 == out
            }())
            // Preflight: unbalanced paren must be REJECTED (exit 3, empty stdout)
            let (badOut, _, badCode) = runFormatter(
                exec: "bin/clang-format-safe", args: ["--style=LLVM"],
                input: "int main( { int x = ; }\n", root: root
            )
            check("c: preflight rejects unbalanced paren", badCode == 3 && badOut.isEmpty, "code=\(badCode) out=\(badOut)")
            // Preflight: unterminated string must be REJECTED
            let (strBadOut, _, strBadCode) = runFormatter(
                exec: "bin/clang-format-safe", args: ["--style=LLVM"],
                input: "char* s = \"unclosed;\n", root: root
            )
            check("c: preflight rejects unterminated string", strBadCode == 3 && strBadOut.isEmpty, "code=\(strBadCode)")
            // Preflight: unterminated block comment must be REJECTED
            let (cmtOut, _, cmtCode) = runFormatter(
                exec: "bin/clang-format-safe", args: ["--style=LLVM"],
                input: "int x = 1; /* never closed\n", root: root
            )
            check("c: preflight rejects unterminated block comment", cmtCode == 3 && cmtOut.isEmpty, "code=\(cmtCode)")
            // Raw string literal must format correctly (previously was false-rejected by string-aware net)
            let (rawOut, _, rawCode) = runFormatter(
                exec: "bin/clang-format-safe", args: ["--style=LLVM"],
                input: "#include <string>\nstd::string r = R\"(raw \\\"quote\\\")\";\nstd::string r2 = R\"#(contains \\\")\\\")#\";\n", root: root
            )
            check("c++: raw string R\"(...)\" formats", rawCode == 0 && rawOut.contains("R\"("), "code=\(rawCode) out=\(rawOut)")
            // Bracket-balanced but semantically broken passes through (documented gap — preflight is lexical not semantic)
            let (semOut, _, semCode) = runFormatter(
                exec: "bin/clang-format-safe", args: ["--style=LLVM"],
                input: "int main() { int x = ; }\n", root: root
            )
            check("c: bracket-balanced semantic error passes (documented gap)", semCode == 0, "code=\(semCode)")
            let (strOut, _, _) = runFormatter(
                exec: "bin/clang-format-safe", args: ["--style=LLVM"],
                input: "const char* s=\"hello;world\";\n", root: root
            )
            check("c: preserves string semicolons", strOut.contains("hello;world"), strOut)
        }

        // ---------- C++ (clang-format-safe wrapper) ----------
        do {
            let (out, _, code) = runFormatter(
                exec: "bin/clang-format-safe", args: ["--style=LLVM"],
                input: "int main(){int x=1;return x;}\n", root: root
            )
            check("cpp: formats unformatted", code == 0 && out.contains("int main() {"), "code=\(code)")
            check("cpp: idempotent", {
                let (out2, _, code2) = runFormatter(exec: "bin/clang-format-safe", args: ["--style=LLVM"], input: out, root: root)
                return code2 == 0 && out2 == out
            }())
            // C++: unbalanced paren must be REJECTED by preflight
            let (badOut, _, badCode) = runFormatter(
                exec: "bin/clang-format-safe", args: ["--style=LLVM"],
                input: "void foo( { if (true) { return; }\n", root: root
            )
            check("cpp: preflight rejects unbalanced paren", badCode == 3 && badOut.isEmpty, "code=\(badCode)")
            // C++17 raw string with delimiter must format without false rejection
            let (rawOut, _, rawCode) = runFormatter(
                exec: "bin/clang-format-safe", args: ["--style=LLVM"],
                input: "std::string r = R\"#(contains \\\")\\\")#\";\n", root: root
            )
            check("cpp: R\"#(...)#\" delimiter raw string formats", rawCode == 0 && rawOut.contains("R\"#("), "code=\(rawCode)")
        }

        // ---------- Shell (shfmt) ----------
        do {
            let (out, err, code) = runFormatter(
                exec: "bin/shfmt-safe", args: ["-i", "    ", "-"],
                input: "if true; then\necho hi\nfi\n", root: root
            )
            check("shell: formats unformatted", code == 0 && out.contains("    echo hi"), "code=\(code) err=\(err)")
            check("shell: idempotent", {
                let (out2, _, code2) = runFormatter(exec: "bin/shfmt-safe", args: ["-i", "    ", "-"], input: out, root: root)
                return code2 == 0 && out2 == out
            }())
            let (badOut, _, badCode) = runFormatter(
                exec: "bin/shfmt-safe", args: ["-i", "    ", "-"],
                input: "if [ -f x ; then echo \"hi\"\n", root: root
            )
            check("shell: rejects syntax error", badCode != 0 && badOut.isEmpty, "code=\(badCode)")
        }

        // ---------- Rust (rustfmt) ----------
        do {
            let (out, err, code) = runFormatter(
                exec: "bin/rustfmt-safe", args: ["--edition", "2024"],
                input: "fn main(){let x=1;println!(\"{}\",x)}\n", root: root
            )
            check("rust: formats unformatted", code == 0 && out.contains("fn main() {"), "code=\(code) err=\(err)")
            check("rust: idempotent", {
                let (out2, _, code2) = runFormatter(exec: "bin/rustfmt-safe", args: ["--edition", "2024"], input: out, root: root)
                return code2 == 0 && out2 == out
            }())
            let (badOut, _, badCode) = runFormatter(
                exec: "bin/rustfmt-safe", args: ["--edition", "2024"],
                input: "fn main( { let x = ; }\n", root: root
            )
            check("rust: rejects syntax error", badCode != 0 && badOut.isEmpty, "code=\(badCode)")
            let (strOut, _, _) = runFormatter(
                exec: "bin/rustfmt-safe", args: ["--edition", "2024"],
                input: "fn main(){let s=\"hello;world\";}\n", root: root
            )
            check("rust: preserves string semicolons", strOut.contains("hello;world"), strOut)
        }

        // ---------- Summary ----------
        print("NativeFormatterEngineTests: \(passed) passed, \(failed) failed")
        if failed > 0 {
            exit(1)
        }
    }
}
