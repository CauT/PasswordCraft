import Foundation
import CryptoKit
import CommonCrypto
import Security
import Darwin

public enum VaultError: Error, LocalizedError {
    case message(String)
    public var errorDescription: String? { if case let .message(message) = self { return message }; return nil }
}

struct VaultEnvelope: Codable {
    let version: Int
    let cipher: String
    let kdf: String
    let rounds: UInt32
    let salt: Data
    let sealed: Data
    // Persisted format identifier, retained across the PasswordCraft rename.
    var authenticatedHeader: Data { Data("LocalVault|\(version)|\(cipher)|\(kdf)|\(rounds)|\(salt.base64EncodedString())".utf8) }
    func validate() throws {
        guard [1, 2, 3].contains(version), cipher == "AES-256-GCM", kdf == "PBKDF2-HMAC-SHA256", rounds == 600_000, salt.count == 16, sealed.count >= 28 else {
            throw VaultError.message("不支持的密码库格式或损坏的文件。")
        }
    }
}

public final class VaultSession {
    // Existing files and backups retain their extension; branding is independent.
    public static let fileExtension = "localvault"
    public let fileURL: URL
    private var document: VaultDocument
    public var items: [VaultItem] { document.items }
    public var allRevisions: [VaultRevision] { document.revisions }
    public var transferDocument: VaultTransferDocument { VaultTransferDocument(items: items, revisions: allRevisions, blobs: document.blobs) }
    public var vaultID: UUID { document.id }
    public var backupDirectory: URL { backupStore.directory }
    public private(set) var lastWarning: String?
    private var key: SymmetricKey?
    private var salt: Data
    private var fingerprint: Data
    private var formatVersion: Int
    private let backupStore: BackupStore
    public var isUnlocked: Bool { key != nil }
    private init(url: URL, document: VaultDocument, key: SymmetricKey, salt: Data, fingerprint: Data, formatVersion: Int, backupRoot: URL?) {
        self.fileURL = url; self.document = document; self.key = key; self.salt = salt
        self.fingerprint = fingerprint; self.formatVersion = formatVersion
        self.backupStore = BackupStore(vaultID: document.id, root: backupRoot)
    }
    public static func create(at url: URL, password: String, backupRoot: URL? = nil) throws -> VaultSession {
        try VaultCrypto.validatePassword(password)
        let salt = try VaultCrypto.randomBytes(count: 16)
        let key = try VaultCrypto.derive(password: password, salt: salt)
        let document = VaultDocument()
        let bytes = try VaultCrypto.seal(document: document, key: key, salt: salt)
        try VaultFile.withLock(url) { try VaultFile.publish(bytes, to: url, replacingExisting: false) }
        return VaultSession(url: url, document: document, key: key, salt: salt, fingerprint: VaultCrypto.digest(bytes), formatVersion: 3, backupRoot: backupRoot)
    }
    public static func open(at url: URL, password: String, backupRoot: URL? = nil) throws -> VaultSession {
        let bytes = try BoundedFileReader.read(url, maximumBytes: VaultCrypto.maximumFileSize)
        let envelope = try VaultCrypto.envelope(from: bytes)
        let key = try VaultCrypto.derive(password: password, salt: envelope.salt)
        let document = try VaultCrypto.document(from: bytes, key: key)
        try validate(document)
        return VaultSession(url: url, document: document, key: key, salt: envelope.salt, fingerprint: VaultCrypto.digest(bytes), formatVersion: envelope.version, backupRoot: backupRoot)
    }
    /// Secret key material: only store in a biometric-protected, device-only Keychain item.
    /// This is not a password substitute suitable for preferences, logs, or export files.
    public func deviceUnlockMaterial() throws -> Data {
        guard let key, formatVersion >= 2 else { throw VaultError.message("请先用主密码解锁并保存为当前格式，再启用 Touch ID。") }
        return try JSONEncoder().encode(DeviceUnlockMaterial(version: 1, vaultID: vaultID, salt: salt, key: key.withUnsafeBytes { Data($0) }))
    }
    public static func open(at url: URL, deviceUnlockMaterial bytes: Data, backupRoot: URL? = nil) throws -> VaultSession {
        guard bytes.count <= 1024, let material = try? JSONDecoder().decode(DeviceUnlockMaterial.self, from: bytes),
              material.version == 1, material.key.count == 32, material.salt.count == 16 else {
            throw VaultError.message("设备解锁记录无效，请使用主密码。")
        }
        let file = try BoundedFileReader.read(url, maximumBytes: VaultCrypto.maximumFileSize)
        let envelope = try VaultCrypto.envelope(from: file)
        guard envelope.version >= 2, material.salt == envelope.salt else { throw VaultError.message("密码库或主密码已更改，请使用主密码并重新启用 Touch ID。") }
        let key = SymmetricKey(data: material.key)
        let document = try VaultCrypto.document(from: file, key: key)
        guard document.id == material.vaultID else { throw VaultError.message("设备解锁记录不属于此密码库。") }
        try validate(document)
        return VaultSession(url: url, document: document, key: key, salt: envelope.salt, fingerprint: VaultCrypto.digest(file), formatVersion: envelope.version, backupRoot: backupRoot)
    }
    public func revisions(for itemID: UUID) -> [VaultRevision] {
        document.revisions.filter { $0.itemID == itemID }.sorted { $0.createdAt > $1.createdAt }
    }
    public func availableBackups() throws -> [VaultBackup] {
        guard isUnlocked else { throw VaultError.message("密码库已锁定。") }
        return try backupStore.list(currentSalt: salt)
    }
    public func save(items updated: [VaultItem], importedRevisions: [VaultRevision] = [], importedBlobs: [String: Data] = [:]) throws {
        guard let key else { throw VaultError.message("密码库已锁定。") }
        guard Set(document.items.map(\.id)).isSubset(of: Set(updated.map(\.id))) else {
            throw VaultError.message("不能通过保存直接删除项目。请先移入回收站，再明确永久删除。")
        }
        var next = document
        next.items = updated
        var knownRevisions = Dictionary(uniqueKeysWithValues: document.revisions.map { ($0.id, $0) })
        for revision in importedRevisions {
            if let previous = knownRevisions[revision.id], previous != revision {
                throw VaultError.message("导入的历史版本标识冲突，未更改密码库。")
            }
            if knownRevisions[revision.id] == nil { next.revisions.append(revision); knownRevisions[revision.id] = revision }
        }
        let previousItems = Dictionary(uniqueKeysWithValues: document.items.map { ($0.id, $0) })
        for item in updated {
            if let old = previousItems[item.id], old != item {
                next.revisions.append(VaultRevision(snapshot: old))
            }
        }
        let mergedBlobs = try AttachmentStore.merging(importedBlobs, into: document.blobs)
        next.blobs = AttachmentStore.referenced(items: next.items, revisions: next.revisions, in: mergedBlobs)
        try Self.validate(next)
        guard next.items != document.items || next.revisions != document.revisions || formatVersion < 3 else { return }
        try commit(next, key: key, salt: salt, reason: "pre-save")
    }
    /// Restores content while keeping the item's current trash/archive status.
    public func restoreRevision(itemID: UUID, revisionID: UUID) throws {
        guard let current = items.first(where: { $0.id == itemID }), let revision = document.revisions.first(where: { $0.id == revisionID && $0.itemID == itemID }) else {
            throw VaultError.message("找不到项目或所选历史版本。")
        }
        var restored = revision.snapshot
        restored.state = current.state; restored.deletedAt = current.deletedAt; restored.updatedAt = Date()
        var updated = items
        updated[updated.firstIndex(where: { $0.id == itemID })!] = restored
        try save(items: updated)
    }
    public func purge(itemID: UUID) throws {
        guard let key else { throw VaultError.message("密码库已锁定。") }
        guard let item = items.first(where: { $0.id == itemID }), item.state == .trashed else {
            throw VaultError.message("只能永久删除回收站内的项目。")
        }
        var next = document
        next.items.removeAll { $0.id == itemID }; next.revisions.removeAll { $0.itemID == itemID }
        next.blobs = AttachmentStore.referenced(items: next.items, revisions: next.revisions, in: next.blobs)
        try commit(next, key: key, salt: salt, reason: "pre-save")
    }
    public func changePassword(_ password: String) throws {
        guard isUnlocked else { throw VaultError.message("密码库已锁定。") }
        try VaultCrypto.validatePassword(password)
        let newSalt = try VaultCrypto.randomBytes(count: 16)
        let newKey = try VaultCrypto.derive(password: password, salt: newSalt)
        try commit(document, key: newKey, salt: newSalt, reason: "before-password-change")
    }
    public func backup(to destination: URL) throws {
        guard isUnlocked else { throw VaultError.message("密码库已锁定。") }
        try VaultFile.withLock(fileURL) {
            let bytes = try unchangedBytes()
            try VaultFile.publish(bytes, to: destination, replacingExisting: false)
        }
    }
    public func recoverBackup(_ backupURL: URL, to destination: URL, password: String) throws {
        guard isUnlocked else { throw VaultError.message("密码库已锁定。") }
        guard backupURL.deletingLastPathComponent().standardizedFileURL == backupDirectory.standardizedFileURL,
              try availableBackups().contains(where: { $0.url == backupURL }) else {
            throw VaultError.message("所选文件不属于此密码库的自动备份。")
        }
        let bytes = try BoundedFileReader.read(backupURL, maximumBytes: VaultCrypto.maximumFileSize)
        let envelope = try VaultCrypto.envelope(from: bytes)
        let backupKey = try VaultCrypto.derive(password: password, salt: envelope.salt)
        let recovered = try VaultCrypto.document(from: bytes, key: backupKey)
        guard recovered.id == document.id else { throw VaultError.message("备份身份与当前密码库不一致。") }
        try Self.validate(recovered)
        try VaultFile.publish(bytes, to: destination, replacingExisting: false)
    }
    public func lock() {
        key = nil
        document = VaultDocument(id: document.id)
    }
    public func addAttachment(itemID: UUID, name: String, mediaType: String, data: Data) throws {
        guard isUnlocked, let index = items.firstIndex(where: { $0.id == itemID }), items[index].state != .trashed,
              data.count <= AttachmentStore.maximumAttachmentBytes else { throw VaultError.message("无法添加附件：请先解锁并恢复项目，单个附件最多 16 MiB。") }
        var next = items
        let attachment = VaultAttachment(name: name, mediaType: mediaType, data: data)
        next[index].attachments.append(attachment); next[index].updatedAt = Date()
        try save(items: next, importedBlobs: [attachment.blobID: data])
    }
    public func removeAttachment(itemID: UUID, attachmentID: UUID) throws {
        guard isUnlocked, let index = items.firstIndex(where: { $0.id == itemID }), items[index].state != .trashed,
              items[index].attachments.contains(where: { $0.id == attachmentID }) else { throw VaultError.message("找不到可移除的附件，请重新打开项目。") }
        var next = items
        next[index].attachments.removeAll { $0.id == attachmentID }; next[index].updatedAt = Date()
        try save(items: next)
    }
    public func attachmentData(itemID: UUID, attachmentID: UUID, revisionID: UUID? = nil) throws -> Data {
        guard isUnlocked else { throw VaultError.message("密码库已锁定。") }
        let item: VaultItem?
        if let revisionID { item = allRevisions.first(where: { $0.id == revisionID && $0.itemID == itemID })?.snapshot }
        else { item = items.first { $0.id == itemID } }
        guard let attachment = item?.attachments.first(where: { $0.id == attachmentID }), let bytes = document.blobs[attachment.blobID] else { throw VaultError.message("找不到附件或所选历史版本。") }
        return bytes
    }
    public func exportAttachment(itemID: UUID, attachmentID: UUID, revisionID: UUID? = nil, to destination: URL) throws {
        try PlaintextExportWriter.write(attachmentData(itemID: itemID, attachmentID: attachmentID, revisionID: revisionID), to: destination)
    }
    private func commit(_ next: VaultDocument, key newKey: SymmetricKey, salt newSalt: Data, reason: String) throws {
        guard let currentKey = key else { throw VaultError.message("密码库已锁定。") }
        try Self.validate(next)
        let bytes = try VaultCrypto.seal(document: next, key: newKey, salt: newSalt)
        try VaultFile.withLock(fileURL) {
            let oldBytes = try unchangedBytes()
            let oldEnvelope = try VaultCrypto.envelope(from: oldBytes)
            do { try backupStore.preserve(oldBytes, envelope: oldEnvelope, key: currentKey, reason: formatVersion < 3 ? "upgrade-v\(formatVersion)" : reason) }
            catch { throw VaultError.message("原密码库未更改。\(error.localizedDescription)") }
            try VaultFile.publish(bytes, to: fileURL, replacingExisting: true)
        }
        document = next; key = newKey; salt = newSalt; fingerprint = VaultCrypto.digest(bytes); formatVersion = 3
        lastWarning = nil
        do {
            let envelope = try VaultCrypto.envelope(from: bytes)
            try backupStore.preserve(bytes, envelope: envelope, key: newKey, reason: "pre-save")
        } catch {
            lastWarning = "修改已保存，但最新状态自动备份失败；修改前恢复点保留，请手动备份。\(error.localizedDescription)"
            return // Never prune the recovery point when the newest copy failed.
        }
        lastWarning = backupStore.prune(currentSalt: newSalt, key: newKey)
    }
    func verifyUnchanged() throws {
        guard isUnlocked else { throw VaultError.message("密码库已锁定。") }; _ = try unchangedBytes()
    }
    private func unchangedBytes() throws -> Data {
        let bytes = try BoundedFileReader.read(fileURL, maximumBytes: VaultCrypto.maximumFileSize)
        guard VaultCrypto.digest(bytes) == fingerprint else {
            throw VaultError.message("密码库已被其他程序修改。请重新打开后再编辑，避免覆盖新内容。")
        }
        return bytes
    }
    private static func validate(_ document: VaultDocument) throws {
        guard document.schemaVersion == 3 else { throw VaultError.message("不支持的密码库数据版本。") }
        try VaultTransferDocument(items: document.items, revisions: document.revisions, blobs: document.blobs).validate()
    }
}

private struct DeviceUnlockMaterial: Codable {
    let version: Int
    let vaultID: UUID
    let salt: Data
    let key: Data
}

enum VaultCrypto {
    static let maximumFileSize = 64 * 1024 * 1024
    static func envelope(from bytes: Data) throws -> VaultEnvelope {
        do { let value = try JSONDecoder().decode(VaultEnvelope.self, from: bytes); try value.validate(); return value }
        catch let error as VaultError { throw error }
        catch { throw VaultError.message("无法识别密码库文件。") }
    }
    static func document(from bytes: Data, key: SymmetricKey) throws -> VaultDocument {
        let envelope = try envelope(from: bytes)
        let plaintext: Data
        do { plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: envelope.sealed), using: key, authenticating: envelope.authenticatedHeader) }
        catch { throw VaultError.message("主密码不正确，或密码库已损坏。") }
        if envelope.version == 1 {
            let items = try JSONDecoder().decode([VaultItem].self, from: plaintext)
            var identity = Array(SHA256.hash(data: bytes).prefix(16))
            identity[6] = (identity[6] & 0x0f) | 0x50; identity[8] = (identity[8] & 0x3f) | 0x80
            let id = identity.withUnsafeBytes { UUID(uuid: $0.load(as: uuid_t.self)) }
            return VaultDocument(id: id, items: items)
        }
        return try JSONDecoder().decode(VaultDocument.self, from: plaintext)
    }
    static func seal(document: VaultDocument, key: SymmetricKey, salt: Data) throws -> Data {
        let plaintext = try JSONEncoder().encode(document)
        guard plaintext.count < maximumFileSize / 2 else { throw VaultError.message("密码库及历史超过本版本的 32 MiB 内容限制。请先导出并备份，再清理不需要的项目。") }
        let header = VaultEnvelope(version: 3, cipher: "AES-256-GCM", kdf: "PBKDF2-HMAC-SHA256", rounds: 600_000, salt: salt, sealed: Data())
        let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: header.authenticatedHeader)
        guard let combined = sealed.combined else { throw VaultError.message("加密失败。") }
        return try JSONEncoder().encode(VaultEnvelope(version: header.version, cipher: header.cipher, kdf: header.kdf, rounds: header.rounds, salt: salt, sealed: combined))
    }
    static func validatePassword(_ password: String) throws {
        guard password.count >= 12, password.utf8.count <= 4096 else { throw VaultError.message("主密码至少需要 12 个字符，最多 4096 字节。请使用独一无二的长密码。") }
    }
    static func derive(password: String, salt: Data) throws -> SymmetricKey {
        guard password.utf8.count <= 4096 else { throw VaultError.message("主密码过长。") }
        var output = [UInt8](repeating: 0, count: 32)
        defer { output.withUnsafeMutableBytes { buffer in if let address = buffer.baseAddress { memset_s(address, buffer.count, 0, buffer.count) } } }
        let result = password.withCString { pointer in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pointer, password.utf8.count,
                    saltBytes.bindMemory(to: UInt8.self).baseAddress!, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 600_000, &output, output.count)
            }
        }
        guard result == kCCSuccess else { throw VaultError.message("密钥派生失败。") }
        return SymmetricKey(data: output)
    }
    static func randomBytes(count: Int) throws -> Data {
        var data = Data(count: count)
        let result = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        guard result == errSecSuccess else { throw VaultError.message("系统随机数生成失败。") }
        return data
    }
    static func digest(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
}

enum VaultFile {
    static func withLock<T>(_ url: URL, action: () throws -> T) throws -> T {
        // A user-selected file does not grant access to existing sibling files.
        // Use one private per-user namespace shared by this app and CLI processes.
        // Keep empty lock files for the login session: unlinking a held lock would
        // allow a second inode to split the lock. No vault content is stored here.
        // Share the established lock namespace with the preceding version.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LocalVault-WriteLocks-v1", isDirectory: true)
        if mkdir(directory.path, S_IRWXU) != 0 && errno != EEXIST { throw VaultError.message("无法创建本地写入锁目录。") }
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw VaultError.message("本地写入锁目录的归属或权限不安全。") }
        let pathKey = AttachmentStore.identity(Data(url.standardizedFileURL.resolvingSymlinksInPath().path.utf8))
        let lockURL = directory.appendingPathComponent(pathKey)
        let fd = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw VaultError.message("无法锁定密码库文件，请检查目录写入权限。") }
        defer { Darwin.close(fd) }
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1,
              info.st_mode & 0o077 == 0 else { throw VaultError.message("本地写入锁文件的归属或权限不安全。") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw VaultError.message("密码库正在被另一个窗口保存，请稍后重试。") }
        defer { flock(fd, LOCK_UN) }
        return try action()
    }
    static func publish(_ data: Data, to url: URL, replacingExisting: Bool) throws {
        // The system supplies a temporary directory on the destination volume;
        // saving a selected file must not require opening its protected parent.
        // Pass the existing parent as a volume hint: on macOS a nonexistent hint
        // can be materialized as a placeholder, violating exclusive creation.
        var parentInfo = stat()
        guard stat(url.deletingLastPathComponent().path, &parentInfo) == 0, parentInfo.st_mode & S_IFMT == S_IFDIR else {
            throw VaultError.message("目标目录不存在或不可访问，未创建密码库。")
        }
        let temporary = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url.deletingLastPathComponent(), create: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let staging = temporary.appendingPathComponent("encrypted-vault.tmp")
        let fd = Darwin.open(staging.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw VaultError.message("无法创建临时文件，请检查目录写入权限。") }
        defer { Darwin.close(fd); unlink(staging.path) }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw VaultError.message("写入失败，请检查剩余磁盘空间。") }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw VaultError.message("文件同步失败，保存未完成。") }
        guard renamex_np(staging.path, url.path, replacingExisting ? UInt32(0) : UInt32(RENAME_EXCL)) == 0 else {
            let detail = NSError(domain: NSPOSIXErrorDomain, code: Int(errno)).localizedDescription
            throw VaultError.message((replacingExisting ? "保存失败，原密码库保持不变。" : "无法创建文件：目标已存在，或文件系统不支持安全创建。") + detail)
        }
        // Do not read protected parent directories solely for metadata fsync.
        // File bytes are synced; sudden-power-loss directory durability is not promised.
    }
}

public enum PasswordGenerator {
    public static func generate(length: Int = 24) throws -> String {
        guard (12...128).contains(length) else { throw VaultError.message("密码长度应为 12–128。") }
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!@#$%*-_=+?".utf8)
        let ceiling = 256 - (256 % alphabet.count)
        var output = [UInt8]()
        while output.count < length {
            var byte: UInt8 = 0
            guard SecRandomCopyBytes(kSecRandomDefault, 1, &byte) == errSecSuccess else { throw VaultError.message("系统随机数生成失败。") }
            if Int(byte) < ceiling { output.append(alphabet[Int(byte) % alphabet.count]) }
        }
        return String(decoding: output, as: UTF8.self)
    }
}


/// Shared bounded, no-follow reader for all externally supplied vault/import files.
internal enum BoundedFileReader {
    static func read(_ url: URL, maximumBytes: Int) throws -> Data {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw VaultError.message("无法读取文件（链接文件不受支持）。") }
        defer { Darwin.close(fd) }
        return try read(descriptor: fd, maximumBytes: maximumBytes)
    }
    static func read(descriptor fd: Int32, maximumBytes: Int) throws -> Data {
        var info = Darwin.stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= 0, info.st_size <= maximumBytes else {
            throw VaultError.message("所选文件不是普通文件或超过大小限制。")
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0, errno == EINTR { continue }
            guard count > 0, data.count + count <= maximumBytes else { throw VaultError.message("读取失败或文件超过大小限制。") }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}
