import SwiftUI
import AppKit
import UniformTypeIdentifiers
import VaultCore

enum VaultFilter: Hashable {
    case all, favorites, archived, trash, category(String), tag(String)
    var title: String {
        switch self {
        case .all: return L("全部项目")
        case .favorites: return L("收藏")
        case .archived: return L("归档")
        case .trash: return L("回收站")
        case .category(let value): return L10n.category(value)
        case .tag(let value): return value
        }
    }
}

enum VaultImportFlow { case encrypted(URL), preview(VaultImportPreview) }

@MainActor final class VaultModel: ObservableObject {
    @Published var items: [VaultItem] = []
    @Published var revisions: [VaultRevision] = []
    @Published var blobs: [String: Data] = [:]
    @Published var backups: [VaultBackup] = []
    @Published var backupDirectory: URL?
    @Published var registeredVaults: [URL] = []
    @Published var unlockedVaults: [UnlockedVault] = []
    @Published var creatingVault = false
    @Published var showTransfer = false
    @Published var unlocked = false
    @Published var busy = false
    @Published var error: String?
    @Published var notice: String?
    @Published var url: URL?
    @Published var selectedIDs: Set<UUID> = []
    var selected: UUID? {
        get { selectedIDs.count == 1 ? selectedIDs.first : nil }
        set { selectedIDs = newValue.map { [$0] } ?? [] }
    }
    @Published var query = ""
    @Published var filter = VaultFilter.all
    @Published var sortByDate = false
    @Published var editor: VaultItem?
    @Published var historyItem: VaultItem?
    @Published var importFlow: VaultImportFlow?
    var pendingImport: VaultImportPreview? {
        get { if case .preview(let preview) = importFlow { return preview }; return nil }
        set { importFlow = newValue.map(VaultImportFlow.preview) }
    }
    @Published var changingPassword = false
    @Published var showBackups = false
    @Published var showExport = false
    @Published var showHealth = false
    @Published var showBiometrics = false
    @Published var biometricAvailable = false
    @Published var biometricExplanation = ""
    @Published var biometricEnabled = false
    @Published private(set) var unlockedWithMasterPassword = false
    private let biometrics = BiometricVaultAccess()
    @Published var quickQuery = ""
    @Published var quickAccessVisible = false
    @Published var quickAccessStatus: String?
    private var quickPanel: QuickAccessPanel?
    private var hotKey: QuickAccessHotKey?
    private let worker = VaultWorker()
    private var epoch: UInt64 = 0
    private var lastActivity = Date()
    private var clipboardChange: Int?
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?

    init() {
        hotKey = QuickAccessHotKey()
        if let status = hotKey?.status, status != 0 { quickAccessStatus = L("全局快捷键注册失败（\(status)），可使用菜单栏打开快速访问。") }
        observers.append(NotificationCenter.default.addObserver(forName: .passwordCraftQuickAccessRequested, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.showQuickAccess() }
        })
        registeredVaults = Array(Set((UserDefaults.standard.stringArray(forKey: "vaultPaths") ?? []).map { VaultWorker.canonicalURL(URL(fileURLWithPath: $0)) })).sorted { $0.path < $1.path }
        if let path = UserDefaults.standard.string(forKey: "lastVault") {
            url = VaultWorker.canonicalURL(URL(fileURLWithPath: path))
            if let url, !registeredVaults.contains(url) { registeredVaults.append(url) }
        }
        refreshBiometrics()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]) { [weak self] event in
            self?.lastActivity = Date(); return event
        }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.unlockedVaults.isEmpty, Date().timeIntervalSince(self.lastActivity) >= 300 else { return }
                self.lock()
            }
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lock() }
        })
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.lock() } })
        }
        observers.append(DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.lock() } })
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
            guard let window = note.object as? NSWindow, window.identifier?.rawValue == "vault" || window.title == "PasswordCraft" else { return }
            Task { @MainActor in self?.lock() }
        })
    }
    var hasDocumentSheet: Bool { editor != nil || historyItem != nil || importFlow != nil || changingPassword || showBackups || showExport || showHealth || showBiometrics || showTransfer }
    var hasSheet: Bool { hasDocumentSheet || quickAccessVisible }
    var canOperate: Bool { unlocked && !busy && !hasDocumentSheet }
    var visible: [VaultItem] {
        let filtered = items.filter { item in
            let included: Bool
            switch filter {
            case .all: included = item.state == .active
            case .favorites: included = item.state == .active && item.favorite
            case .archived: included = item.state == .archived
            case .trash: included = item.state == .trashed
            case .category(let category): included = item.state == .active && item.category == category
            case .tag(let tag): included = item.state == .active && item.tags.contains(tag)
            }
            return included && VaultSearch.matches(item, query: query)
        }
        return filtered.sorted { sortByDate ? $0.updatedAt > $1.updatedAt : $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    var current: VaultItem? { visible.first { $0.id == selected } }
    var activeCount: Int { items.filter { $0.state == .active }.count }
    var trashCount: Int { items.filter { $0.state == .trashed }.count }
    var categories: [String] { Array(Set(ItemTemplates.categories + items.filter { $0.state == .active }.map(\.category))).sorted() }
    var tags: [String] { Array(Set(items.filter { $0.state == .active }.flatMap(\.tags))).sorted() }
    func history(for item: VaultItem) -> [VaultRevision] { revisions.filter { $0.itemID == item.id }.sorted { $0.createdAt > $1.createdAt } }
    func showError(_ value: Error) { error = value.localizedDescription }
    func chooseVault() {
        guard !busy, !hasDocumentSheet else { return }
        let panel = NSOpenPanel(); panel.title = L("打开本地加密密码库"); panel.canChooseDirectories = false
        if panel.runModal() == .OK, let value = panel.url { selectVault(value) }
    }
    func newVaultURL() -> URL? { destination(title: L("新建本地加密密码库"), name: L("我的密码库.localvault")) }
    func destination(title: String, name: String) -> URL? {
        let panel = NSSavePanel(); panel.title = title; panel.nameFieldStringValue = name
        guard panel.runModal() == .OK, let result = panel.url else { return nil }
        guard !FileManager.default.fileExists(atPath: result.path) else { error = L("请选择新文件名，不能覆盖已有文件。"); return nil }
        return result
    }
    private func register(_ url: URL) {
        if !registeredVaults.contains(url) { registeredVaults.append(url); registeredVaults.sort { $0.path < $1.path } }
        UserDefaults.standard.set(registeredVaults.map(\.path), forKey: "vaultPaths")
        UserDefaults.standard.set(url.path, forKey: "lastVault")
    }
    func selectVault(_ target: URL?, itemID: UUID? = nil) {
        guard !busy, !hasDocumentSheet else { return }
        clearSelection(); epoch += 1; let operation = epoch
        url = target.map(VaultWorker.canonicalURL); creatingVault = false
        if let url { register(url) } else { UserDefaults.standard.removeObject(forKey: "lastVault") }
        refreshBiometrics(); busy = true
        let selection = url
        Task {
            do {
                let snapshot = try await worker.select(selection, generation: operation)
                guard epoch == operation else { return }
                apply(snapshot)
                if let itemID { selected = itemID }
            } catch {
                let state = try? await worker.workspace(generation: operation)
                if epoch == operation { if let state { apply(state) }; showError(error) }
            }
            if epoch == operation { busy = false }
        }
    }
    func beginCreateVault() { selectVault(nil); creatingVault = true }
    func forgetCurrentVault() {
        guard !busy, !hasDocumentSheet, !unlocked, let url else { return }
        registeredVaults.removeAll { $0 == url }
        UserDefaults.standard.set(registeredVaults.map(\.path), forKey: "vaultPaths")
        selectVault(nil)
    }
    private func apply(_ workspace: VaultWorkspaceSnapshot) {
        unlockedVaults = workspace.unlockedVaults
        unlocked = workspace.active != nil
        unlockedWithMasterPassword = unlockedVaults.first { $0.url == url }?.masterPassword ?? false
        guard let snapshot = workspace.active else { return }

        items = snapshot.items; revisions = snapshot.revisions; blobs = snapshot.blobs; backups = snapshot.backups
        backupDirectory = snapshot.backupDirectory
        if let warning = snapshot.warning { notice = warning }
        pruneSelection()
        if selectedIDs.isEmpty { selected = visible.first?.id }
    }
    func unlock(password: String, createAt: URL? = nil) {
        guard !busy, let selectedURL = createAt ?? url else { return }
        let target = VaultWorker.canonicalURL(selectedURL); url = target
        busy = true; epoch += 1; let operation = epoch
        Task {
            do {
                _ = try await worker.open(target, password: password, create: createAt != nil, generation: operation)
                let snapshot = try await worker.workspace(generation: operation)
                guard epoch == operation else { await worker.cancel(generation: operation); return }
                apply(snapshot); creatingVault = false; register(target); refreshBiometrics()
                lastActivity = Date()
            } catch { if epoch == operation { showError(error) } }
            if epoch == operation { busy = false }
        }
    }
    func refreshBiometrics() {
        let capability = biometrics.capability()
        biometricAvailable = capability.available; biometricExplanation = capability.explanation
        biometricEnabled = url.map { biometrics.isEnabled($0) } ?? false
    }
    func languageChanged() {
        refreshBiometrics()
        quickPanel?.updateLanguage()
        if let status = hotKey?.status, status != 0 {
            quickAccessStatus = L("全局快捷键注册失败（\(status)），可使用菜单栏打开快速访问。")
        }
    }
    func enableBiometrics() {
        guard unlocked, unlockedWithMasterPassword, !busy, let target = url else { return }
        busy = true; let operation = epoch
        Task {
            do {
                let material = try await worker.deviceUnlockMaterial(generation: operation)
                guard operation == epoch else { return }
                try biometrics.enable(material, for: target)
                refreshBiometrics(); notice = L("Touch ID 已启用；设备解锁密钥仅保存在此 Mac 的受保护钥匙串中。")
            } catch { if operation == epoch { showError(error) } }
            if operation == epoch { busy = false }
        }
    }
    func disableBiometrics() {
        guard !busy, let target = url else { return }
        do { try biometrics.disable(for: target); refreshBiometrics(); notice = L("设备解锁记录已移除。") }
        catch { showError(error) }
    }
    func unlockWithBiometrics() {
        guard !unlocked, !busy, let target = url else { return }
        busy = true; epoch += 1; let operation = epoch
        Task {
            do {
                let material = try await biometrics.retrieve(for: target)
                guard epoch == operation else { return }
                _ = try await worker.open(target, deviceUnlockMaterial: material, generation: operation)
                let snapshot = try await worker.workspace(generation: operation)
                guard epoch == operation else { await worker.cancel(generation: operation); return }
                apply(snapshot); register(target)
                lastActivity = Date(); refreshBiometrics()
            } catch { if epoch == operation { showError(error); refreshBiometrics() } }
            if epoch == operation { busy = false }
        }
    }
    func showQuickAccess() {
        // A document sheet owns its error presentation and must finish first.
        guard !hasDocumentSheet else { NSApp.activate(ignoringOtherApps: true); return }
        if quickPanel == nil { quickPanel = QuickAccessPanel(model: self) }
        lastActivity = Date(); quickQuery = ""; quickAccessVisible = true; quickPanel?.show()
    }
    func hideQuickAccess() { quickQuery = ""; quickAccessVisible = false; quickPanel?.hide() }
    private func clearSelection() {
        biometrics.cancel(); unlockedWithMasterPassword = false; hideQuickAccess()
        items = []; revisions = []; blobs = [:]; backups = []; backupDirectory = nil; editor = nil; historyItem = nil
        pendingImport = nil; selected = nil; query = ""; filter = .all; unlocked = false
        changingPassword = false; showBackups = false; showExport = false; showHealth = false; showBiometrics = false; showTransfer = false
        notice = nil; error = nil; busy = false; clearClipboard()
    }
    func lock() {
        clearSelection(); unlockedVaults = []
        epoch += 1; let generation = epoch
        Task { await worker.invalidate(generation: generation) }
    }
    func lockCurrentVault() {
        guard !busy, !hasDocumentSheet, let target = url else { return }
        clearSelection(); unlockedVaults.removeAll { $0.url == target }
        epoch += 1; let operation = epoch; busy = true
        Task {
            do { let snapshot = try await worker.lockVault(target, generation: operation); if epoch == operation { apply(snapshot) } }
            catch { if epoch == operation { showError(error) } }
            if epoch == operation { busy = false }
        }
    }
    func closeVault() { lock(); url = nil; creatingVault = false; refreshBiometrics(); UserDefaults.standard.removeObject(forKey: "lastVault") }
    var transferDestinations: [UnlockedVault] { unlockedVaults.filter { $0.url != url } }
    func transfer(to destination: URL, move: Bool) {
        let ids = selectedIDs.intersection(Set(visible.map(\.id)))
        guard unlocked, !busy, showTransfer, !ids.isEmpty else { return }
        busy = true; let operation = epoch
        Task {
            do {
                let result = try await worker.transfer(itemIDs: ids, to: destination, move: move, generation: operation)
                let snapshot = try await worker.workspace(generation: operation)
                if epoch == operation { apply(snapshot); notice = result.message; showTransfer = false }
            } catch { if epoch == operation { showError(error) } }
            if epoch == operation { busy = false }
        }
    }
    func newItem() { editor = VaultItem() }
    func save(_ item: VaultItem) {
        var next = items
        if let index = next.firstIndex(where: { $0.id == item.id }) { next[index] = item } else { next.append(item) }
        perform(select: item.id, revealInAll: !items.contains(where: { $0.id == item.id }), message: L("已保存；修改前的恢复点已自动加密备份。")) { worker, generation in try await worker.save(next, generation: generation) }
    }
    func pruneSelection() { selectedIDs.formIntersection(Set(visible.map(\.id))) }
    func batch(_ operation: BatchEdit.Operation) {
        let ids = selectedIDs.intersection(Set(visible.map(\.id)))
        do {
            let next = try BatchEdit.applying(operation, to: items, ids: ids)
            perform(message: L("已批量更新 \(ids.count) 个项目。")) { worker, generation in try await worker.save(next, generation: generation) }
        } catch { showError(error) }
    }
    func changeState(_ item: VaultItem, to state: ItemState) {
        var updated = item; updated.state = state; updated.deletedAt = state == .trashed ? Date() : nil; updated.updatedAt = Date()
        save(updated)
    }
    func purge(_ item: VaultItem) {
        perform(message: L("项目及库内历史已永久删除。已有加密备份仍可能包含它。")) { worker, generation in try await worker.purge(itemID: item.id, generation: generation) }
    }
    func restore(_ revision: VaultRevision) {
        perform(select: revision.itemID, message: L("历史版本已恢复，恢复前内容也已保留为历史。")) { worker, generation in
            try await worker.restoreRevision(itemID: revision.itemID, revisionID: revision.id, generation: generation)
        }
    }
    private func perform(select: UUID? = nil, revealInAll: Bool = false, message: String, action: @escaping (VaultWorker, UInt64) async throws -> Void) {
        guard unlocked, !busy else { return }; busy = true; let operation = epoch
        Task {
            do {
                try await action(worker, operation)
                let snapshot = try await worker.workspace(generation: operation)
                if epoch == operation {
                    if revealInAll { filter = .all; query = "" }
                    if let select { selected = select }; notice = message; apply(snapshot)
                    editor = nil; historyItem = nil; pendingImport = nil; changingPassword = false
                }
            } catch { if epoch == operation { showError(error) } }
            if epoch == operation { busy = false }
        }
    }
    func copy(_ text: String, validFor: TimeInterval = 30) {
        guard !unlockedVaults.isEmpty else { return }
        let board = NSPasteboard.general; board.clearContents(); board.setString(text, forType: .string)
        board.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        board.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        let lifetime = min(30, max(0, validFor))
        clipboardChange = board.changeCount; let count = board.changeCount; notice = L("已复制，\(Int(ceil(lifetime))) 秒内清除")
        DispatchQueue.main.asyncAfter(deadline: .now() + lifetime) { [weak self] in
            guard self?.clipboardChange == count else { return }; self?.clearClipboard()
        }
    }
    private func clearClipboard() {
        if let count = clipboardChange, NSPasteboard.general.changeCount == count { NSPasteboard.general.clearContents() }
        clipboardChange = nil
    }
    func importFile() {
        guard canOperate else { return }
        let panel = NSOpenPanel(); panel.title = L("导入 OPVault、AgileKeychain、1PIF、1PUX、CSV 或完整 JSON"); panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let source = panel.url, unlocked else { return }
        if LegacyVaultFormat(url: source) != nil { importFlow = .encrypted(source); return }
        busy = true; let operation = epoch
        Task {
            do { let imported = try await worker.previewImport(source); if epoch == operation { pendingImport = imported } }
            catch { if epoch == operation { showError(error) } }
            if epoch == operation { busy = false }
        }
    }
    func decryptImport(password: String) {
        guard unlocked, !busy, case .encrypted(let source) = importFlow else { return }
        busy = true; let operation = epoch
        Task {
            do {
                let imported = try await worker.previewLegacyVault(source, password: password, generation: operation)
                if epoch == operation { importFlow = .preview(imported) }
            } catch { if epoch == operation { showError(error) } }
            if epoch == operation { busy = false }
        }
    }
    func addAttachment(to item: VaultItem) {
        guard canOperate else { return }
        let panel = NSOpenPanel(); panel.title = L("添加加密附件（单个最多 16 MiB）"); panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let source = panel.url else { return }
        let mediaType = UTType(filenameExtension: source.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        perform(select: item.id, message: L("附件已加密保存，修改前版本可从历史恢复。")) { worker, generation in
            try await worker.addAttachment(itemID: item.id, from: source, mediaType: mediaType, generation: generation)
        }
    }
    func removeAttachment(_ attachment: VaultAttachment, from item: VaultItem) {
        perform(select: item.id, message: L("附件已从当前版本移除，历史和已有备份仍保留原内容。")) { worker, generation in
            try await worker.removeAttachment(itemID: item.id, attachmentID: attachment.id, generation: generation)
        }
    }
    func attachmentData(_ attachment: VaultAttachment, itemID: UUID, revisionID: UUID?) async throws -> Data {
        let operation = epoch
        let bytes = try await worker.attachmentData(itemID: itemID, attachmentID: attachment.id, revisionID: revisionID, generation: operation)
        guard operation == epoch, unlocked else { throw VaultError.message(L("密码库已锁定，附件读取取消。")) }
        return bytes
    }
    func exportAttachment(_ attachment: VaultAttachment, itemID: UUID, revisionID: UUID?) {
        guard unlocked, !busy, let target = destination(title: L("导出未加密附件"), name: attachment.name) else { return }
        busy = true; let operation = epoch
        Task {
            do {
                try await worker.exportAttachment(itemID: itemID, attachmentID: attachment.id, revisionID: revisionID, to: target, generation: operation)
                if epoch == operation { notice = L("原始附件已明文导出，请妥善保管。") }
            } catch { if epoch == operation { showError(error) } }
            if epoch == operation { busy = false }
        }
    }
    func commitImport(copies: Bool) {
        guard let preview = pendingImport else { return }
        perform(message: L("导入完成；已按选择处理重复项目。")) { worker, generation in
            try await worker.commitImport(preview, copies: copies, generation: generation)
        }
    }
    func backup() {
        guard let target = destination(title: L("保存加密副本"), name: L("密码库副本.localvault")) else { return }
        perform(message: L("加密副本已保存，可通过「打开密码库」验证。")) { worker, generation in try await worker.backup(target, generation: generation) }
    }
    func changePassword(_ password: String) {
        // Remove the old protected key before rekeying. Cleanup failure must not
        // leave a credential whose UI state falsely reports it was disabled.
        guard unlocked, !busy, let target = url else { return }
        do { if biometrics.isEnabled(target) { try biometrics.disable(for: target) }; refreshBiometrics() }
        catch { showError(error); return }
        perform(message: L("主密码已更新。改密前的备份仍使用原主密码，请保留原密码以便恢复。")) { worker, generation in try await worker.changePassword(password, generation: generation) }
    }
    func revealBackups() { if let directory = backupDirectory { NSWorkspace.shared.open(directory) } }
    func recover(_ backup: VaultBackup, password: String) {
        guard !busy, let target = destination(title: L("恢复为新的密码库文件"), name: L("恢复的密码库.localvault")) else { return }
        busy = true; let operation = epoch
        Task {
            do {
                try await worker.recoverBackup(backup.url, to: target, password: password, generation: operation)
                guard epoch == operation else { return }
                lock(); url = target; unlock(password: password)
            } catch { if epoch == operation { showError(error); busy = false } }
        }
    }
    func export(_ format: VaultExportFormat) {
        let ext: String = format == .nativeJSON ? "json" : format == .onePIF ? "1pif" : "csv"
        guard !busy, let target = destination(title: L("导出未加密数据"), name: L("密码库导出.\(ext)")) else { return }
        busy = true; let operation = epoch
        Task {
            do {
                try await worker.exportTransfer(to: target, format: format, generation: operation)
                if epoch == operation { showExport = false; notice = L("明文导出已保存，请妥善保管并核对。") }
            } catch { if epoch == operation { showError(error) } }
            if epoch == operation { busy = false }
        }
    }
}

func isSensitive(_ kind: FieldKind) -> Bool { kind == .password || kind == .otp }

extension VaultWorker {
    func previewImport(_ url: URL) throws -> VaultImportPreview { try VaultInterchange.read(from: url) }
    func commitImport(_ preview: VaultImportPreview, copies: Bool, generation: UInt64) throws {
        let current = try snapshot(generation: generation)
        let merge = try VaultInterchange.planMerge(preview, existing: current.items, existingRevisions: current.revisions, existingBlobs: current.blobs, policy: copies ? .copies : .skipExisting)
        try save(merge.items, generation: generation, importedRevisions: merge.revisions, importedBlobs: merge.document.blobs)
    }
    func exportTransfer(to url: URL, format: VaultExportFormat, generation: UInt64) throws {
        let current = try snapshot(generation: generation)
        try VaultInterchange.export(VaultTransferDocument(items: current.items, revisions: current.revisions, blobs: current.blobs), to: url, format: format)
    }
}
