import Foundation

@main
struct DetectionTests {
    static var passed = 0
    static func check(_ name: String, _ condition: Bool) {
        guard condition else { print("FAIL: \(name)"); exit(1) }
        passed += 1
    }

    static func main() {
        // MARK: - JSON detection
        let json = "{\"name\":\"test\",\"value\":42}"
        let r1 = SyntaxLexer.detect(json)
        check("JSON detected", r1.language == .json)
        check("JSON high confidence", r1.confidence >= 0.7)

        let jsonArr = "[{\"a\":1},{\"b\":2}]"
        check("JSON array detected", SyntaxLexer.detect(jsonArr).language == .json)

        // MARK: - Python detection
        let python = "def hello():\n    print(\"world\")\n"
        check("Python detected", SyntaxLexer.detect(python).language == .python)

        let pythonShebang = "#!/usr/bin/env python3\nprint('hi')"
        check("Python shebang detected", SyntaxLexer.detect(pythonShebang).language == .python)

        // MARK: - SQL detection
        let sql = "SELECT name, age FROM users WHERE id = 1"
        let r2 = SyntaxLexer.detect(sql)
        check("SQL detected", r2.language == .sql)
        check("SQL high confidence", r2.confidence >= 0.7)

        // MARK: - Go detection
        let go = "package main\n\nimport \"fmt\"\n\nfunc main() {\n    fmt.Println(\"hi\")\n}\n"
        check("Go detected", SyntaxLexer.detect(go).language == .go)

        // MARK: - Rust detection
        let rust = "pub fn main() {\n    println!(\"hi\");\n}\n"
        check("Rust detected", SyntaxLexer.detect(rust).language == .rust)

        // MARK: - Swift detection
        let swift = "import SwiftUI\n\nstruct ContentView: View {\n    var body: some View {\n        Text(\"Hello\")\n    }\n}\n"
        check("Swift detected", SyntaxLexer.detect(swift).language == .swift)

        // MARK: - Shell detection
        let shell = "#!/bin/bash\nexport PATH=\"/usr/bin\"\necho \"hello\"\n"
        check("Shell detected", SyntaxLexer.detect(shell).language == .shell)

        // MARK: - HTML detection
        let html = "<!DOCTYPE html>\n<html>\n<head><title>Test</title></head>\n<body><p>Hi</p></body>\n</html>\n"
        let r3 = SyntaxLexer.detect(html)
        check("HTML detected", r3.language == .html)
        check("HTML high confidence", r3.confidence >= 0.7)

        // MARK: - CSS detection
        let css = ".container {\n    display: flex;\n    color: #333;\n    margin: 0 auto;\n}\n"
        check("CSS detected", SyntaxLexer.detect(css).language == .css)

        // MARK: - TypeScript detection
        let ts = "interface User {\n    name: string;\n    age: number;\n}\n\nconst u: User = { name: \"a\", age: 1 };\n"
        let r4 = SyntaxLexer.detect(ts)
        check("TypeScript detected", r4.language == .typescript)

        // MARK: - JavaScript detection
        let js = "const x = 42;\nfunction greet(name) {\n    return `Hello ${name}`;\n}\nconsole.log(greet(\"world\"));\n"
        let r5 = SyntaxLexer.detect(js)
        check("JavaScript detected", r5.language == .javascript)

        // MARK: - Java detection
        let java = "public class Hello {\n    public static void main(String[] args) {\n        System.out.println(\"Hi\");\n    }\n}\n"
        check("Java detected", SyntaxLexer.detect(java).language == .java)

        // MARK: - C/C++ detection
        let cpp = "#include <iostream>\nusing namespace std;\n\nint main() {\n    cout << \"Hello\" << endl;\n    return 0;\n}\n"
        let r6 = SyntaxLexer.detect(cpp)
        check("C/C++ detected", r6.language == .cpp || r6.language == .c)

        // MARK: - Unknown / low confidence
        let empty = SyntaxLexer.detect("")
        check("empty is unknown", empty.language == .plain)
        check("empty confidence 0", empty.confidence == 0)

        let gibberish = "x\nx\nx\nx\nx\n"
        let r7 = SyntaxLexer.detect(gibberish)
        check("gibberish is low confidence or plain", r7.confidence < 0.5)

        // MARK: - resolved() backwards compatibility
        check("resolved auto JSON", SyntaxLexer.resolved(.automatic, text: json) == .json)
        check("resolved auto Python", SyntaxLexer.resolved(.automatic, text: python) == .python)
        check("resolved auto SQL", SyntaxLexer.resolved(.automatic, text: sql) == .sql)
        check("resolved explicit", SyntaxLexer.resolved(.swift, text: "random text") == .swift)

        // MARK: - Detection is synchronous and bounded
        let largeText = String(repeating: "const x = 1; // comment\n", count: 10_000)
        let start = Date()
        _ = SyntaxLexer.detect(largeText)
        check("large detection fast", Date().timeIntervalSince(start) < 1.0)

        // MARK: - Lexer bounds safety for new languages
        for lang: CodeLanguage in [.html, .css, .typescript, .c, .cpp] {
            let tokens = SyntaxLexer.spans("<div class=\"test\">/* comment */</div>", language: lang)
            check("bounded tokens \(lang)", tokens.allSatisfy {
                $0.range.location >= 0 && $0.range.length > 0 && NSMaxRange($0.range) <= 100
            })
        }

        // HTML comment lexing
        let htmlComment = "<!-- comment -->\n<div>text</div>"
        let htmlTokens = SyntaxLexer.spans(htmlComment, language: .html)
        check("HTML comment exists", htmlTokens.contains { $0.kind == .comment })

        // CSS comment lexing
        let cssComment = "/* comment */\nbody { margin: 0; }"
        let cssTokens = SyntaxLexer.spans(cssComment, language: .css)
        check("CSS comment exists", cssTokens.contains { $0.kind == .comment })

        print("PASS: \(passed) detection assertions")
    }
}
