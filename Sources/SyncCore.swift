import Foundation

/// On-disk format for the optional iCloud Drive sync folder.
/// Everything here is Foundation-only so it can be unit tested without AppKit.
enum SyncFormat {
    static let schema = 1
    static let folderName = "DevKit"
    static let settingsFile = "settings.json"
    static let notebookFile = "notebook.json"
    static let draftsFile = "drafts.json"
}

/// Synced user settings. `updatedAt` is the author-side timestamp (epoch seconds)
/// used for last-writer-wins merges; it travels with the record.
struct SyncSettingsRecord: Equatable {
    var schema: Int
    var updatedAt: Double
    var appearance: String
    var utcOffset: String
    var workEndTime: String
    var toolOrder: [String]
    var codeIndent: String
    var codeLanguage: String
    var diffLanguage: String
    /// Nil only for records written before per-weekday schedules were introduced.
    var workWeekSchedule: WorkWeekSchedule? = nil
}

extension SyncSettingsRecord: Codable {
    enum CodingKeys: String, CodingKey {
        case schema, updatedAt, appearance, utcOffset, workEndTime, toolOrder
        case codeIndent, codeLanguage, diffLanguage, workWeekSchedule
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = (try? c.decode(Int.self, forKey: .schema)) ?? SyncFormat.schema
        updatedAt = (try? c.decode(Double.self, forKey: .updatedAt)) ?? 0
        appearance = (try? c.decode(String.self, forKey: .appearance)) ?? "system"
        utcOffset = (try? c.decode(String.self, forKey: .utcOffset)) ?? "0"
        workEndTime = (try? c.decode(String.self, forKey: .workEndTime)) ?? "20:30"
        toolOrder = (try? c.decode([String].self, forKey: .toolOrder)) ?? []
        codeIndent = (try? c.decode(String.self, forKey: .codeIndent)) ?? "2"
        codeLanguage = (try? c.decode(String.self, forKey: .codeLanguage)) ?? CodeLanguage.automatic.rawValue
        diffLanguage = (try? c.decode(String.self, forKey: .diffLanguage)) ?? CodeLanguage.automatic.rawValue
        if c.contains(.workWeekSchedule), !(try c.decodeNil(forKey: .workWeekSchedule)) {
            workWeekSchedule = try c.decode(WorkWeekSchedule.self, forKey: .workWeekSchedule).validated()
        } else {
            workWeekSchedule = nil
        }
    }
}

struct SyncDraftRecord: Equatable {
    var text: String
    var updatedAt: Double
}

extension SyncDraftRecord: Codable {
    enum CodingKeys: String, CodingKey { case text, updatedAt }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = (try? c.decode(String.self, forKey: .text)) ?? ""
        updatedAt = (try? c.decode(Double.self, forKey: .updatedAt)) ?? 0
    }
}

/// Temporary code: the formatter input plus both Diff panes.
struct SyncDraftsRecord: Equatable {
    var schema: Int
    var formatter: SyncDraftRecord
    var diffLeft: SyncDraftRecord
    var diffRight: SyncDraftRecord
    static func empty() -> SyncDraftsRecord {
        SyncDraftsRecord(schema: SyncFormat.schema,
                         formatter: SyncDraftRecord(text: "", updatedAt: 0),
                         diffLeft: SyncDraftRecord(text: "", updatedAt: 0),
                         diffRight: SyncDraftRecord(text: "", updatedAt: 0))
    }
}

extension SyncDraftsRecord: Codable {
    enum CodingKeys: String, CodingKey { case schema, formatter, diffLeft, diffRight }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = (try? c.decode(Int.self, forKey: .schema)) ?? SyncFormat.schema
        formatter = (try? c.decode(SyncDraftRecord.self, forKey: .formatter)) ?? SyncDraftRecord(text: "", updatedAt: 0)
        diffLeft = (try? c.decode(SyncDraftRecord.self, forKey: .diffLeft)) ?? SyncDraftRecord(text: "", updatedAt: 0)
        diffRight = (try? c.decode(SyncDraftRecord.self, forKey: .diffRight)) ?? SyncDraftRecord(text: "", updatedAt: 0)
    }
}

/// Merge rules.
///
/// Two devices can never agree on wall-clock time to the millisecond, so a small
/// tolerance is applied: a remote record must be clearly newer than the local
/// edit before it may replace what is on this device. Equal timestamps keep the
/// local value, which is then written back so both devices converge.
enum SyncMerge {
    static let tieTolerance: Double = 0.5

    static func settings(local: SyncSettingsRecord, remote: SyncSettingsRecord) -> SyncSettingsRecord {
        // Unknown schema revisions are not safe to interpret; keep local and let
        // the other device be the one that upgrades.
        guard remote.schema == SyncFormat.schema else { return local }
        guard remote.updatedAt > local.updatedAt + tieTolerance else { return local }
        var result = remote
        if result.workWeekSchedule == nil { result.workWeekSchedule = local.workWeekSchedule }
        return result
    }

    static func draft(local: SyncDraftRecord, remote: SyncDraftRecord) -> SyncDraftRecord {
        remote.updatedAt > local.updatedAt + tieTolerance ? remote : local
    }

    static func drafts(local: SyncDraftsRecord, remote: SyncDraftsRecord) -> SyncDraftsRecord {
        guard remote.schema == SyncFormat.schema else { return local }
        return SyncDraftsRecord(
            schema: SyncFormat.schema,
            formatter: draft(local: local.formatter, remote: remote.formatter),
            diffLeft: draft(local: local.diffLeft, remote: remote.diffLeft),
            diffRight: draft(local: local.diffRight, remote: remote.diffRight))
    }

    /// Note-level union: notes and folders only ever grow, and every note carries
    /// its own `updatedAt`, so a newer edit on either device wins per note instead
    /// of replacing the whole library. Remote folders whose name already exists
    /// locally are mapped onto the local folder to avoid duplicate folders.
    static func library(local: NotebookLibrary, remote: NotebookLibrary) -> NotebookLibrary {
        guard remote.schema == local.schema, !remote.folders.isEmpty,
              Set(remote.notes.map(\.id)).count == remote.notes.count,
              Set(remote.folders.map(\.id)).count == remote.folders.count else { return local }
        var merged = local
        var remapped: [UUID: UUID] = [:]
        for folder in remote.folders {
            if merged.folders.contains(where: { $0.id == folder.id }) { continue }
            if let same = merged.folders.first(where: {
                $0.name.compare(folder.name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            }) {
                remapped[folder.id] = same.id
            } else {
                merged.folders.append(folder)
            }
        }
        for var note in remote.notes {
            if let mapped = remapped[note.folderID] { note.folderID = mapped }
            if !merged.folders.contains(where: { $0.id == note.folderID }) {
                note.folderID = merged.folders[0].id
            }
            if let index = merged.notes.firstIndex(where: { $0.id == note.id }) {
                if note.updatedAt > merged.notes[index].updatedAt { merged.notes[index] = note }
            } else {
                merged.notes.append(note)
            }
        }
        return (try? merged.validate()) != nil ? merged : local
    }
}

/// Where the sync folder lives.
enum SyncLayout {
    static func iCloudDriveRoot(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    }

    static func iCloudAvailable(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: iCloudDriveRoot(home: home).path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    /// Default base folder shown to the user; the actual payload lives in `DevKit`
    /// inside it so the folder can be shared with other files safely.
    static func defaultBase(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        iCloudDriveRoot(home: home)
    }

    static func payloadURL(base: URL) -> URL {
        base.appendingPathComponent(SyncFormat.folderName, isDirectory: true)
    }
}

/// Result of reading a remote file: `unreadable` is distinguished from "not there"
/// so a damaged sync file is never overwritten with local content.
struct SyncRead<T> {
    var value: T?
    var unreadable = false
}

enum SyncIO {
    static let maximumBytes = 40_000_000

    static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    static func read<T: Decodable>(_ type: T.Type, from url: URL) -> SyncRead<T> {
        guard exists(url) else { return SyncRead(value: nil) }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
        if values?.isSymbolicLink == true { return SyncRead(value: nil, unreadable: true) }
        if let size = values?.fileSize, size > maximumBytes { return SyncRead(value: nil, unreadable: true) }
        guard let data = try? Data(contentsOf: url) else { return SyncRead(value: nil, unreadable: true) }
        guard let decoded = try? JSONDecoder().decode(type, from: data) else {
            return SyncRead(value: nil, unreadable: true)
        }
        return SyncRead(value: decoded)
    }

    /// Atomic write. Returns true when the bytes on disk actually changed.
    @discardableResult
    static func write<T: Encodable>(_ value: T, to url: URL) throws -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        if let existing = try? Data(contentsOf: url), existing == data { return false }
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temp) }
        guard FileManager.default.createFile(atPath: temp.path, contents: data,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw KitError.message("无法写入同步文件。")
        }
        // POSIX rename(2) atomically creates or replaces the target.
        guard rename(temp.path, url.path) == 0 else {
            throw KitError.message("同步文件原子替换失败。")
        }
        return true
    }

    static func ensureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }
}
