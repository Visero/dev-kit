import Foundation

// Independent integration tests for the web external formatters.
// This file is self-contained and does NOT require any changes to test.sh;
// it resolves the bundled engine under Resources/Formatters/web and verifies
// the manifest contract: stdin=text, stdout=formatted-only-on-success,
// stderr=diagnostics, non-zero exit with empty stdout on any error.
//
// Build/run manually (example):
//   swiftc -O Tests/WebFormatterTests.swift -o build/web-formatter-tests
//   ./build/web-formatter-tests

@main
struct WebFormatterTests {
    static var passed = 0
    static var failures = 0

    static func check(_ name: String, _ condition: Bool, _ detail: String = "") {
        if condition {
            passed += 1
        } else {
            failures += 1
            print("FAIL: \(name) \(detail)")
        }
    }

    // Locate the project root and the bundled web formatter resources.
    static func resourcesDir() -> URL {
        // Walk up from the executable to find Contents/Resources fallback:
        // in the built app it is <App>/Contents/Resources; in dev we use
        // <repo>/Resources.
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        var dir = cwd
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent("Resources/Formatters/web/manifest.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return dir.appendingPathComponent("Resources")
            }
            dir.deleteLastPathComponent()
        }
        fatalError("Cannot locate Resources/Formatters/web; run from the repo root or built app.")
    }

    // Run the engine for a language with given source; returns (stdout, stderr, exitCode).
    static func run(language: String, indent: String, source: String) -> (String, String, Int32) {
        let res = resourcesDir()
        let launcher = res.appendingPathComponent("Formatters/web/bin/format")
        let api = Process()
        api.executableURL = launcher
        api.arguments = [res.path, language, indent]
        // Isolate from any project config / system node.
        api.environment = ["PATH": "/usr/bin:/bin", "HOME": NSTemporaryDirectory()]

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        api.standardInput = inPipe
        api.standardOutput = outPipe
        api.standardError = errPipe

        do { try api.run() } catch {
            return ("", "launch error: \(error)", -1)
        }
        inPipe.fileHandleForWriting.write(source.data(using: .utf8)!)
        try? inPipe.fileHandleForWriting.close()
        api.waitUntilExit()

        let outData = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
        let errData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
        return (String(data: outData, encoding: .utf8) ?? "",
                String(data: errData, encoding: .utf8) ?? "",
                api.terminationStatus)
    }

    static func expectValid(_ lang: String, _ src: String, _ contains: String) {
        let (out, err, code) = run(language: lang, indent: "  ", source: src)
        check("\(lang) exit 0", code == 0, "code=\(code) err=\(err)")
        check("\(lang) stdout non-empty", !out.isEmpty)
        check("\(lang) output contains expected", out.contains(contains), "out=\(out)")
    }

    static func expectReject(_ lang: String, _ src: String) {
        let (out, err, code) = run(language: lang, indent: "  ", source: src)
        check("\(lang) error non-zero exit", code != 0, "code=\(code)")
        check("\(lang) error stdout empty", out.isEmpty, "stdout=\(out)")
        check("\(lang) error stderr has diagnostic", !err.isEmpty, "err empty")
    }

    static func expectIdempotent(_ lang: String, _ src: String) {
        let first = run(language: lang, indent: "  ", source: src).0
        let second = run(language: lang, indent: "  ", source: first).0
        check("\(lang) idempotent", first == second, "1st≠2nd")
    }

    static func main() {
        // Valid formatting samples (suggested recognition samples for the lexer package).
        expectValid("javascript", "const a={x:1};console.log(a.x);", "const a = { x: 1 };")
        expectValid("typescript", "const n:number=1;export const f=(x:number)=>x+1;", "const n: number = 1;")
        expectValid("html", "<div><p>Hi</p></div>", "<div>")
        expectValid("css", ".a{color:red;margin:0}", "color: red;")
        expectValid("java", "class A{int x=1;void f(){if(x>0){x++;}}}", "class A {")
        expectValid("sql", "select a,b from t where x=1 group by a", "SELECT")

        // String / comment / semicolon sensitivity: content must survive.
        let jsStr = run(language: "javascript", indent: "  ",
                        source: "const s=\"a;b{c}\";//note\n").0
        check("js string literal preserved", jsStr.contains("a;b{c}"))
        check("js comment preserved", jsStr.contains("//note"))

        // Idempotency (double format == single format).
        expectIdempotent("javascript", "const a={x:1,y:2};if(a.x){f()}")
        expectIdempotent("typescript", "type T={a:number};const g=(t:T)=>t.a")
        expectIdempotent("html", "<div><p>Hi</p></div>")
        expectIdempotent("css", ".a{margin:0;color:red}")
        expectIdempotent("java", "class A{int x=1;void f(){if(x>0){x++;}}}")
        expectIdempotent("sql", "select * from users where id=1")

        // Indent contract: {indent} is a literal string ("  " / "    " / TAB).
        let i2 = run(language: "javascript", indent: "  ",
                     source: "const a={xxxxxxxxxxxxxxxxxx:1,yyyyyyyyyyyyyyyyyy:2,zzzzzzzzzzzzzzzzzz:3,wwwwwwwwwwwwwwwwww:4};").0
        let i4 = run(language: "javascript", indent: "    ",
                     source: "const a={xxxxxxxxxxxxxxxxxx:1,yyyyyyyyyyyyyyyyyy:2,zzzzzzzzzzzzzzzzzz:3,wwwwwwwwwwwwwwwwww:4};").0
        let iTab = run(language: "javascript", indent: "\t",
                     source: "const a={xxxxxxxxxxxxxxxxxx:1,yyyyyyyyyyyyyyyyyy:2,zzzzzzzzzzzzzzzzzz:3,wwwwwwwwwwwwwwwwww:4};").0
        check("js indent 2 vs 4 differ", i2 != i4)
        check("js indent 2 has 2-space lead", i2.contains("  xxxxxxxxxxxxxxxxxx: 1"))
        check("js indent 4 has 4-space lead", i4.contains("    xxxxxxxxxxxxxxxxxx: 1"))
        check("js indent TAB has tab lead", iTab.contains("\txxxxxxxxxxxxxxxxxx: 1"))

        // Error samples: non-zero exit, empty stdout, diagnostic on stderr.
        expectReject("javascript", "const a={x:1")
        expectReject("typescript", "const n:number=")
        expectReject("html", "<div></span></div>")
        expectReject("css", ".a{color:red")
        expectReject("java", "class A{void f( { }")
        expectReject("sql", "SELECT FROM WHERE (;")

        print("")
        print("WebFormatterTests: passed=\(passed) failed=\(failures)")
        if failures > 0 { exit(1) }
    }
}
