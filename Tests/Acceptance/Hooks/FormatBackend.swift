import Foundation

/// Independent-acceptance backend protocol.
///
/// Two implementations ship alongside the runner:
///   * `StubBackend.swift` — works against the *current* Sources (SyntaxCore + ToolCore).
///     It can detect via the existing heuristic lexer and format JSON strictly.
///     For every other language it returns nil (formatter not integrated yet).
///   * `RealBackend.swift.tmpl` — a template to be filled in once
///     `Sources/CodeFormatting.swift` lands. The runner itself never references
///     CodeFormatting symbols, so this file compiles cleanly in both phases.
protocol FormatBackend {
    /// Stable name shown in the report, e.g. "stub.v1" or "codeformat.v1".
    static var backendName: String { get }

    /// Returns (languageID in manifest.target.languages, confidence 0..1, engine rule used).
    /// Must never throw; on ambiguity it picks the best guess and the runner
    /// records the gap rather than asserting a pass.
    static func detect(_ text: String) -> (languageID: String, confidence: Double, rule: String)

    /// Format `text` for the given manifest languageID.
    /// Returns nil when this backend has no formatter for that language
    /// (e.g. before CodeFormatting.swift is integrated). Throws only on a real
    /// formatting error (the runner then classifies it as a retained-error case).
    static func format(_ text: String, languageID: String) throws -> String?
}

/// Mapping table: SyntaxCore's current CodeLanguage → manifest language id.
/// Used by both StubBackend and (as a reference) RealBackend.
enum DetectionMap {
    static func id(for raw: String) -> (id: String, rule: String, separable: Bool) {
        switch raw {
        case "Swift":                       return ("swift",    "swift-keyword",          true)
        case "JavaScript / TypeScript":       return ("js",        "js-heuristic",            false) // ts not separable today
        case "Python":                      return ("python",   "python-re-shebang",       true)
        case "Go":                          return ("go",        "go-func-package",         true)
        case "Rust":                        return ("rust",      "rust-fn-use",            true)
        case "Java / C / C++":              return ("java",      "java-include-std",        false) // c/cpp not separable today
        case "SQL":                         return ("sql",        "sql-re",                  true)
        case "Shell":                       return ("shell",     "shell-shebang-export",    true)
        case "JSON":                        return ("json",       "json-brace-quote",        true)
        default:                            return ("plain",     "fallback",                true)
        }
    }
}
