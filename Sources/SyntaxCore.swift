import Foundation

enum CodeLanguage: String, CaseIterable, Identifiable, Sendable {
    case automatic = "自动"
    case json = "JSON"
    case javascript = "JavaScript"
    case typescript = "TypeScript"
    case html = "HTML"
    case css = "CSS"
    case python = "Python"
    case go = "Go"
    case rust = "Rust"
    case swift = "Swift"
    case java = "Java"
    case c = "C"
    case cpp = "C++"
    case sql = "SQL"
    case shell = "Shell"
    case plain = "纯文本"
    var id: String { rawValue }

    /// Lower-case identifier used in manifest.json engines entries.
    var manifestIdentifier: String {
        switch self {
        case .automatic, .plain: return ""
        case .json: return "json"
        case .javascript: return "javascript"
        case .typescript: return "typescript"
        case .html: return "html"
        case .css: return "css"
        case .python: return "python"
        case .go: return "go"
        case .rust: return "rust"
        case .swift: return "swift"
        case .java: return "java"
        case .c: return "c"
        case .cpp: return "cpp"
        case .sql: return "sql"
        case .shell: return "shell"
        }
    }
}

enum SyntaxKind: String, Sendable { case keyword, string, comment, number, literal, type, function, key }
struct SyntaxSpan: Sendable, Equatable {
    let range: NSRange
    let kind: SyntaxKind
}

/// Result of language auto-detection with confidence for formatting decisions.
struct DetectionResult: Sendable, Equatable {
    let language: CodeLanguage
    let confidence: Double  // 0.0 – 1.0; ≥0.7 is high-confidence for auto-format
    static let unknown = DetectionResult(language: .plain, confidence: 0)
}

/// Lightweight display lexer. It never parses or executes user code, or rewrites input.
/// Ranges are UTF-16 offsets, matching NSTextStorage exactly (including emoji).
enum SyntaxLexer {
    static let commonKeywords = Set("if else for while do return break continue switch case default try catch throw throws async await import export from as class struct enum protocol extension public private internal static final let var const func function new in guard defer init self super override yield with end then fi done esac select package interface go chan range map type mut pub impl fn use mod crate match loop trait where unsafe extern move ref dyn pass def elif lambda except finally raise global nonlocal assert del not and or is begin rescue ensure unless module require include typedef sizeof namespace using virtual template auto void volatile union protected synchronized extends implements instanceof this delete actor some any open operator fallthrough repeat get set willSet didSet associatedtype inout nonisolated readonly declare keyof infer satisfies interface readonly abstract native goto volatile register extern threadstrict signed unsigned short long char float double boolean".split(separator:" ").map(String.init))
    static let builtinTypes = Set("String Int Int8 Int16 Int32 Int64 UInt UInt8 UInt16 UInt32 UInt64 Double Float Bool Character Array Dictionary Set Optional Date Data URL Any Object Number Boolean Promise Map Vec Option Result Self str i8 i16 i32 i64 u8 u16 u32 u64 f32 f64 usize isize bool int long short float double boolean char string byte error null nil None True False true false undefined NULL TRUE FALSE void size_t uint8_t int32_t uint32_t int64_t uint64_t".split(separator:" ").map(String.init))
    static let literals = Set(["true","false","nil","null","undefined","None","True","False","NULL","TRUE","FALSE"])
    static let sqlKeywords = Set("SELECT FROM WHERE JOIN INNER LEFT RIGHT FULL OUTER ON AS AND OR NOT NULL IS IN EXISTS BETWEEN LIKE ORDER BY GROUP HAVING LIMIT OFFSET INSERT INTO VALUES UPDATE SET DELETE CREATE ALTER DROP TABLE INDEX VIEW DISTINCT UNION ALL WITH CASE WHEN THEN ELSE END ASC DESC COUNT SUM AVG MIN MAX OVER PARTITION ROW_NUMBER CAST COALESCE DATABASE IF PRIMARY KEY FOREIGN REFERENCES DEFAULT RETURNING".split(separator:" ").map(String.init))
    static let tsKeywords = Set(["interface","implements","enum","namespace","declare","readonly","abstract","private","protected","public","keyof","infer","satisfies","type","extends","implements","override","readonly"])
    static let cPreprocessor = Set(["#include","#define","#ifdef","#ifndef","#endif","#if","#else","#elif","#pragma","#undef","#error","#warning","#import"])

    /// High-confidence detection with a numeric score.
    static func detect(_ text: String) -> DetectionResult {
        let sample = String(text.prefix(8192))
        let trim = sample.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trim.isEmpty else { return .unknown }

        var scores: [CodeLanguage: Double] = [:]

        // Shebang — very high confidence.
        if trim.hasPrefix("#!") {
            if sample.contains("python") { scores[.python] = 0.95 }
            else if sample.contains("node") || sample.contains("js") { scores[.javascript] = 0.9 }
            else { scores[.shell] = 0.95 }
        }

        // JSON — strict validation: try parsing the entire text as JSON.
        // Only objects/arrays get high confidence; bare scalars (numbers, booleans)
        // get medium confidence. Bare quoted strings are NOT detected as JSON
        // to avoid false-positives on plain text.
        if let data = trim.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            if obj is [String: Any] || obj is [Any] {
                scores[.json] = 0.85
            } else if !(obj is String) {
                scores[.json] = 0.55
            }
        } else if (trim.hasPrefix("{") && trim.hasSuffix("}")) ||
                  (trim.hasPrefix("[") && trim.hasSuffix("]")) {
            // Malformed JSON (trailing comma, overflow, etc.) — looks like JSON.
            // Medium confidence: formatter will try and report the actual error.
            scores[.json] = 0.5
        }

        // HTML — strong signals: doctype/root tag, or multiple tag pairs.
        if trim.hasPrefix("<!DOCTYPE") || trim.hasPrefix("<html") || trim.hasPrefix("<?xml") {
            scores[.html] = 0.95
        }
        // Any HTML tag pair (<div>, <script>, <style>, <body>, etc.) indicates HTML.
        if sample.range(of: #"</?(html|head|body|div|span|p|script|style|pre|textarea|table|ul|ol|li|h[1-6]|a|img|form|button|nav|header|footer|main|section|article)"#, options: [.regularExpression, .caseInsensitive]) != nil {
            scores[.html] = scores[.html, default: 0] + 0.55
        }
        if sample.range(of: #"<!--.*?-->"#, options: .regularExpression) != nil {
            scores[.html] = scores[.html, default: 0] + 0.2
        }

        // CSS — at-rules anywhere (not just at start) are strong CSS signals.
        if sample.range(of: #"@(media|keyframes|import|font-face|supports|charset)"#, options: .regularExpression) != nil {
            scores[.css] = scores[.css, default: 0] + 0.45
        }
        // CSS class/id selector: starts with . or #, then { property: value; }
        // Requiring . or # start avoids matching JS/TS/Go object literals.
        if sample.range(of: #"[.#][^{}]*\{[^{}]*:[^{};]*;[^{}]*\}"#, options: .regularExpression) != nil {
            scores[.css] = scores[.css, default: 0] + 0.55
        }
        // Vendor-prefixed properties (-webkit-, -moz-) are CSS-specific.
        if sample.range(of: #"-webkit-|-moz-|-ms-|-o-"#, options: .regularExpression) != nil {
            scores[.css] = scores[.css, default: 0] + 0.2
        }

        // Python — removed @\w+ (it matched CSS @media and Java annotations).
        // class \w+.*: now requires the colon at end of line (Python style).
        if sample.range(of: #"(?m)^\s*(def |from \w+ import |import (?:sys|os|json)|class \w+.*:\s*$|elif |except )"#, options: .regularExpression) != nil {
            scores[.python] = scores[.python, default: 0] + 0.7
        }

        // SQL
        if sample.range(of: #"(?im)^\s*(SELECT\b|WITH\s+\w+\s+AS\b|INSERT INTO\b|CREATE TABLE\b|UPDATE\s+\w+\s+SET\b|DELETE FROM\b)"#, options: .regularExpression) != nil {
            scores[.sql] = 0.85
        }

        // Go
        if sample.contains("package main") || sample.contains("package ") && sample.contains("import (") {
            scores[.go] = scores[.go, default: 0] + 0.5
        }
        if sample.contains(":=") && sample.contains("func ") {
            scores[.go] = scores[.go, default: 0] + 0.3
        }
        // Go struct tags (backtick-annotated fields) and go:generate comments.
        if sample.contains("`json:") || sample.contains("`yaml:") || sample.contains("//go:generate") {
            scores[.go] = scores[.go, default: 0] + 0.2
        }
        // Go type declaration: type X struct { ... } — Go-specific capitalized fields.
        if sample.range(of: #"type\s+\w+\s+struct\s*\{"#, options: .regularExpression) != nil {
            scores[.go] = scores[.go, default: 0] + 0.6
        }
        // Go bare function: func greet(name string) string { — no parameter colons,
        // return type appears before opening brace (vs Swift's ->).
        if sample.range(of: #"func\s+\w+\([^)]*\)\s+(string|int|bool|error|float64|\[\]\w+|\*?\w+)\s*\{"#, options: .regularExpression) != nil {
            scores[.go] = scores[.go, default: 0] + 0.55
        }

        // Rust
        if sample.contains("fn main()") || sample.contains("use std::") || sample.contains("pub fn ") {
            scores[.rust] = 0.8
        }

        // Swift
        if sample.contains("import SwiftUI") {
            scores[.swift] = scores[.swift, default: 0] + 0.5
        }
        // Swift-style function declarations with parameter type annotations.
        if sample.contains("func ") && (sample.contains(": String") || sample.contains(": Int") || sample.contains(": Bool") || sample.contains("-> ")) {
            scores[.swift] = scores[.swift, default: 0] + 0.5
        }
        // Swift raw strings (#"..."#) and build configuration (#if swift) are strong Swift signals.
        if sample.contains("#\"") || sample.contains("#if swift") || sample.contains("#endif") {
            scores[.swift] = scores[.swift, default: 0] + 0.55
        }
        if sample.contains("let ") && sample.contains(": String") && sample.contains("print(") {
            scores[.swift] = scores[.swift, default: 0] + 0.2
        }

        // Shell
        if sample.contains("#!/bin/") || (sample.contains("export ") && sample.contains("$") && sample.contains("echo ")) {
            scores[.shell] = scores[.shell, default: 0] + 0.5
        }
        // Bare echo statement — common shell script idiom.
        if trim.range(of: #"^echo\s+"#, options: .regularExpression) != nil {
            scores[.shell] = scores[.shell, default: 0] + 0.55
        }

        // Java
        if sample.contains("public class ") || sample.contains("public static void main") {
            scores[.java] = scores[.java, default: 0] + 0.55
        }
        if sample.contains("private ") || sample.contains("protected ") || sample.contains("void ") && sample.contains(";") {
            scores[.java] = scores[.java, default: 0] + 0.15
        }

        // C / C++ — distinguish by standard library headers.
        // C standard library headers → strong C signal (match even if unterminated).
        if sample.range(of: #"#include\s*<(stdio|stdlib|string|ctype|math|time)"#, options: .regularExpression) != nil {
            scores[.c] = scores[.c, default: 0] + 0.55
        }
        // C++ standard library headers → strong C++ signal.
        if sample.range(of: #"#include\s*<(iostream|vector|string|map|set|algorithm|memory|fstream|sstream)>"#, options: .regularExpression) != nil {
            scores[.cpp] = scores[.cpp, default: 0] + 0.55
        }
        // Generic #include (neither C nor C++ standard) → weak both.
        if sample.contains("#include <") || sample.contains("#include\"") {
            if scores[.c] == nil && scores[.cpp] == nil {
                scores[.c] = scores[.c, default: 0] + 0.3
                scores[.cpp] = scores[.cpp, default: 0] + 0.2
            }
        }
        if sample.contains("std::") || sample.contains("cout <<") {
            scores[.cpp] = scores[.cpp, default: 0] + 0.35
        }
        // namespace alone is weak C++ (could be in a .c file).
        if sample.contains("namespace ") && sample.contains("std::") {
            scores[.cpp] = scores[.cpp, default: 0] + 0.2
        }
        // C preprocessor macros (#define, #ifdef) are C/C++ but not strongly one or the other.
        if sample.contains("#define ") || sample.contains("#ifdef ") || sample.contains("#ifndef ") {
            if scores[.c] == nil && scores[.cpp] == nil {
                scores[.c] = scores[.c, default: 0] + 0.35
            }
        }

        // TypeScript — raised confidence for interface/type aliases.
        if sample.contains("interface ") {
            scores[.typescript] = scores[.typescript, default: 0] + 0.5
        }
        if sample.range(of: #"type\s+\w+\s*=\s*"#, options: .regularExpression) != nil {
            scores[.typescript] = scores[.typescript, default: 0] + 0.25
        }
        // TS type alias with type annotation fields: { name: string; age: number; }
        if sample.range(of: #"type\s+\w+\s*=\s*\{[^}]*:\s*(string|number|boolean)"#, options: .regularExpression) != nil {
            scores[.typescript] = scores[.typescript, default: 0] + 0.35
        }
        if sample.contains("implements ") || sample.contains("as const") || sample.contains("as ") && sample.contains("undefined") {
            scores[.typescript] = scores[.typescript, default: 0] + 0.2
        }

        // JavaScript — raised baseline; only when TS signals are absent.
        if scores[.typescript] == nil || (scores[.typescript] ?? 0) < 0.6 {
            var jsScore = 0.0
            if sample.contains("function ") || sample.contains("=>") { jsScore += 0.35 }
            if sample.contains("console.log") || sample.contains("console.error") { jsScore += 0.2 }
            if sample.contains("const ") || sample.contains("let ") || sample.contains("var ") { jsScore += 0.15 }
            // JS export class — strong JS/TS module signal.
            if sample.contains("export class ") || sample.contains("export default ") { jsScore += 0.4 }
            // JS decorator @Component({...}) — Angular/TS-style but in .js file.
            if sample.range(of: #"@\w+\(\{"#, options: .regularExpression) != nil { jsScore += 0.2 }
            // JS template literals (`...${...}...`)
            if sample.range(of: #"`[^`]*\$\{"#, options: .regularExpression) != nil { jsScore += 0.15 }
            // JS regex literal /ab+c/
            if sample.range(of: #"=\s*/[^/\n]+/[gimsuy]*\s*[;,\n]"#, options: .regularExpression) != nil { jsScore += 0.1 }
            // Unquoted object literal at start: {key: value} (not valid JSON)
            if trim.range(of: #"^\{\s*\w+\s*:"#, options: .regularExpression) != nil { jsScore += 0.5 }
            // const X = { ... } — common JS config object.
            if sample.range(of: #"const\s+\w+\s*=\s*\{"#, options: .regularExpression) != nil { jsScore += 0.45 }
            if jsScore > 0 { scores[.javascript] = scores[.javascript, default: 0] + jsScore }
        }

        // Pick the highest-scoring language.
        guard let best = scores.max(by: { $0.value < $1.value }) else {
            return .unknown
        }
        let confidence = min(best.value, 1.0)
        // Below 0.5 confidence → treat as unknown/plain; don't auto-format.
        if confidence < 0.5 { return .unknown }
        return DetectionResult(language: best.key, confidence: confidence)
    }

    /// Resolve automatic language to a concrete language. Kept for CoreTests compat.
    static func resolved(_ language: CodeLanguage, text: String) -> CodeLanguage {
        guard language == .automatic else { return language }
        return detect(text).language
    }

    /// Check if a language uses `//` line comments.
    private static func usesLineComment(_ lang: CodeLanguage) -> Bool {
        switch lang {
        case .swift, .javascript, .typescript, .java, .c, .cpp, .go, .rust: return true
        case .json, .html, .css, .python, .shell, .sql, .plain, .automatic: return false
        }
    }
    /// Check if a language uses `/* */` block comments.
    private static func usesBlockComment(_ lang: CodeLanguage) -> Bool {
        switch lang {
        case .swift, .javascript, .typescript, .java, .c, .cpp, .go, .rust, .css: return true
        case .json, .html, .python, .shell, .sql, .plain, .automatic: return false
        }
    }

    static func spans(_ text: String, language requested: CodeLanguage = .automatic) -> [SyntaxSpan] {
        let language = requested == .automatic ? detect(text).language : requested
        guard language != .plain, !text.isEmpty else { return [] }
        let u = Array(text.utf16), n = u.count
        var i = 0, result: [SyntaxSpan] = []
        func append(_ start: Int, _ end: Int, _ kind: SyntaxKind) {
            if end > start { result.append(SyntaxSpan(range: NSRange(location: start, length: end - start), kind: kind)) }
        }
        func has(_ index: Int, _ value: UInt16) -> Bool { index < n && u[index] == value }
        func digit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }
        func alpha(_ c: UInt16) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c == 36 }
        func word(_ c: UInt16) -> Bool { alpha(c) || digit(c) }
        func spaces(_ c: UInt16) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 }

        // HTML-specific state machine
        var inHTMLTag = false  // inside <...>
        var inHTMLComment = false

        while i < n {
            let start = i, c = u[i]

            // HTML comments <!-- ... -->
            if language == .html && !inHTMLComment && c == 60 && has(i+1, 33) && has(i+2, 45) && has(i+3, 45) {
                inHTMLComment = true
                i += 4
                while i < n {
                    if u[i] == 45 && has(i+1, 45) && has(i+2, 62) { i += 3; break }
                    i += 1
                }
                inHTMLComment = false
                append(start, i, .comment)
                continue
            }

            // HTML tag handling
            if language == .html && !inHTMLComment {
                if c == 60 && !inHTMLTag {  // <
                    // Check for </ or <! or <?
                    if has(i+1, 47) || has(i+1, 33) || has(i+1, 63) {
                        i += 2
                        while i < n && u[i] != 62 { i += 1 }
                        if i < n { i += 1 }
                        append(start, i, .keyword)
                        inHTMLTag = false
                        continue
                    }
                    inHTMLTag = true
                    i += 1
                    // Tag name
                    if i < n && (alpha(u[i]) || u[i] == 33 || u[i] == 47) {
                        let nameStart = i
                        while i < n && word(u[i]) { i += 1 }
                        append(nameStart, i, .keyword)
                    }
                    // Attributes inside tag
                    while i < n && u[i] != 62 {
                        let a = u[i]
                        if a == 34 || a == 39 {  // quoted attribute value
                            let q = a
                            i += 1
                            while i < n && u[i] != q { i += 1 }
                            if i < n { i += 1 }
                            append(start, i, .string)
                        } else if alpha(a) {
                            let attrStart = i
                            while i < n && (word(u[i]) || u[i] == 45) { i += 1 }
                            append(attrStart, i, .key)
                        } else {
                            i += 1
                        }
                    }
                    if i < n && u[i] == 62 { i += 1; inHTMLTag = false }
                    continue
                }
                if inHTMLTag {
                    i += 1
                    continue
                }
            }

            // CSS comments /* */ (CSS uses only block comments)
            if language == .css && c == 47 && has(i+1, 42) {
                i += 2
                while i < n {
                    if u[i] == 42 && has(i+1, 47) { i += 2; break }
                    i += 1
                }
                append(start, i, .comment)
                continue
            }

            // Comments take precedence over slash/operator tokens outside strings.
            if language != .json && language != .html {
                // Hash comments: Python, Shell, Java (rarely), C/C++ preprocessor
                if (language == .python || language == .shell) && c == 35 {
                    while i < n && u[i] != 10 && u[i] != 13 { i += 1 }
                    append(start, i, .comment); continue
                }
                // C/C++ preprocessor directives
                if (language == .c || language == .cpp) && c == 35 {
                    while i < n && u[i] != 10 && u[i] != 13 { i += 1 }
                    append(start, i, .keyword); continue
                }
                // SQL -- comments
                if language == .sql && c == 45 && has(i+1, 45) {
                    while i < n && u[i] != 10 && u[i] != 13 { i += 1 }
                    append(start, i, .comment); continue
                }
                // // line comments
                if usesLineComment(language) && c == 47 && has(i+1, 47) {
                    while i < n && u[i] != 10 && u[i] != 13 { i += 1 }
                    append(start, i, .comment); continue
                }
                // /* block comments (non-CSS)
                if usesBlockComment(language) && language != .css && c == 47 && has(i+1, 42) {
                    i += 2; var nesting = 1
                    while i < n && nesting > 0 {
                        if language == .swift && u[i] == 47 && has(i+1, 42) { nesting += 1; i += 2 }
                        else if u[i] == 42 && has(i+1, 47) { nesting -= 1; i += 2 }
                        else { i += 1 }
                    }
                    append(start, i, .comment); continue
                }
            }

            // Quoted strings, escaped quotes, JS templates, Python/Swift triple strings.
            if c == 34 || (language != .json && language != .html && (c == 39 || c == 96)) {
                let triple = (language == .python || language == .swift) && has(i+1, c) && has(i+2, c)
                i += triple ? 3 : 1
                while i < n {
                    if u[i] == 92 && language != .sql { i = min(i+2, n); continue }
                    if triple {
                        if u[i] == c && has(i+1, c) && has(i+2, c) { i += 3; break }
                    } else if u[i] == c {
                        if language == .sql && has(i+1, c) { i += 2; continue }
                        i += 1; break
                    } else if c != 96 && (u[i] == 10 || u[i] == 13) { break }
                    i += 1
                }
                var end = i
                while end < n && spaces(u[end]) { end += 1 }
                append(start, i, language == .json && end < n && u[end] == 58 ? .key : .string)
                continue
            }

            // Numbers
            if digit(c) || (c == 45 && has(i+1, 48) || c == 45 && i+1 < n && digit(u[i+1])) {
                if c == 45 { i += 1 }
                if has(i, 48) && i+1 < n && [UInt16(120),88,98,66,111,79].contains(u[i+1]) {
                    i += 2
                    while i < n && (word(u[i]) || u[i] == 95) { i += 1 }
                } else {
                    while i < n && (digit(u[i]) || u[i] == 95) { i += 1 }
                    if has(i, 46) && i+1 < n && digit(u[i+1]) { i += 1; while i < n && (digit(u[i]) || u[i] == 95) { i += 1 } }
                    if i < n && (u[i] == 101 || u[i] == 69) {
                        var end = i+1
                        if has(end, 43) || has(end, 45) { end += 1 }
                        if end < n && digit(u[end]) { i = end; while i < n && digit(u[i]) { i += 1 } }
                    }
                }
                append(start, i, .number); continue
            }

            // Words / keywords
            if alpha(c) {
                i += 1; while i < n && word(u[i]) { i += 1 }
                let token = String(decoding: u[start..<i], as: UTF16.self)
                var next = i; while next < n && spaces(u[next]) { next += 1 }
                if literals.contains(token) { append(start, i, .literal) }
                else if language == .sql && sqlKeywords.contains(token.uppercased()) { append(start, i, .keyword) }
                else if language != .json && language != .sql && language != .html && commonKeywords.contains(token) { append(start, i, .keyword) }
                else if language != .json && language != .html && builtinTypes.contains(token) { append(start, i, .type) }
                else if language != .json && language != .html && next < n && u[next] == 40 { append(start, i, .function) }
                continue
            }

            i += 1
        }
        return result
    }

    /// Split a full-source scan into per-line spans while retaining multiline token state.
    static func lineSpans(_ text: String, language: CodeLanguage) -> [[SyntaxSpan]] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        guard !normalized.isEmpty else { return [] }
        let tokens = spans(normalized, language: language), lines = normalized.components(separatedBy: "\n")
        var result: [[SyntaxSpan]] = [], start = 0, tokenIndex = 0
        for line in lines {
            let end = start + line.utf16.count
            while tokenIndex < tokens.count && NSMaxRange(tokens[tokenIndex].range) <= start { tokenIndex += 1 }
            var row: [SyntaxSpan] = [], j = tokenIndex
            while j < tokens.count && tokens[j].range.location < end {
                let low = max(start, tokens[j].range.location), high = min(end, NSMaxRange(tokens[j].range))
                if high > low { row.append(SyntaxSpan(range: NSRange(location: low-start, length: high-low), kind: tokens[j].kind)) }
                j += 1
            }
            result.append(row); start = end + 1
        }
        return result
    }
}

struct PreferredWindowSize: Equatable {
    let width: Double
    let height: Double
}
enum WindowSizing {
    static let width: Double = 1440
    static let height: Double = 960
    static func fitted(availableWidth: Double, availableHeight: Double) -> PreferredWindowSize {
        PreferredWindowSize(width: min(width, max(availableWidth-32, 1)), height: min(height, max(availableHeight-32, 1)))
    }
}
