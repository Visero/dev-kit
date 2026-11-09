import Foundation

enum FormatError: LocalizedError, Sendable {
    case tooLarge(Int)
    case timeout
    case engineNotFound(String)
    case engineFailed(String)
    case noEngineAvailable(CodeLanguage)
    case invalidManifest(String)
    case illegalExecutablePath(String)
    var errorDescription: String? {
        switch self {
        case .tooLarge(let b): return "文件大小 \(b) 字节超过 2 MB 限制。"
        case .timeout: return "格式化超时（5 秒），已取消以保护输入。"
        case .engineNotFound(let l): return "未找到 \(l) 的格式化引擎。"
        case .engineFailed(let m): return "格式化失败：\(m)"
        case .noEngineAvailable(let l):
            if l == .rust { return "Rust 格式化引擎未随本版安装包分发，保留原文；其余语言不受影响。" }
            return "\(l.rawValue) 暂无格式化引擎，保留原文。"
        case .invalidManifest(let m): return "格式化配置无效：\(m)"
        case .illegalExecutablePath(let p): return "引擎路径越界：\(p)"
        }
    }
}

struct FormatterEngine: Sendable, Equatable {
    let language: String
    let executable: String
    let arguments: [String]
}

struct FormatterManifest: Sendable, Equatable {
    let engines: [FormatterEngine]
}

/// Code formatting engine.
/// - stdin/stdout/stderr pumped concurrently → no pipe-buffer deadlock.
/// - 2 MB input cap, 5 s timeout, kill(9) after 0.5 s grace.
/// - Executable must resolve inside embedded Resources (symlink-aware, rejects `..`).
/// - PATH restricted to /usr/bin:/bin — only PATH isolation, no network sandbox claim.
/// - Never executes user code; only runs bundled manifest executables.
enum CodeFormatEngine {
    static let maxInputBytes = 2_000_000
    static let maxOutputBytes = 4_000_000
    static let maxStderrBytes = 64 * 1024
    static let timeoutSeconds: TimeInterval = 5.0
    static let killGrace: TimeInterval = 0.5

    /// Test-only override. Production always uses Bundle.main.resourceURL.
    static var testResourcesOverride: URL?

    private static var manifestCache: [String: FormatterManifest] = [:]
    private static let cacheLock = NSLock()

    static func resourcesDirectory() -> URL? {
        if let override = testResourcesOverride { return override }
        guard let bundleURL = Bundle.main.resourceURL else { return nil }
        let fmt = bundleURL.appendingPathComponent("Formatters")
        guard FileManager.default.fileExists(atPath: fmt.path) else { return nil }
        return bundleURL
    }

    static func loadManifest(at url: URL) throws -> FormatterManifest {
        let data = try Data(contentsOf: url)
        guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FormatError.invalidManifest("根对象不是 JSON 对象")
        }
        guard let arr = raw["engines"] as? [[String: Any]] else {
            return FormatterManifest(engines: [])
        }
        var engines: [FormatterEngine] = []
        for e in arr {
            guard let lang = e["language"] as? String,
                  let exec = e["executable"] as? String,
                  let args = e["arguments"] as? [String] else { continue }
            engines.append(FormatterEngine(language: lang, executable: exec, arguments: args))
        }
        return FormatterManifest(engines: engines)
    }

    static func manifest(forBundleName name: String) -> FormatterManifest? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let c = manifestCache[name] { return c }
        guard let res = resourcesDirectory() else { return nil }
        let url = res.appendingPathComponent("Formatters/\(name)/manifest.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do { let m = try loadManifest(at: url); manifestCache[name] = m; return m }
        catch { return nil }
    }

    static func engine(for lang: CodeLanguage) -> FormatterEngine? {
        let id = lang.manifestIdentifier
        guard !id.isEmpty else { return nil }
        if let n = manifest(forBundleName: "native")?.engines.first(where: { $0.language == id }) { return n }
        if let w = manifest(forBundleName: "web")?.engines.first(where: { $0.language == id }) { return w }
        return nil
    }

    static func expand(arguments: [String], language: String, indent: String, resources: String) -> [String] {
        arguments.map { $0
            .replacingOccurrences(of: "{language}", with: language)
            .replacingOccurrences(of: "{indent}", with: indent)
            .replacingOccurrences(of: "{resources}", with: resources)
        }
    }

    /// Resolve executable. Must be inside Resources after symlink resolution.
    static func resolvedExecURL(relativePath: String, resources: URL) throws -> URL {
        guard !relativePath.hasPrefix("/") else {
            throw FormatError.illegalExecutablePath(relativePath)
        }
        let combined = resources.appendingPathComponent(relativePath).standardizedFileURL
        let resolved = (combined.path as NSString).resolvingSymlinksInPath
        let resRoot = (resources.standardizedFileURL.path as NSString).resolvingSymlinksInPath
        guard resolved.hasPrefix(resRoot + "/") else {
            throw FormatError.illegalExecutablePath(relativePath)
        }
        let url = URL(fileURLWithPath: resolved)
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw FormatError.engineNotFound(relativePath)
        }
        return url
    }

    static func format(_ source: String, language requested: CodeLanguage, indent: String = "  ") throws -> String {
        // Ignore SIGPIPE process-wide: pipe writes to dead children return EPIPE
        // instead of crashing this app. Safe for a single-process GUI tool.
        signal(SIGPIPE, SIG_IGN)

        let bytes = source.utf8.count
        guard bytes <= maxInputBytes else { throw FormatError.tooLarge(bytes) }
        guard !source.isEmpty else { return source }

        if requested == .json {
            return try JSONTools.format(source, indent: indent, compact: false)
        }

        guard let engine = engine(for: requested) else {
            throw FormatError.noEngineAvailable(requested)
        }
        guard let resDir = resourcesDirectory() else {
            throw FormatError.engineNotFound(requested.rawValue)
        }
        let execURL = try resolvedExecURL(relativePath: engine.executable, resources: resDir)
        let args = expand(arguments: engine.arguments,
                          language: requested.manifestIdentifier,
                          indent: indent,
                          resources: resDir.path)

        let process = Process()
        process.executableURL = execURL
        process.arguments = args
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "NSUnbufferedIO": "YES"]

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let lock = NSLock()
        var timedOut = false
        var overflowed = false
        var stdoutBuf = Data()
        var stderrBuf = Data()

        // Watchdog scheduled BEFORE run(); sets timedOut flag, terminates, then kills.
        let watchdog = DispatchWorkItem {
            guard process.isRunning else { return }
            lock.lock(); timedOut = true; lock.unlock()
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + killGrace) {
                if process.isRunning { kill(process.processIdentifier, 9) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: watchdog)

        do { try process.run() }
        catch { watchdog.cancel(); throw FormatError.engineFailed("无法启动引擎：\(error.localizedDescription)") }

        // Pump stdin on background queue — 2MB input won't block on 64KB pipe buffer.
        let inputData = source.data(using: .utf8) ?? Data()
        DispatchQueue.global().async {
            do { try stdinPipe.fileHandleForWriting.write(contentsOf: inputData) } catch { }
            try? stdinPipe.fileHandleForWriting.close()
        }

        // Chunked stdout pump: read 64KB at a time, track total.
        // If exceeds maxOutputBytes, set overflowed and kill process — never truncate.
        let stdoutGroup = DispatchGroup()
        stdoutGroup.enter()
        DispatchQueue.global().async {
            let handle = stdoutPipe.fileHandleForReading
            var buf = Data()
            var overflow = false
            while true {
                let chunk = (try? handle.read(upToCount: 65536)) ?? Data()
                if chunk.isEmpty { break } // EOF
                if buf.count + chunk.count > maxOutputBytes {
                    overflow = true
                    break
                }
                buf.append(chunk)
            }
            if overflow && process.isRunning {
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                    if process.isRunning { kill(process.processIdentifier, 9) }
                }
            }
            lock.lock()
            overflowed = overflow
            stdoutBuf = buf
            lock.unlock()
            stdoutGroup.leave()
        }

        // Chunked stderr pump: cap at maxStderrBytes, discard excess but keep draining.
        let stderrGroup = DispatchGroup()
        stderrGroup.enter()
        DispatchQueue.global().async {
            let handle = stderrPipe.fileHandleForReading
            var buf = Data()
            while true {
                let chunk = (try? handle.read(upToCount: 65536)) ?? Data()
                if chunk.isEmpty { break }
                if buf.count < maxStderrBytes {
                    let room = maxStderrBytes - buf.count
                    buf.append(chunk.prefix(min(room, chunk.count)))
                }
            }
            lock.lock(); stderrBuf = buf; lock.unlock()
            stderrGroup.leave()
        }

        process.waitUntilExit()
        // Bounded wait for pipe pumps (they end on pipe EOF after process exit).
        _ = stdoutGroup.wait(timeout: .now() + 2)
        _ = stderrGroup.wait(timeout: .now() + 2)
        watchdog.cancel()

        // Close pipe handles.
        try? stdinPipe.fileHandleForWriting.close()
        try? stdoutPipe.fileHandleForReading.close()
        try? stderrPipe.fileHandleForReading.close()

        lock.lock()
        let wasTimedOut = timedOut
        let didOverflow = overflowed
        let out = stdoutBuf
        let err = stderrBuf
        let status = process.terminationStatus
        lock.unlock()

        if wasTimedOut { throw FormatError.timeout }
        if didOverflow { throw FormatError.engineFailed("输出超过 \(maxOutputBytes / 1024 / 1024) MB 限制，保留原文") }
        guard status == 0 else {
            let msg = String(data: err, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw FormatError.engineFailed(msg.isEmpty ? "退出码 \(status)" : msg)
        }
        guard let result = String(data: out, encoding: .utf8) else {
            throw FormatError.engineFailed("输出不是有效的 UTF-8")
        }
        // Safety: empty output on non-empty input is treated as failure.
        guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FormatError.engineFailed("引擎输出为空，保留原文")
        }
        return result
    }

    static func clearCache() {
        cacheLock.lock(); manifestCache.removeAll(); cacheLock.unlock()
    }
}
