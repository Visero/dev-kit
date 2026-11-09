import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Result of loading a draft.
struct DraftLoadResult: Sendable {
    enum Outcome: Sendable, Equatable {
        case noFile
        case loaded(String)
        case corrupted
        case readError
    }
    let outcome: Outcome
    var text: String? {
        if case .loaded(let t) = outcome { return t }
        return nil
    }
}

/// Persistence for the CodeFormatPage's single code input box.
enum CodeDraftStore {
    private static let fileName = "CodeDraft.json"
    private static let queue = DispatchQueue(label: "devkit.code-draft", qos: .utility)
    private static let debounceInterval: TimeInterval = 0.5
    private static let lock = NSLock()
    private static var currentVersion: UInt64 = 0
    private static var pendingVersion: UInt64 = 0
    private static var pendingWork: DispatchWorkItem?
    /// True after a successful load; false after corrupt/readError.
    /// When false, flush() refuses to write (protects corrupt file from empty overwrite).
    private static var loadHealthy = true

    /// Main-thread callback after every save attempt. true = success.
    static var onSaveComplete: ((Bool) -> Void)?

    static var testDirectoryOverride: URL?

    static var bundleIdentifier: String {
        if testDirectoryOverride != nil { return "test" }
        return Bundle.main.bundleIdentifier ?? "com.visero.devkit"
    }

    static var directoryURL: URL {
        if let override = testDirectoryOverride { return override }
        let fm = FileManager.default
        return fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
    }

    static var fileURL: URL { directoryURL.appendingPathComponent(fileName) }

    /// Local draft file modification time, used as its sync timestamp after a relaunch.
    static var fileModificationStamp: Double? {
        guard let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]) else { return nil }
        guard let date = values.contentModificationDate else { return nil }
        return date.timeIntervalSince1970
    }

    private static func ensureDirectory() throws {
        let url = directoryURL
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try fm.createDirectory(at: url, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        } else {
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
    }

    static func load() -> DraftLoadResult {
        let url = fileURL
        // Distinguish "no file" from "read error".
        guard FileManager.default.fileExists(atPath: url.path) else {
            lock.lock(); loadHealthy = true; lock.unlock()
            return DraftLoadResult(outcome: .noFile)
        }
        guard let data = try? Data(contentsOf: url) else {
            lock.lock(); loadHealthy = false; lock.unlock()
            return DraftLoadResult(outcome: .readError)
        }
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = raw["text"] as? String else {
            lock.lock(); loadHealthy = false; lock.unlock()
            return DraftLoadResult(outcome: .corrupted)
        }
        if let v = raw["version"] as? UInt64 {
            lock.lock(); currentVersion = v; pendingVersion = v; lock.unlock()
        }
        lock.lock(); loadHealthy = true; lock.unlock()
        return DraftLoadResult(outcome: .loaded(text))
    }

    /// Mark that the user has edited the draft. Required before flush will write.
    /// Prevents corrupt file from being overwritten by empty flush on app quit.
    static func userDidEdit() {
        lock.lock(); loadHealthy = true; lock.unlock()
    }

    static func scheduleSave(_ text: String) {
        queue.async {
            pendingWork?.cancel()
            // Capture version at submit time, not execution time.
            lock.lock()
            currentVersion += 1
            let v = currentVersion
            lock.unlock()
            let work = DispatchWorkItem {
                // Verify this is still the latest pending version.
                lock.lock()
                guard v == currentVersion else { lock.unlock(); return }
                lock.unlock()
                let ok = performWrite(text, version: v)
                DispatchQueue.main.async { onSaveComplete?(ok) }
            }
            lock.lock(); pendingWork = work; lock.unlock()
            queue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
        }
    }

    static func flush(_ text: String) {
        queue.sync {
            // Don't overwrite a corrupt file on app quit if user hasn't edited.
            lock.lock()
            guard loadHealthy else { lock.unlock(); return }
            pendingWork?.cancel()
            currentVersion += 1
            let v = currentVersion
            lock.unlock()
            let ok = performWrite(text, version: v)
            DispatchQueue.main.async { onSaveComplete?(ok) }
        }
    }

    /// Atomic POSIX write: temp file → chmod 0600 → rename(2, temp → target).
    /// rename(2) atomically creates OR replaces the target; no remove-then-move gap.
    private static func performWrite(_ text: String, version: UInt64) -> Bool {
        let tempURL = directoryURL.appendingPathComponent(".\(fileName).\(UUID().uuidString).tmp")
        do {
            try ensureDirectory()
            let payload: [String: Any] = [
                "version": version, "text": text, "savedAt": Int(Date().timeIntervalSince1970)
            ]
            let data = try JSONSerialization.data(withJSONObject: payload)
            try data.write(to: tempURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tempURL.path)
            // POSIX rename(2) — atomic replace or create on APFS/HFS+.
            let rc = rename(tempURL.path, fileURL.path)
            guard rc == 0 else {
                try? FileManager.default.removeItem(at: tempURL)
                return false
            }
            return true
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            return false
        }
    }
}
