import Foundation

/// Owns all unlocked sessions and rejects work from a superseded UI selection.
/// All session operations are synchronous inside this actor: an invalidation cannot
/// interleave with a partial save, and an old cleanup cannot close a newer session.
public actor VaultWorker {
    private struct Entry {
        let session: VaultSession
        let openedGeneration: UInt64
        let masterPassword: Bool
    }
    private var sessions: [URL: Entry] = [:]
    private var activeURL: URL?
    public static let maximumUnlockedVaults = 8
    private var session: VaultSession? { activeURL.flatMap { sessions[$0]?.session } }
    private var latestGeneration: UInt64 = 0
    private var sessionGeneration: UInt64?

    private let backupRoot: URL?

    public init(backupRoot: URL? = nil) { self.backupRoot = backupRoot }

    public func open(_ url: URL, password: String, create: Bool, generation: UInt64) throws -> [VaultItem] {
        try beginOpen(url, generation: generation)
        let opened = try create ? VaultSession.create(at: canonical(url), password: password, backupRoot: backupRoot) : VaultSession.open(at: canonical(url), password: password, backupRoot: backupRoot)
        return try retain(opened, masterPassword: true, generation: generation)
    }

    public static func canonicalURL(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath() }
    private func canonical(_ url: URL) -> URL { Self.canonicalURL(url) }

    private func beginOpen(_ url: URL, generation: UInt64) throws {
        try advance(generation)
        guard sessions[canonical(url)] == nil else { throw VaultError.message(L("密码库已解锁，请从库列表切换。")) }
        // Bound the number of resident decrypted vaults (each serialized vault is at most 32 MiB).
        guard sessions.count < Self.maximumUnlockedVaults else { throw VaultError.message(L("最多同时解锁 8 个库，请先锁定一个库。")) }
    }
    private func retain(_ opened: VaultSession, masterPassword: Bool, generation: UInt64) throws -> [VaultItem] {
        guard !sessions.values.contains(where: { $0.session.vaultID == opened.vaultID }) else {
            opened.lock()
            throw VaultError.message(L("此文件与已解锁库具有相同库标识（副本或另一个文件入口）。请先锁定原库。"))
        }
        sessions[opened.fileURL] = Entry(session: opened, openedGeneration: generation, masterPassword: masterPassword)
        activeURL = opened.fileURL; sessionGeneration = generation
        return opened.items
    }
    private func advance(_ generation: UInt64) throws {
        guard generation > latestGeneration else { throw expiredOperation() }
        latestGeneration = generation; activeURL = nil; sessionGeneration = nil
    }
    /// Selecting a locked path only changes selection; other unlocked vaults remain open.
    public func select(_ url: URL?, generation: UInt64) throws -> VaultWorkspaceSnapshot {
        try advance(generation)
        if let url, let entry = sessions[canonical(url)] {
            do { try entry.session.verifyUnchanged() }
            catch { sessions.removeValue(forKey: canonical(url))?.session.lock(); throw error }
            activeURL = canonical(url); sessionGeneration = generation
        }
        return try workspace(generation: generation)
    }
    public func workspace(generation: UInt64) throws -> VaultWorkspaceSnapshot {
        guard generation == latestGeneration else { throw expiredOperation() }
        let vaults = sessions.map { url, entry in
            UnlockedVault(url: url, items: entry.session.items, masterPassword: entry.masterPassword)
        }.sorted { $0.url.path < $1.url.path }
        return VaultWorkspaceSnapshot(active: session == nil ? nil : try snapshot(generation: generation), unlockedVaults: vaults)
    }
    public func lockVault(_ url: URL, generation: UInt64) throws -> VaultWorkspaceSnapshot {
        try advance(generation)
        sessions.removeValue(forKey: canonical(url))?.session.lock()
        return try workspace(generation: generation)
    }

    public func save(_ items: [VaultItem], generation: UInt64, importedRevisions: [VaultRevision] = [], importedBlobs: [String: Data] = [:]) throws {
        try matchingSession(generation).save(items: items, importedRevisions: importedRevisions, importedBlobs: importedBlobs)
    }
    public func previewLegacyVault(_ url: URL, password: String, generation: UInt64) throws -> VaultImportPreview {
        _ = try matchingSession(generation)
        guard let format = LegacyVaultFormat(url: url) else { throw VaultError.message(L("请选择 OPVault 或 AgileKeychain 目录。")) }
        return try format.read(from: url, password: password)
    }

    public func deviceUnlockMaterial(generation: UInt64) throws -> Data {
        try matchingSession(generation).deviceUnlockMaterial()
    }

    public func open(_ url: URL, deviceUnlockMaterial: Data, generation: UInt64) throws -> [VaultItem] {
        try beginOpen(url, generation: generation)
        let opened = try VaultSession.open(at: canonical(url), deviceUnlockMaterial: deviceUnlockMaterial, backupRoot: backupRoot)
        return try retain(opened, masterPassword: false, generation: generation)
    }

    public func snapshot(generation: UInt64) throws -> VaultSnapshot {
        let current = try matchingSession(generation)
        do {
            return VaultSnapshot(items: current.items, revisions: current.allRevisions, blobs: current.transferDocument.blobs, backups: try current.availableBackups(), backupDirectory: current.backupDirectory, warning: current.lastWarning)
        } catch {
            let listingWarning = L("无法读取自动备份列表；修复备份目录后才能继续保存。\(error.localizedDescription)")
            let warning = current.lastWarning.map { $0 + "\n" + listingWarning } ?? listingWarning
            return VaultSnapshot(items: current.items, revisions: current.allRevisions, blobs: current.transferDocument.blobs, backups: [], backupDirectory: current.backupDirectory, warning: warning)
        }
    }

    public func restoreRevision(itemID: UUID, revisionID: UUID, generation: UInt64) throws {
        try matchingSession(generation).restoreRevision(itemID: itemID, revisionID: revisionID)
    }

    public func purge(itemID: UUID, generation: UInt64) throws {
        try matchingSession(generation).purge(itemID: itemID)
    }

    public func recoverBackup(_ backupURL: URL, to destination: URL, password: String, generation: UInt64) throws {
        try matchingSession(generation).recoverBackup(backupURL, to: destination, password: password)
    }

    public func backup(_ url: URL, generation: UInt64) throws {
        try matchingSession(generation).backup(to: url)
    }

    public func changePassword(_ password: String, generation: UInt64) throws {
        try matchingSession(generation).changePassword(password)
    }
    public func addAttachment(itemID: UUID, from source: URL, mediaType: String, generation: UInt64) throws {
        let current = try matchingSession(generation)
        let bytes = try BoundedFileReader.read(source, maximumBytes: AttachmentStore.maximumAttachmentBytes)
        try current.addAttachment(itemID: itemID, name: source.lastPathComponent, mediaType: mediaType, data: bytes)
    }
    public func removeAttachment(itemID: UUID, attachmentID: UUID, generation: UInt64) throws {
        try matchingSession(generation).removeAttachment(itemID: itemID, attachmentID: attachmentID)
    }
    public func attachmentData(itemID: UUID, attachmentID: UUID, revisionID: UUID? = nil, generation: UInt64) throws -> Data {
        try matchingSession(generation).attachmentData(itemID: itemID, attachmentID: attachmentID, revisionID: revisionID)
    }
    public func exportAttachment(itemID: UUID, attachmentID: UUID, revisionID: UUID? = nil, to destination: URL, generation: UInt64) throws {
        try matchingSession(generation).exportAttachment(itemID: itemID, attachmentID: attachmentID, revisionID: revisionID, to: destination)
    }

    /// Invalidation supersedes both an existing session and an open that has not
    /// arrived yet. An older delayed invalidation has no effect on newer work.
    public func invalidate(generation: UInt64) {
        guard generation >= latestGeneration else { return }
        latestGeneration = generation
        clearSessions()
    }

    /// Cleanup for one completed open; unlike invalidation, it never advances
    /// the generation or changes a replacement session.
    public func cancel(generation: UInt64) {
        // Cancel only the session opened by this generation, never a newer one.
        guard generation == latestGeneration else { return }
        guard let url = sessions.first(where: { $0.value.openedGeneration == generation })?.key else { return }
        sessions.removeValue(forKey: url)?.session.lock()
        if activeURL == url { activeURL = nil; sessionGeneration = nil }
    }

    public func readImport(_ url: URL) throws -> [VaultItem] {
        try OnePasswordImporter.read(from: url)
    }

    private func matchingSession(_ generation: UInt64) throws -> VaultSession {
        guard generation == latestGeneration, generation == sessionGeneration, let session else {
            throw expiredOperation()
        }
        return session
    }

    private func clearSessions() {
        for entry in sessions.values { entry.session.lock() }
        sessions.removeAll(); activeURL = nil; sessionGeneration = nil
    }

    /// Each file commit is atomic; the pair is deliberately recoverable, not a transaction.
    /// A move retains the source in Trash (and its backups) after the destination is saved.
    public func transfer(itemIDs: Set<UUID>, to destination: URL, move: Bool, generation: UInt64) throws -> VaultMoveResult {
        let source = try matchingSession(generation)
        guard let target = sessions[canonical(destination)]?.session, target !== source else {
            throw VaultError.message(L("请选择另一个已解锁的密码库。"))
        }
        try source.verifyUnchanged(); try target.verifyUnchanged()
        let selected = source.items.filter { itemIDs.contains($0.id) }
        guard !selected.isEmpty, selected.count == itemIDs.count, selected.allSatisfy({ $0.state != .trashed }) else {
            throw VaultError.message(L("请选择仍在源库中的非回收站项目。"))
        }
        var merged = target.items
        let existing = Dictionary(uniqueKeysWithValues: target.items.map { ($0.id, $0) })
        for item in selected {
            if let previous = existing[item.id] {
                guard previous == item else { throw VaultError.message(L("目标库存在同一标识但内容不同的项目，未覆盖任何内容。请先核对两库项目。")) }
            } else { merged.append(item) }
        }
        let history = source.allRevisions.filter { itemIDs.contains($0.itemID) }
        let blobs = AttachmentStore.referenced(items: selected, revisions: history, in: source.transferDocument.blobs)
        try target.save(items: merged, importedRevisions: history, importedBlobs: blobs)
        guard move else { return .copied(selected.count, warning: target.lastWarning) }
        do {
            // Also check the no-op/retry path, where save may not publish a file.
            try target.verifyUnchanged()
            try source.save(items: BatchEdit.applying(.trash, to: source.items, ids: itemIDs))
            return .moved(selected.count, warning: [target.lastWarning, source.lastWarning].compactMap { $0 }.joined(separator: "\n"))
        } catch {
            return .sourceRetained(selected.count, reason: error.localizedDescription)
        }
    }

    private func expiredOperation() -> VaultError {
        .message(L("密码库已锁定或切换，此操作已取消。"))
    }
}
