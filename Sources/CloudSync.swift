import Foundation
import Combine
import AppKit
import SwiftUI

enum SyncDraftKey: String, CaseIterable {
    case formatter
    case diffLeft
    case diffRight
}

/// Snapshot of everything that participates in sync, captured on the main thread.
struct SyncSnapshot {
    var settings: SyncSettingsRecord
    var drafts: SyncDraftsRecord
    var library: NotebookLibrary
}

/// Optional iCloud Drive folder sync.
///
/// DevKit is an ad-hoc signed local build, so it cannot own an iCloud ubiquity
/// container. Like Obsidian's iCloud mode, it syncs through a plain folder inside
/// the user's iCloud Drive; the system replicates files between Macs.
final class CloudSyncEngine: ObservableObject {
    static let enabledKey = "DevKit.syncEnabled"
    static let baseFolderKey = "DevKit.syncBaseFolder"
    static let settingsStampKey = "DevKit.settingsEditedAt"
    static let draftStampsKey = "DevKit.draftEditedAt"

    @Published private(set) var enabled = false
    @Published private(set) var baseFolder = ""
    @Published private(set) var iCloudAvailable = false
    @Published private(set) var busy = false
    @Published private(set) var lastError = ""
    @Published private(set) var status = "未开启"
    @Published private(set) var lastSync: Date?

    weak var store: ToolkitStore?

    private let queue = DispatchQueue(label: "devkit.cloud-sync", qos: .utility)
    private var pending: DispatchWorkItem?
    private var watcher: DispatchSourceFileSystemObject?
    private var pollTimer: Timer?
    private var isApplying = false
    private var settingsStamp: Double = 0
    private var draftStamps: [String: Double] = [:]

    // MARK: - Lifecycle

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.bool(forKey: Self.enabledKey)
        baseFolder = defaults.string(forKey: Self.baseFolderKey) ?? ""
        iCloudAvailable = SyncLayout.iCloudAvailable()
        settingsStamp = defaults.double(forKey: Self.settingsStampKey)
        if let stored = defaults.dictionary(forKey: Self.draftStampsKey) {
            draftStamps = stored.compactMapValues { ($0 as? NSNumber)?.doubleValue }
        }
        if draftStamps[SyncDraftKey.formatter.rawValue] == nil,
           let stamp = CodeDraftStore.fileModificationStamp {
            draftStamps[SyncDraftKey.formatter.rawValue] = stamp
        }
        if enabled { status = "等待首次同步" }
    }

    func attach(store: ToolkitStore) {
        self.store = store
        if enabled { start() }
    }

    var payloadURL: URL? {
        guard !baseFolder.isEmpty else { return nil }
        return SyncLayout.payloadURL(base: URL(fileURLWithPath: baseFolder))
    }

    var folderDisplayPath: String { payloadURL?.path ?? "尚未选择文件夹" }

    var usesICloudDrive: Bool {
        guard !baseFolder.isEmpty else { return false }
        let root = SyncLayout.iCloudDriveRoot().path
        return baseFolder.hasPrefix(root)
    }

    var footerTitle: String { enabled ? "iCloud 同步" : "仅在本机处理" }

    var footerDetail: String {
        if enabled {
            if let lastSync {
                let formatter = DateFormatter()
                formatter.dateFormat = "HH:mm"
                return "已同步 · \(formatter.string(from: lastSync))"
            }
            return lastError.isEmpty ? status : "同步待处理"
        }
        return "点此开启同步"
    }

    var symbolName: String { enabled ? "icloud.fill" : "lock.shield" }

    // MARK: - Public controls

    func enable() {
        iCloudAvailable = SyncLayout.iCloudAvailable()
        if baseFolder.isEmpty {
            guard iCloudAvailable else {
                fail("未检测到 iCloud Drive 文件夹。请先在系统设置中开启 iCloud 云盘，或手动选择文件夹。")
                return
            }
            baseFolder = SyncLayout.defaultBase().path
            defaults.set(baseFolder, forKey: Self.baseFolderKey)
        }
        do {
            _ = try ensurePayloadDirectory()
        } catch {
            fail("无法创建同步文件夹：\(error.localizedDescription)")
            return
        }
        enabled = true
        lastError = ""
        status = "等待首次同步"
        defaults.set(true, forKey: Self.enabledKey)
        start()
    }

    func disable() {
        enabled = false
        defaults.set(false, forKey: Self.enabledKey)
        stopWatching()
        pending?.cancel()
        pending = nil
        busy = false
        status = "已关闭同步"
        lastError = ""
    }

    func useICloudDriveDefault() {
        iCloudAvailable = SyncLayout.iCloudAvailable()
        guard iCloudAvailable else {
            fail("本机未检测到 iCloud Drive。请在 系统设置 → Apple 账户 → iCloud → iCloud 云盘 中开启“同步此 Mac”。")
            return
        }
        setBaseFolder(SyncLayout.defaultBase())
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "使用此文件夹"
        panel.message = "DevKit 会在所选文件夹内创建 \(SyncFormat.folderName) 目录，只写入同步数据。"
        if !baseFolder.isEmpty { panel.directoryURL = URL(fileURLWithPath: baseFolder) }
        else if SyncLayout.iCloudAvailable() { panel.directoryURL = SyncLayout.iCloudDriveRoot() }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setBaseFolder(url)
    }

    func setBaseFolder(_ url: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            fail("所选位置不是文件夹。")
            return
        }
        stopWatching()
        baseFolder = url.path
        defaults.set(baseFolder, forKey: Self.baseFolderKey)
        iCloudAvailable = SyncLayout.iCloudAvailable()
        if !enabled { enable() } else {
            do { _ = try ensurePayloadDirectory() } catch {
                fail("无法创建同步文件夹：\(error.localizedDescription)"); return
            }
            start()
        }
    }

    func refreshICloudAvailability() {
        iCloudAvailable = SyncLayout.iCloudAvailable()
    }

    func revealInFinder() {
        guard let payloadURL else { return }
        if FileManager.default.fileExists(atPath: payloadURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([payloadURL])
        }
    }

    func syncNow() {
        guard enabled else { return }
        schedule(0)
    }

    // MARK: - Local change hooks (called on the main thread)

    func localSettingsChanged() {
        guard !isApplying else { return }
        settingsStamp = Date().timeIntervalSince1970
        defaults.set(settingsStamp, forKey: Self.settingsStampKey)
        schedule()
    }

    func localDraftChanged(_ key: SyncDraftKey, text: String) {
        guard !isApplying else { return }
        if text.isEmpty && draftStamps[key.rawValue] == nil { return }
        draftStamps[key.rawValue] = Date().timeIntervalSince1970
        defaults.set(draftStamps, forKey: Self.draftStampsKey)
        schedule()
    }

    func localNotebookChanged() {
        guard !isApplying else { return }
        schedule()
    }

    /// Best-effort final push while the app terminates. Local edits are already on
    /// disk; this makes the sync folder catch up even if the timer had not fired.
    func flushOnTerminate() {
        guard enabled, let store, let root = try? ensurePayloadDirectory() else { return }
        let snapshot = makeSnapshot(store)
        queue.sync {
            _ = mergeAndWrite(snapshot, root: root)
        }
    }

    // MARK: - Scheduling

    private func schedule(_ delay: TimeInterval = 0.6) {
        guard enabled else { return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.runReconcile() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func runReconcile() {
        guard enabled, let store, let root = try? ensurePayloadDirectory() else { return }
        let snapshot = makeSnapshot(store)
        busy = true
        queue.async { [weak self] in
            guard let self else { return }
            let plan = self.mergeAndWrite(snapshot, root: root)
            DispatchQueue.main.async { self.apply(plan, snapshot: snapshot) }
        }
    }

    private func start() {
        guard enabled else { return }
        do { _ = try ensurePayloadDirectory() } catch {
            fail("无法创建同步文件夹：\(error.localizedDescription)")
            enabled = false
            return
        }
        startWatching()
        schedule(0.4)
    }

    private func ensurePayloadDirectory() throws -> URL {
        guard let payloadURL else { throw KitError.message("尚未选择同步文件夹。") }
        let base = URL(fileURLWithPath: baseFolder)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: base.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw KitError.message("同步文件夹不存在，请重新选择。")
        }
        try SyncIO.ensureDirectory(payloadURL)
        return payloadURL
    }

    private func fail(_ message: String) {
        lastError = message
        status = "同步未完成"
    }

    // MARK: - Snapshot

    private func makeSnapshot(_ store: ToolkitStore) -> SyncSnapshot {
        let settings = SyncSettingsRecord(
            schema: SyncFormat.schema,
            updatedAt: settingsStamp,
            appearance: store.appearance,
            utcOffset: store.savedOffset,
            workEndTime: store.workEndTime,
            toolOrder: store.toolOrder.map(\.rawValue),
            codeIndent: store.codeIndent,
            codeLanguage: store.codeLanguage.rawValue,
            diffLanguage: store.diffLanguage.rawValue,
            workWeekSchedule: store.workWeekSchedule)
        let drafts = SyncDraftsRecord(
            schema: SyncFormat.schema,
            formatter: SyncDraftRecord(text: store.codeInput, updatedAt: draftStamps[SyncDraftKey.formatter.rawValue] ?? 0),
            diffLeft: SyncDraftRecord(text: store.left, updatedAt: draftStamps[SyncDraftKey.diffLeft.rawValue] ?? 0),
            diffRight: SyncDraftRecord(text: store.right, updatedAt: draftStamps[SyncDraftKey.diffRight.rawValue] ?? 0))
        return SyncSnapshot(settings: settings, drafts: drafts, library: store.notebook.library)
    }

    private func settingsFromStore(_ store: ToolkitStore, stamp: Double) -> SyncSettingsRecord {
        SyncSettingsRecord(
            schema: SyncFormat.schema, updatedAt: stamp,
            appearance: store.appearance, utcOffset: store.savedOffset,
            workEndTime: store.workEndTime, toolOrder: store.toolOrder.map(\.rawValue),
            codeIndent: store.codeIndent,
            codeLanguage: store.codeLanguage.rawValue,
            diffLanguage: store.diffLanguage.rawValue,
            workWeekSchedule: store.workWeekSchedule)
    }

    private func draftsFromStore(_ store: ToolkitStore, stamps: SyncDraftsRecord) -> SyncDraftsRecord {
        SyncDraftsRecord(
            schema: SyncFormat.schema,
            formatter: SyncDraftRecord(text: store.codeInput, updatedAt: stamps.formatter.updatedAt),
            diffLeft: SyncDraftRecord(text: store.left, updatedAt: stamps.diffLeft.updatedAt),
            diffRight: SyncDraftRecord(text: store.right, updatedAt: stamps.diffRight.updatedAt))
    }

    // MARK: - Merge & write (background queue)

    private struct SyncPlan {
        var settings: SyncSettingsRecord
        var drafts: SyncDraftsRecord
        var library: NotebookLibrary
        var unreadable = ""
    }

    private func mergeAndWrite(_ snapshot: SyncSnapshot, root: URL) -> SyncPlan {
        let settingsURL = root.appendingPathComponent(SyncFormat.settingsFile)
        let draftsURL = root.appendingPathComponent(SyncFormat.draftsFile)
        let notebookURL = root.appendingPathComponent(SyncFormat.notebookFile)

        var plan = SyncPlan(settings: snapshot.settings, drafts: snapshot.drafts, library: snapshot.library)

        let settingsRead = readSettings(settingsURL)
        if settingsRead.unreadable { plan.unreadable = "settings.json 无法读取，已保留原文件" }
        if let remote = settingsRead.value {
            plan.settings = SyncMerge.settings(local: plan.settings, remote: remote)
        }
        if !settingsRead.unreadable, settingsRead.value != plan.settings {
            _ = try? SyncIO.write(plan.settings, to: settingsURL)
        }

        let draftsRead = readDrafts(draftsURL)
        if draftsRead.unreadable && plan.unreadable.isEmpty { plan.unreadable = "drafts.json 无法读取，已保留原文件" }
        if let remote = draftsRead.value {
            plan.drafts = SyncMerge.drafts(local: plan.drafts, remote: remote)
        }
        if !draftsRead.unreadable, draftsRead.value != plan.drafts {
            _ = try? SyncIO.write(plan.drafts, to: draftsURL)
        }

        let libraryRead = readLibrary(notebookURL)
        if libraryRead.unreadable && plan.unreadable.isEmpty { plan.unreadable = "notebook.json 无法读取，已保留原文件" }
        if let remote = libraryRead.value {
            plan.library = SyncMerge.library(local: plan.library, remote: remote)
        }
        if !libraryRead.unreadable, libraryRead.value != plan.library {
            _ = try? SyncIO.write(plan.library, to: notebookURL)
        }
        return plan
    }

    // Read a file plus any unresolved iCloud conflicted copies, merging each copy
    // before marking it resolved. Without this, a conflict copy would sit forever
    // and its edits would never reach the app.
    private func readSettings(_ url: URL) -> SyncRead<SyncSettingsRecord> {
        var result = SyncIO.read(SyncSettingsRecord.self, from: url)
        if let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: url), !versions.isEmpty {
            for version in versions {
                if let record = SyncIO.read(SyncSettingsRecord.self, from: version.url).value {
                    result.value = result.value.map { SyncMerge.settings(local: $0, remote: record) } ?? record
                }
                version.isResolved = true
            }
        }
        return result
    }

    private func readDrafts(_ url: URL) -> SyncRead<SyncDraftsRecord> {
        var result = SyncIO.read(SyncDraftsRecord.self, from: url)
        if let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: url), !versions.isEmpty {
            for version in versions {
                if let record = SyncIO.read(SyncDraftsRecord.self, from: version.url).value {
                    result.value = result.value.map { SyncMerge.drafts(local: $0, remote: record) } ?? record
                }
                version.isResolved = true
            }
        }
        return result
    }

    private func readLibrary(_ url: URL) -> SyncRead<NotebookLibrary> {
        var result = SyncIO.read(NotebookLibrary.self, from: url)
        if let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: url), !versions.isEmpty {
            for version in versions {
                if let record = SyncIO.read(NotebookLibrary.self, from: version.url).value {
                    result.value = result.value.map { SyncMerge.library(local: $0, remote: record) } ?? record
                }
                version.isResolved = true
            }
        }
        return result
    }

    // MARK: - Apply (main thread)

    private func apply(_ plan: SyncPlan, snapshot: SyncSnapshot) {
        busy = false
        guard let store else { return }
        var deferred = false

        isApplying = true
        if plan.settings.updatedAt > snapshot.settings.updatedAt + SyncMerge.tieTolerance,
           settingsFromStore(store, stamp: snapshot.settings.updatedAt) == snapshot.settings {
            store.applySyncSettings(plan.settings)
            settingsStamp = plan.settings.updatedAt
            defaults.set(settingsStamp, forKey: Self.settingsStampKey)
        } else if plan.settings.updatedAt > snapshot.settings.updatedAt + SyncMerge.tieTolerance {
            deferred = true
        }

        if plan.drafts.formatter.updatedAt > snapshot.drafts.formatter.updatedAt + SyncMerge.tieTolerance {
            if store.codeInput == snapshot.drafts.formatter.text && !store.codeBusy {
                store.applySyncDraft(plan.drafts.formatter.text)
                draftStamps[SyncDraftKey.formatter.rawValue] = plan.drafts.formatter.updatedAt
                CodeDraftStore.flush(plan.drafts.formatter.text)
            } else {
                deferred = true
            }
        }
        if plan.drafts.diffLeft.updatedAt > snapshot.drafts.diffLeft.updatedAt + SyncMerge.tieTolerance {
            if store.left == snapshot.drafts.diffLeft.text {
                store.left = plan.drafts.diffLeft.text
                draftStamps[SyncDraftKey.diffLeft.rawValue] = plan.drafts.diffLeft.updatedAt
            } else {
                deferred = true
            }
        }
        if plan.drafts.diffRight.updatedAt > snapshot.drafts.diffRight.updatedAt + SyncMerge.tieTolerance {
            if store.right == snapshot.drafts.diffRight.text {
                store.right = plan.drafts.diffRight.text
                draftStamps[SyncDraftKey.diffRight.rawValue] = plan.drafts.diffRight.updatedAt
            } else {
                deferred = true
            }
        }
        defaults.set(draftStamps, forKey: Self.draftStampsKey)

        if plan.library != snapshot.library {
            if store.notebook.library == snapshot.library, !store.notebook.dirty, !store.notebook.loadFailed {
                store.notebook.applyRemoteLibrary(plan.library)
            } else {
                deferred = true
            }
        }
        isApplying = false

        if !plan.unreadable.isEmpty {
            lastError = plan.unreadable
            status = "同步暂停：同步文件无法读取"
        } else {
            lastError = ""
            lastSync = Date()
            status = "已同步"
        }
        if deferred { schedule(1.2) }
    }

    // MARK: - Watching

    private func startWatching() {
        stopWatching()
        guard let root = payloadURL else { return }
        let fd = open(root.path, O_EVTONLY)
        if fd >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .extend, .rename, .delete, .attrib],
                queue: queue)
            source.setEventHandler { [weak self, weak source] in
                guard let self, let source else { return }
                let flags = source.data
                DispatchQueue.main.async { self.schedule(0.9) }
                if flags.contains(.delete) || flags.contains(.rename) {
                    DispatchQueue.main.async { self.startWatching() }
                }
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            watcher = source
        }
        // iCloud can materialise changes after the file-system event; a slow poll
        // catches those without busy-looping.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.schedule(0)
        }
        pollTimer?.tolerance = 5
    }

    private func stopWatching() {
        pollTimer?.invalidate()
        pollTimer = nil
        watcher?.cancel()
        watcher = nil
    }
}

// MARK: - Sidebar footer entry

struct SyncFooterButton: View {
    @ObservedObject var engine: CloudSyncEngine
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: engine.symbolName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(engine.enabled ? Color.teal : Color.secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(engine.footerTitle).font(.system(size: 12, weight: .medium))
                    Text(engine.lastError.isEmpty ? engine.footerDetail : "同步需要处理")
                        .font(.system(size: 10))
                        .foregroundStyle(engine.lastError.isEmpty ? Color.secondary : Color.orange)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("iCloud 同步设置")
    }
}

// MARK: - Sync settings sheet

struct SyncSheet: View {
    @ObservedObject var engine: CloudSyncEngine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "icloud.fill").font(.system(size: 22, weight: .medium)).foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 2) {
                    Text("iCloud 同步").font(.system(size: 19, weight: .bold))
                    Text("设置、笔记与临时代码在你的 Mac 之间保持一致").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.plain).help("关闭")
            }

            Divider()

            Toggle("启用 iCloud 同步", isOn: Binding(
                get: { engine.enabled },
                set: { on in if on { engine.enable() } else { engine.disable() } }))
                .toggleStyle(.switch)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("同步位置").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Text(engine.usesICloudDrive ? "iCloud 云盘" : "自定义文件夹")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(engine.usesICloudDrive ? Color.teal : Color.secondary)
                }
                Text(engine.folderDisplayPath)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    Button("选择文件夹…") { engine.chooseFolder() }
                    Button("iCloud 默认位置") { engine.useICloudDriveDefault() }
                    Button("在访达中显示") { engine.revealInFinder() }.disabled(!engine.enabled)
                    Spacer()
                }.font(.system(size: 11))
            }

            if !engine.iCloudAvailable {
                Label("本机未检测到 iCloud Drive。请先在 系统设置 → Apple 账户 → iCloud → iCloud 云盘 中开启“同步此 Mac”，或选择任意文件夹作为同步位置。",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Circle().fill(engine.lastError.isEmpty ? Color.teal : Color.orange).frame(width: 7, height: 7)
                Text(engine.lastError.isEmpty ? engine.status : engine.lastError)
                    .font(.system(size: 11)).foregroundStyle(engine.lastError.isEmpty ? Color.secondary : Color.orange)
                    .lineLimit(2)
                Spacer()
                Button("立即同步") { engine.syncNow() }
                    .font(.system(size: 11))
                    .disabled(!engine.enabled || engine.busy)
            }

            Text("同步内容为工具顺序、外观、时区与下班时间等设置，笔记库，以及格式化草稿和 Diff 两侧临时文本。文件只写入你选择的文件夹，不经任何第三方服务器。两台设备同时修改同一条笔记时，较新的修改生效。")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(22)
        .frame(width: 460)
        .onAppear { engine.refreshICloudAvailability() }
    }
}
