import Foundation
import CoreServices
import UniformTypeIdentifiers

/// One switch per code format: turning a switch on hands that format to DevKit,
/// turning it off puts the previous app back. macOS asks for confirmation on
/// every change, so each switch waits for the system before it settles.
final class CodeDefaultOpener: ObservableObject {
    static let shared = CodeDefaultOpener()
    static let bundleIdentifier = "com.visero.devkit"
    /// Sorted alphabetically for the three-column grid; `.txt` is left alone.
    static let extensions = ["c","cpp","css","go","h","hpp","html","java","js","json","jsx","md","mm","py","rs","sh","sql","swift","toml","ts","tsx","xml","yaml","yml"]
    static let tsNote = ".ts 与 MPEG-TS 视频同后缀，开启后视频也会交给 DevKit"

    @Published private(set) var states: [String: Bool] = [:]
    @Published private(set) var pending: Set<String> = []
    @Published private(set) var message = ""

    private let defaults: UserDefaults
    private let backupKey = "DevKit.defaultOpenersBackup"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        refresh()
    }

    func isEnabled(_ ext: String) -> Bool { states[ext] ?? false }
    func isPending(_ ext: String) -> Bool { pending.contains(ext) }

    /// Reads the live handler for every format, so the switches always show the truth.
    func refresh() {
        var latest: [String: Bool] = [:]
        for ext in Self.extensions {
            guard let identifier = Self.contentType(ext) else { continue }
            latest[ext] = readHandler(identifier) == Self.bundleIdentifier
        }
        if latest != states {
            states = latest
            // A late system confirmation can land after the wait timed out.
            if message.contains("系统没有接受") { message = "" }
        }
    }

    func setEnabled(_ on: Bool, for ext: String) {
        guard !pending.contains(ext) else { return }
        guard let identifier = Self.contentType(ext) else {
            message = "无法识别 .\(ext) 的系统类型"
            return
        }
        pending.insert(ext)
        message = on ? "等待系统确认 .\(ext)…" : "等待系统确认恢复 .\(ext)…"
        let defaults = self.defaults
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var backups = defaults.dictionary(forKey: self.backupKey) as? [String: String] ?? [:]
            let current = self.readHandler(identifier)
            if on, current != Self.bundleIdentifier, let old = current {
                backups[identifier] = old
                defaults.set(backups, forKey: self.backupKey)
            }
            let target = on ? Self.bundleIdentifier : (backups[identifier] ?? "")
            guard !target.isEmpty else {
                DispatchQueue.main.async {
                    self.pending.remove(ext)
                    self.refresh()
                    self.message = "没有 .\(ext) 原来应用的记录，请在访达里手动改回"
                }
                return
            }
            LSSetDefaultRoleHandlerForContentType(identifier as CFString, .editor, target as CFString)
            // The preference only lands once the user accepts the system prompt.
            var confirmed = false
            for _ in 0..<40 {
                Thread.sleep(forTimeInterval: 0.35)
                let handler = self.readHandler(identifier)
                if on ? (handler == Self.bundleIdentifier) : (handler != Self.bundleIdentifier) {
                    confirmed = true
                    break
                }
            }
            if confirmed, !on {
                backups.removeValue(forKey: identifier)
                defaults.set(backups, forKey: self.backupKey)
            }
            let text: String
            if confirmed {
                text = on ? "已把 .\(ext) 交给 DevKit 打开" : "已把 .\(ext) 恢复为原来的应用"
            } else {
                text = "系统没有接受对 .\(ext) 的更改（可能取消了确认）"
            }
            DispatchQueue.main.async {
                self.pending.remove(ext)
                self.refresh()
                self.message = text
            }
        }
    }

    private static func contentType(_ ext: String) -> String? {
        if ext == "tsx" { return UTType("com.microsoft.typescript")?.identifier ?? UTType(filenameExtension: "tsx")?.identifier }
        guard let type = UTType(filenameExtension: ext) else { return nil }
        return type.identifier
    }

    private func readHandler(_ identifier: String) -> String? {
        LSCopyDefaultRoleHandlerForContentType(identifier as CFString, .editor)?.takeRetainedValue() as String?
    }
}
