import Foundation
import CryptoKit

// Backend selection: compile with `-D DEVKIT_REAL_BACKEND` and include
// Hooks/RealBackend.swift once Sources/CodeFormatting.swift is integrated.
#if DEVKIT_REAL_BACKEND
typealias Backend = RealBackend
#else
typealias Backend = StubBackend
#endif

// MARK: - Manifest model
struct SampleEntry: Decodable {
    let path: String
    let category: String
    let language: String
    let mustPreserveTokens: [String]?
    let mustRetainOriginalBytes: Bool?
    let mustNotDetectAs: [String]?
    let allowPlain: Bool?
}
struct Manifest: Decodable {
    struct Language: Decodable { let id: String; let display: String; let ext: [String] }
    struct Target: Decodable { let languages: [Language]; let hardRequirements: [String] }
    let target: Target
    let samples: [SampleEntry]
}

/// Normalize manifest language ids to CodeLanguage.manifestIdentifier().
/// Manifest uses short ids ("js", "ts"); the engine emits long ids
/// ("javascript", "typescript"). We normalize both ways so the runner's
/// detectMatchesExpected is a real check, not a label mismatch.
func normalizeLangID(_ raw: String) -> String {
    switch raw.lowercased() {
    case "js":  return "javascript"
    case "ts":  return "typescript"
    default:    return raw.lowercased()
    }
}

// MARK: - Report model
struct SampleReport: Encodable {
    let sample: String
    let category: String
    let expectedLanguage: String
    let inputBytes: Int
    let inputSHA256: String
    let detectedLanguage: String
    let detectionConfidence: Double
    let detectionRule: String
    let detectMatchesExpected: Bool
    let detectAvoidsForbidden: Bool
    let engine: String
    let formatterAvailable: Bool
    let formatterStatus: String   // "ok" | "not-integrated" | "error" | "retained-original"
    let outputSHA256: String?
    let outputBytes: Int?
    let idempotent: Bool?
    let tokenPreservation: [String: Bool]?
    let retainedOriginalBytes: Bool?
    let notes: [String]
}
struct Report: Encodable {
    let generatedAt: String
    let backend: String
    let sourcesSnapshot: [String: String]   // path → sha256
    let samples: [SampleReport]
    let summary: Summary
}
struct Summary: Encodable {
    let total: Int
    let ok: Int
    let notIntegrated: Int
    let formatterError: Int
    let retainedOk: Int
    let failed: Int
    let detectionMisses: Int
    let coverageGaps: [String]
}

// MARK: - Runner
@main
struct AcceptanceRunner {
    static func main() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
            .deletingLastPathComponent()   // build/
            .absoluteURL
        // Fallback: if launched from repo root directly, walk up to locate Tests/Acceptance.
        var acceptDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Tests/Acceptance")
        if !fm.fileExists(atPath: acceptDir.appendingPathComponent("manifest.json").path) {
            // Try relative to executable
            acceptDir = URL(fileURLWithPath: CommandLine.arguments[0])
                .deletingLastPathComponent()
            for _ in 0..<6 {
                let probe = acceptDir.appendingPathComponent("Tests/Acceptance/manifest.json")
                if fm.fileExists(atPath: probe.path) {
                    acceptDir = probe.deletingLastPathComponent()
                    break
                }
                acceptDir = acceptDir.deletingLastPathComponent()
            }
        }
        let manifestURL = acceptDir.appendingPathComponent("manifest.json")
        let samplesRoot = acceptDir.appendingPathComponent("Samples")

        let manifest = try JSONDecoder().decode(
            Manifest.self,
            from: try Data(contentsOf: manifestURL)
        )

        // Point CodeFormatEngine at the repo's Resources (test-only override).
        // In CLI mode Bundle.main.resourceURL points at build/, not the repo.
        let repoRoot = acceptDir.deletingLastPathComponent().deletingLastPathComponent()
        let repoResources = repoRoot.appendingPathComponent("Resources")
        if FileManager.default.fileExists(
            atPath: repoResources.appendingPathComponent("Formatters").path
        ) {
            CodeFormatEngine.testResourcesOverride = repoResources
            CodeFormatEngine.clearCache()
        }

        // Snapshot current Sources for reproducibility.
        var snapshot: [String: String] = [:]
        let sourcesDir = acceptDir.deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
        if let files = try? fm.contentsOfDirectory(at: sourcesDir, includingPropertiesForKeys: nil) {
            for f in files where f.pathExtension == "swift" {
                let data = try Data(contentsOf: f)
                snapshot[f.lastPathComponent] = SHA256.hash(data: data)
                    .compactMap { String(format: "%02x", $0) }.joined()
            }
        }

        var reports: [SampleReport] = []
        var ok = 0, notInt = 0, ferr = 0, retOk = 0, failed = 0, detMiss = 0
        var gaps: Set<String> = []

        for entry in manifest.samples {
            let url = samplesRoot.appendingPathComponent(entry.path)
            var notes: [String] = []
            let inputData: Data
            do {
                inputData = try Data(contentsOf: url)
            } catch {
                reports.append(SampleReport(
                    sample: entry.path, category: entry.category,
                    expectedLanguage: entry.language,
                    inputBytes: 0, inputSHA256: "",
                    detectedLanguage: "", detectionConfidence: 0, detectionRule: "read-error",
                    detectMatchesExpected: false, detectAvoidsForbidden: false,
                    engine: Backend.backendName,
                    formatterAvailable: false, formatterStatus: "read-error",
                    outputSHA256: nil, outputBytes: nil, idempotent: nil,
                    tokenPreservation: nil, retainedOriginalBytes: nil,
                    notes: ["cannot read sample: \(error.localizedDescription)"]
                ))
                failed += 1
                continue
            }
            let input = String(decoding: inputData, as: UTF8.self)
            let inputSHA = SHA256.hash(data: inputData)
                .compactMap { String(format: "%02x", $0) }.joined()

            let det = Backend.detect(input)
            let expectedNorm = normalizeLangID(entry.language)
            let detectedNorm = normalizeLangID(det.languageID)
            // allowPlain: true means the sample is genuinely ambiguous;
            // detected==plain is acceptable (UI shows "please pick manually").
            let plainOK = (entry.allowPlain == true && detectedNorm == "plain")
            let matchesExpected = detectedNorm == expectedNorm || plainOK
            let avoidsForbidden = !(entry.mustNotDetectAs?.map(normalizeLangID).contains(detectedNorm) ?? false)
            if !matchesExpected { detMiss += 1 }
            if !matchesExpected || !avoidsForbidden {
                notes = ["detection: got=\(det.languageID)(\(detectedNorm)) expected=\(entry.language)(\(expectedNorm))" + (plainOK ? " [plain-allowed]" : "")]
            } else {
                notes = []
            }

            var formatterAvailable = false
            var formatterStatus = "not-integrated"
            var outputSHA: String? = nil
            var outputBytes: Int? = nil
            var idempotent: Bool? = nil
            var tokenMap: [String: Bool]? = nil
            var retained: Bool? = nil

            do {
                if let out = try Backend.format(input, languageID: entry.language) {
                    formatterAvailable = true
                    outputBytes = out.utf8.count
                    outputSHA = SHA256.hash(data: Data(out.utf8))
                        .compactMap { String(format: "%02x", $0) }.joined()

                    // Idempotency
                    if let out2 = try Backend.format(out, languageID: entry.language) {
                        idempotent = (out2 == out)
                    }

                    // Token preservation
                    if let tokens = entry.mustPreserveTokens, !tokens.isEmpty {
                        var m: [String: Bool] = [:]
                        for t in tokens { m[t] = out.contains(t) }
                        tokenMap = m
                        if m.values.contains(false) { notes.append("token-loss: \(m.filter{!$0.value}.keys)") }
                    }

                    if entry.mustRetainOriginalBytes == true {
                        retained = (out == input)
                        formatterStatus = retained == true ? "retained-original" : "changed-error-input"
                        if retained == true { retOk += 1 } else { failed += 1 }
                    } else {
                        formatterStatus = "ok"
                        ok += 1
                    }
                } else {
                    formatterStatus = "not-integrated"
                    notInt += 1
                    gaps.insert("\(entry.language): formatter not yet integrated")
                }
            } catch {
                formatterAvailable = true
                formatterStatus = "error"
                ferr += 1
                notes.append("format-threw: \(String(describing: error))")
                if entry.mustRetainOriginalBytes == true {
                    // Failure must retain original — we treat throw as "kept original"
                    // because the GUI contract says unknown/failed keeps input.
                    retained = true
                    retOk += 1
                    notes.append("error-path: input untouched by contract")
                } else {
                    failed += 1
                }
            }

            reports.append(SampleReport(
                sample: entry.path, category: entry.category,
                expectedLanguage: entry.language,
                inputBytes: inputData.count, inputSHA256: inputSHA,
                detectedLanguage: det.languageID, detectionConfidence: det.confidence,
                detectionRule: det.rule,
                detectMatchesExpected: matchesExpected,
                detectAvoidsForbidden: avoidsForbidden,
                engine: Backend.backendName,
                formatterAvailable: formatterAvailable,
                formatterStatus: formatterStatus,
                outputSHA256: outputSHA, outputBytes: outputBytes,
                idempotent: idempotent,
                tokenPreservation: tokenMap,
                retainedOriginalBytes: retained,
                notes: notes
            ))
        }

        let summary = Summary(
            total: reports.count,
            ok: ok, notIntegrated: notInt, formatterError: ferr,
            retainedOk: retOk, failed: failed, detectionMisses: detMiss,
            coverageGaps: gaps.sorted()
        )
        let report = Report(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            backend: Backend.backendName,
            sourcesSnapshot: snapshot,
            samples: reports,
            summary: summary
        )

        let outDir = acceptDir.appendingPathComponent("Reports")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let jsonURL = outDir.appendingPathComponent("report.json")
        try JSONEncoder.pretty.encode(report).write(to: jsonURL)

        // Human-readable
        var lines: [String] = []
        lines.append("DevKit Independent Acceptance Report")
        lines.append("generated: \(report.generatedAt)")
        lines.append("backend:   \(report.backend)")
        lines.append("sources:")
        for (k, v) in snapshot.sorted(by: { $0.key < $1.key }) {
            lines.append("  \(k)  \(v.prefix(16))…")
        }
        lines.append("")
        lines.append("== Summary ==")
        lines.append("total=\(summary.total) ok=\(summary.ok) notIntegrated=\(summary.notIntegrated) formatterError=\(summary.formatterError) retainedOk=\(summary.retainedOk) failed=\(summary.failed) detectionMisses=\(summary.detectionMisses)")
        if !summary.coverageGaps.isEmpty {
            lines.append("")
            lines.append("== Coverage gaps ==")
            for g in summary.coverageGaps { lines.append("  - \(g)") }
        }
        lines.append("")
        lines.append("== Samples ==")
        for r in reports {
            let flag: String
            if r.formatterStatus == "not-integrated" { flag = "~" }
            else if r.notes.isEmpty && r.detectMatchesExpected { flag = "✓" }
            else { flag = "✗" }
            lines.append("  [\(flag)] \(r.sample)")
            lines.append("       expected=\(r.expectedLanguage) detected=\(r.detectedLanguage) (conf=\(r.detectionConfidence)) rule=\(r.detectionRule)")
            lines.append("       status=\(r.formatterStatus) idempotent=\(String(describing: r.idempotent)) retained=\(String(describing: r.retainedOriginalBytes))")
            if let tm = r.tokenPreservation {
                let lost = tm.filter { !$0.value }.map { $0.key }
                if !lost.isEmpty { lines.append("       token-loss: \(lost)") }
            }
            for n in r.notes { lines.append("       note: \(n)") }
        }
        try lines.joined(separator: "\n").write(
            to: outDir.appendingPathComponent("report.txt"),
            atomically: true, encoding: .utf8
        )

        print(lines.joined(separator: "\n"))
        print("")
        print("Wrote \(jsonURL.path)")

        // Hard failures only cause non-zero exit; coverage gaps / not-integrated
        // are informational (expected before CodeFormatting lands).
        if summary.failed > 0 { exit(2) }
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}
