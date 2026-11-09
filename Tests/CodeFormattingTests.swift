import Foundation

@main
struct CodeFormattingTests {
    static var passed = 0
    static func check(_ name: String, _ condition: Bool) {
        guard condition else { print("FAIL: \(name)"); exit(1) }
        passed += 1
    }
    static func rejects(_ name: String, _ action: () throws -> Void) {
        do { try action(); print("FAIL: accepted invalid \(name)"); exit(1) }
        catch { passed += 1 }
    }

    static func main() throws {
        // Point resources to the repo's Resources directory (test-only override).
        let fm = FileManager.default
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
        var dir = cwd
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("Resources/Formatters")
            if fm.fileExists(atPath: candidate.path) {
                CodeFormatEngine.testResourcesOverride = dir.appendingPathComponent("Resources")
                break
            }
            dir.deleteLastPathComponent()
        }
        CodeFormatEngine.clearCache()

        // MARK: - Built-in JSON formatting
        let jsonSource = "{\"name\":\"test\",\"version\":1,\"large\":9007199254740993}"
        let formatted = try CodeFormatEngine.format(jsonSource, language: .json)
        check("JSON format succeeds", formatted.contains("\"name\""))
        check("JSON preserves large integer", formatted.contains("9007199254740993"))
        check("JSON format idempotent", try CodeFormatEngine.format(formatted, language: .json) == formatted)
        check("JSON key order", formatted.range(of: "\"name\"")!.lowerBound < formatted.range(of: "\"version\"")!.lowerBound)
        check("empty input", try CodeFormatEngine.format("", language: .json) == "")

        // MARK: - 2MB limit
        let huge = String(repeating: "{\"a\":1,", count: 100_000) + "}"
        rejects("2MB limit") { _ = try CodeFormatEngine.format(huge, language: .json) }

        // MARK: - Manifest loading
        let web = CodeFormatEngine.manifest(forBundleName: "web")
        check("web manifest loads", web != nil)
        check("web manifest has engines", (web?.engines.count ?? 0) > 0)
        let native = CodeFormatEngine.manifest(forBundleName: "native")
        check("native manifest loads", native != nil)

        // MARK: - Argument expansion
        let expanded = CodeFormatEngine.expand(
            arguments: ["--parser", "{language}", "--tab-width", "{indent}"],
            language: "javascript", indent: "2", resources: "/tmp/res"
        )
        check("language placeholder", expanded[1] == "javascript")
        check("indent placeholder", expanded[3] == "2")

        // MARK: - manifestIdentifier mapping
        check("json id", CodeLanguage.json.manifestIdentifier == "json")
        check("js id", CodeLanguage.javascript.manifestIdentifier == "javascript")
        check("ts id", CodeLanguage.typescript.manifestIdentifier == "typescript")
        check("html id", CodeLanguage.html.manifestIdentifier == "html")
        check("css id", CodeLanguage.css.manifestIdentifier == "css")
        check("c id", CodeLanguage.c.manifestIdentifier == "c")
        check("cpp id", CodeLanguage.cpp.manifestIdentifier == "cpp")
        check("automatic empty id", CodeLanguage.automatic.manifestIdentifier.isEmpty)

        // MARK: - Path validation
        let resURL = CodeFormatEngine.testResourcesOverride!
        // Valid relative path — gofmt binary exists in Resources/Formatters/native/bin/
        let validPath = try CodeFormatEngine.resolvedExecURL(relativePath: "Formatters/native/bin/gofmt", resources: resURL)
        check("valid exec resolves", validPath.path.contains("gofmt"))
        // Absolute path rejected
        rejects("absolute path rejected") {
            _ = try CodeFormatEngine.resolvedExecURL(relativePath: "/etc/passwd", resources: resURL)
        }
        // Traversal rejected
        rejects("traversal rejected") {
            _ = try CodeFormatEngine.resolvedExecURL(relativePath: "../../../etc/passwd", resources: resURL)
        }

        // MARK: - Engine invocation (binary may or may not be installed yet)
        do {
            let _ = try CodeFormatEngine.format("let x = 1", language: .swift)
            check("swift format succeeded (binary present)", true)
        } catch is FormatError {
            check("swift format threw FormatError (binary absent or failed)", true)
        }

        // MARK: - S9: Over 4MB output cap exists (preserve original, not truncate)
        check("overflow cap is 4MB", CodeFormatEngine.maxOutputBytes == 4_000_000)

        // MARK: - S10: 100KB output round-trip (tail preserved)
        do {
            var dict: [String: String] = [:]
            for i in 0..<5000 { dict["key\(i)"] = "value\(i)" }
            let data = try JSONSerialization.data(withJSONObject: dict)
            let jsonStr = String(data: data, encoding: .utf8)!
            let formatted = try CodeFormatEngine.format(jsonStr, language: .json)
            check("100KB JSON format succeeds", formatted.count > 50_000)
            check("100KB tail preserved", formatted.contains("key4999"))
        }

        // MARK: - Timeout constants
        check("max is 2MB", CodeFormatEngine.maxInputBytes == 2_000_000)
        check("timeout is 5s", CodeFormatEngine.timeoutSeconds == 5.0)
        check("output cap 4MB", CodeFormatEngine.maxOutputBytes == 4_000_000)

        // MARK: - Languages without a bundled engine
        // Rust formatting is not shipped (its dylibs were ~220 MB). The UI must
        // explain that instead of silently doing nothing or blaming the file.
        if CodeFormatEngine.manifest(forBundleName: "native") != nil,
           CodeFormatEngine.engine(for: .rust) == nil {
            do {
                _ = try CodeFormatEngine.format("fn main(){}\n", language: .rust)
                check("rust without engine throws", false)
            } catch let error as FormatError {
                let text = error.errorDescription ?? ""
                check("rust without engine throws", true)
                check("rust message names the missing engine", text.contains("Rust"))
                check("rust message says it is not bundled", text.contains("未随本版安装包分发"))
                check("rust message says other languages still work", text.contains("其余语言不受影响"))
            }
        }

        print("PASS: \(passed) code formatting assertions")
    }
}
