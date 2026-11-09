import Foundation

/// Pure-logic tests for the iCloud Drive sync merge rules and file IO.
@main
struct SyncTests {
    static var passed = 0
    static func check(_ name: String, _ condition: Bool) {
        guard condition else { print("FAIL: \(name)"); exit(1) }
        passed += 1
    }

    static func settings(stamp: Double, appearance: String = "system", order: [String] = ["clock"]) -> SyncSettingsRecord {
        SyncSettingsRecord(schema: SyncFormat.schema, updatedAt: stamp, appearance: appearance,
                           utcOffset: "0", workEndTime: "20:30", toolOrder: order,
                           codeIndent: "2", codeLanguage: "自动", diffLanguage: "自动")
    }

    static func folder(_ name: String, _ id: UUID = UUID()) -> NotebookFolder {
        NotebookFolder(id: id, name: name)
    }

    static func note(_ title: String, id: UUID = UUID(), folder: UUID, stamp: Date, markdown: String = "") -> NotebookNote {
        NotebookNote(id: id, folderID: folder, title: title, markdown: markdown,
                     createdAt: stamp, updatedAt: stamp)
    }

    static func main() throws {
        // MARK: Settings — last writer wins with a tolerance
        let older = settings(stamp: 100, appearance: "light")
        let newer = settings(stamp: 200, appearance: "dark")
        check("newer remote settings win", SyncMerge.settings(local: older, remote: newer).appearance == "dark")
        check("older remote settings lose", SyncMerge.settings(local: newer, remote: older).appearance == "dark")
        let nearTie = settings(stamp: 200.2, appearance: "light")
        check("tie within tolerance keeps local",
              SyncMerge.settings(local: newer, remote: nearTie).appearance == "dark")
        var unknownSchema = newer
        unknownSchema.schema = 99
        check("unknown schema never replaces local",
              SyncMerge.settings(local: older, remote: unknownSchema).appearance == "light")

        // Weekly schedules travel with settings; old peers cannot wipe a saved week.
        var localWeekly = older
        var week = WorkWeekSchedule.standard
        week[.friday].time = "18:00"
        week[.saturday] = WorkDaySetting(isWorkday:true,time:"15:30")
        localWeekly.workWeekSchedule = week
        let oldPeerMerge = SyncMerge.settings(local:localWeekly,remote:newer)
        check("old peer keeps weekly schedule",oldPeerMerge.workWeekSchedule == week)
        check("old peer other settings still merge",oldPeerMerge.appearance == "dark")
        var remoteWeekly = newer
        remoteWeekly.workWeekSchedule = .migrated(legacyTime:"19:00")
        check("new remote weekly wins",SyncMerge.settings(local:localWeekly,remote:remoteWeekly).workWeekSchedule == remoteWeekly.workWeekSchedule)
        check("weekly settings roundtrip",try JSONDecoder().decode(SyncSettingsRecord.self,from:JSONEncoder().encode(localWeekly)) == localWeekly)
        let oldJSON = #"{"updatedAt":12,"workEndTime":"18:45"}"#.data(using:.utf8)!
        check("old settings decode without week",try JSONDecoder().decode(SyncSettingsRecord.self,from:oldJSON).workWeekSchedule == nil)
        let badWeekJSON = #"{"workWeekSchedule":{"days":[]}}"#.data(using:.utf8)!
        do { _ = try JSONDecoder().decode(SyncSettingsRecord.self,from:badWeekJSON);check("reject invalid weekly sync",false) }
        catch { check("reject invalid weekly sync",true) }

        // MARK: Drafts — merged per field, not as one blob
        var localDrafts = SyncDraftsRecord.empty()
        localDrafts.formatter = SyncDraftRecord(text: "local format", updatedAt: 100)
        localDrafts.diffLeft = SyncDraftRecord(text: "local left", updatedAt: 100)
        var remoteDrafts = SyncDraftsRecord.empty()
        remoteDrafts.formatter = SyncDraftRecord(text: "remote format", updatedAt: 100)
        remoteDrafts.diffLeft = SyncDraftRecord(text: "remote left", updatedAt: 300)
        remoteDrafts.diffRight = SyncDraftRecord(text: "remote right", updatedAt: 300)
        let mergedDrafts = SyncMerge.drafts(local: localDrafts, remote: remoteDrafts)
        check("draft tie keeps local text", mergedDrafts.formatter.text == "local format")
        check("newer remote draft wins", mergedDrafts.diffLeft.text == "remote left")
        check("remote-only draft is imported", mergedDrafts.diffRight.text == "remote right")

        // MARK: Notebook library
        let folderA = UUID(), folderB = UUID(), folderRemote = UUID()
        var localLibrary = NotebookLibrary(folders: [NotebookFolder(id: folderA, name: "工作")])
        let sharedID = UUID()
        let sharedOld = note("共享笔记", id: sharedID, folder: folderA, stamp: Date(timeIntervalSince1970: 100), markdown: "v1")
        localLibrary.notes = [sharedOld]
        var remoteLibrary = NotebookLibrary(folders: [NotebookFolder(id: folderRemote, name: "工作")])
        let sharedNew = note("共享笔记", id: sharedID, folder: folderRemote, stamp: Date(timeIntervalSince1970: 200), markdown: "v2")
        let remoteOnly = note("远端新笔记", folder: folderRemote, stamp: Date(timeIntervalSince1970: 150))
        remoteLibrary.notes = [sharedNew, remoteOnly]
        let mergedLibrary = SyncMerge.library(local: localLibrary, remote: remoteLibrary)
        check("folder with same name is reused", mergedLibrary.folders.count == 1)
        check("newer remote note wins", mergedLibrary.notes.first { $0.title == "共享笔记" }?.markdown == "v2")
        check("remote-only note imported", mergedLibrary.notes.contains { $0.title == "远端新笔记" })
        check("imported note remapped into local folder",
              mergedLibrary.notes.first { $0.title == "远端新笔记" }?.folderID == folderA)
        check("merged library validates", (try? mergedLibrary.validate()) != nil)

        // Local newer edit must not be overwritten by an older remote copy.
        var localNewer = localLibrary
        localNewer.notes[0].updatedAt = Date(timeIntervalSince1970: 400)
        localNewer.notes[0].markdown = "v4"
        let kept = SyncMerge.library(local: localNewer, remote: remoteLibrary)
        check("newer local note survives", kept.notes.first { $0.title == "共享笔记" }?.markdown == "v4")

        // A note pointing at a folder unknown to both sides is re-homed, not dropped.
        var brokenRemote = NotebookLibrary(folders: [NotebookFolder(id: folderB, name: "临时")])
        brokenRemote.notes = [note("孤儿", folder: UUID(), stamp: Date(timeIntervalSince1970: 50))]
        let repaired = SyncMerge.library(local: localLibrary, remote: brokenRemote)
        check("orphan note re-homed", repaired.notes.contains { $0.title == "孤儿" })
        check("repaired library validates", (try? repaired.validate()) != nil)

        // A structurally invalid remote library (duplicate note ids) is rejected.
        var invalidRemote = NotebookLibrary(folders: [NotebookFolder(id: folderA, name: "工作")])
        let dup = note("重复", folder: folderA, stamp: Date())
        invalidRemote.notes = [dup, dup]
        let rejected = SyncMerge.library(local: localLibrary, remote: invalidRemote)
        check("invalid remote library rejected", rejected.notes.count == 1)

        // MARK: Codable tolerance
        let partial = #"{"updatedAt":12,"appearance":"dark"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(SyncSettingsRecord.self, from: partial)
        check("missing settings fields fall back", decoded.utcOffset == "0" && decoded.codeIndent == "2" && decoded.schema == SyncFormat.schema)
        let partialDrafts = #"{"formatter":{"text":"abc"}}"#.data(using: .utf8)!
        let drafts = try JSONDecoder().decode(SyncDraftsRecord.self, from: partialDrafts)
        check("missing draft fields fall back", drafts.formatter.text == "abc" && drafts.diffLeft.updatedAt == 0)

        // MARK: File IO
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("sync-tests-\(UUID().uuidString)")
        try SyncIO.ensureDirectory(root)
        defer { try? fm.removeItem(at: root) }
        let settingsURL = root.appendingPathComponent(SyncFormat.settingsFile)

        let readMissing = SyncIO.read(SyncSettingsRecord.self, from: settingsURL)
        check("missing file is not unreadable", readMissing.value == nil && !readMissing.unreadable)
        let firstWrite = try SyncIO.write(newer, to: settingsURL)
        check("first write reports change", firstWrite)
        let secondWrite = try SyncIO.write(newer, to: settingsURL)
        check("identical bytes are not rewritten", !secondWrite)
        let stored = SyncIO.read(SyncSettingsRecord.self, from: settingsURL)
        check("roundtrip settings", stored.value == newer)
        let attributes = try fm.attributesOfItem(atPath: settingsURL.path)
        check("permissions are private", (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        // Corrupt content must be reported as unreadable so it is not overwritten.
        try Data("not json".utf8).write(to: settingsURL)
        let corrupt = SyncIO.read(SyncSettingsRecord.self, from: settingsURL)
        check("corrupt file is unreadable", corrupt.value == nil && corrupt.unreadable)

        let libraryURL = root.appendingPathComponent(SyncFormat.notebookFile)
        _ = try SyncIO.write(mergedLibrary, to: libraryURL)
        check("roundtrip notebook library",
              SyncIO.read(NotebookLibrary.self, from: libraryURL).value == mergedLibrary)

        // MARK: Layout
        let fakeHome = root.appendingPathComponent("home")
        try SyncIO.ensureDirectory(fakeHome)
        check("missing iCloud Drive detected",
              !SyncLayout.iCloudAvailable(home: fakeHome))
        let payload = SyncLayout.payloadURL(base: fakeHome)
        check("payload folder named DevKit", payload.lastPathComponent == "DevKit")

        print("PASS: \(passed) sync assertions")
    }
}
