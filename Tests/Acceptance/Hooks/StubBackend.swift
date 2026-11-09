import Foundation

/// Backend bound to the *current* Sources. It uses the new
/// `SyntaxLexer.detect()` (which already returns a numeric confidence) and
/// the built-in JSON path. Other languages are routed through
/// `CodeFormatEngine.format(_:language:)` so that once the bundled
/// formatter executables land, the stub automatically exercises them.
enum StubBackend: FormatBackend {
    static var backendName: String { "stub.v1 (SyntaxLexer.detect + CodeFormatEngine routing)" }

    static func detect(_ text: String) -> (languageID: String, confidence: Double, rule: String) {
        let result = SyntaxLexer.detect(text)
        return (result.language.manifestIdentifier.isEmpty ? "plain" : result.language.manifestIdentifier,
                result.confidence,
                "score-based")
    }

    static func format(_ text: String, languageID: String) throws -> String? {
        // Normalize short manifest ids (js/ts) to engine ids (javascript/typescript).
        let n: String
        switch languageID.lowercased() {
        case "js":  n = "javascript"
        case "ts":  n = "typescript"
        default:    n = languageID.lowercased()
        }
        let langID: CodeLanguage
        switch n {
        case "json":     langID = .json
        case "javascript": langID = .javascript
        case "typescript": langID = .typescript
        case "html":     langID = .html
        case "css":      langID = .css
        case "python":   langID = .python
        case "go":       langID = .go
        case "swift":    langID = .swift
        case "java":     langID = .java
        case "c":        langID = .c
        case "cpp":      langID = .cpp
        case "sql":      langID = .sql
        case "shell":    langID = .shell
        case "rust":     langID = .rust
        default:         return nil
        }
        do {
            return try CodeFormatEngine.format(text, language: langID, indent: "  ")
        } catch let e as FormatError {
            // `noEngineAvailable` → no bundled binary yet. We surface nil so
            // the runner records a coverage gap rather than a hard failure.
            if case .noEngineAvailable = e { return nil }
            if case .engineNotFound = e { return nil }
            throw e
        }
    }
}
