import Foundation
import CryptoKit
import Darwin

/// Owns only a private per-vault directory. Names contain no item data or paths.
struct BackupStore {
    let directory: URL
    let vaultID: UUID
    // Retain the established location so renaming never hides existing recovery points.
    static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalVault/Backups", isDirectory: true)
    }
    init(vaultID: UUID, root: URL?) {
        self.vaultID = vaultID
        directory = (root ?? Self.defaultRoot).appendingPathComponent(vaultID.uuidString, isDirectory: true)
    }
    func prepare() throws {
        // Fail closed for symlinked owned roots; never broaden directory modes.
        let root = directory.deletingLastPathComponent()
        for path in [root, directory] {
            var info = stat()
            if lstat(path.path, &info) == 0 {
                guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid(), (info.st_mode & 0o077) == 0 else {
                    throw VaultError.message("自动备份目录必须是本人拥有的私有普通目录（0700），不能是链接。")
                }
            } else {
                guard errno == ENOENT else { throw VaultError.message("无法检查自动备份目录。") }
                try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                guard lstat(path.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid(), (info.st_mode & 0o077) == 0 else {
                    throw VaultError.message("自动备份目录权限验证失败。")
                }
            }
        }
    }
    func keyTag(_ salt: Data) -> String { SHA256.hash(data: salt).prefix(6).map { String(format: "%02x", $0) }.joined() }
    func list(currentSalt: Data) throws -> [VaultBackup] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        try prepare()
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .compactMap { url in
                let fields = url.deletingPathExtension().lastPathComponent.components(separatedBy: "_")
                guard url.pathExtension == "localvault", fields.count == 5,
                      let milliseconds = Double(fields[0]), milliseconds.isFinite,
                      let version = Int(fields[1]), [1, 2, 3].contains(version),
                      fields[2].count == 12, fields[2].allSatisfy({ $0.isHexDigit }),
                      ["pre-save", "before-password-change", "upgrade-v1", "upgrade-v2"].contains(fields[3]), UUID(uuidString: fields[4]) != nil else { return nil }
                var info = stat()
                guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid() else { return nil }
                return VaultBackup(url: url, createdAt: Date(timeIntervalSince1970: milliseconds / 1000), reason: fields[3], usesCurrentPassword: fields[2] == keyTag(currentSalt), formatVersion: version)
            }.sorted { $0.createdAt > $1.createdAt }
    }
    /// Verifies identity and decryption before and after publication. The caller
    /// decides whether failure blocks a mutation or warns after a committed save.
    func preserve(_ bytes: Data, envelope: VaultEnvelope, key: SymmetricKey, reason: String) throws {
        do {
            try prepare()
            let decoded = try VaultCrypto.document(from: bytes, key: key)
            guard decoded.id == vaultID else { throw VaultError.message("自动备份密码库身份不一致。") }
            // A successful prior post-save copy is exactly the next pre-save
            // copy. Authenticate it before reusing this recovery point.
            if reason == "pre-save", let latest = try list(currentSalt: envelope.salt).first(where: { $0.usesCurrentPassword && $0.reason == "pre-save" }) {
                let existing = try BoundedFileReader.read(latest.url, maximumBytes: VaultCrypto.maximumFileSize)
                if existing == bytes, try VaultCrypto.document(from: existing, key: key).id == vaultID { return }
            }
            let stamp = String(format: "%.3f", Date().timeIntervalSince1970 * 1000)
            let name = "\(stamp)_\(envelope.version)_\(keyTag(envelope.salt))_\(reason)_\(UUID().uuidString).localvault"
            let destination = directory.appendingPathComponent(name)
            try VaultFile.publish(bytes, to: destination, replacingExisting: false)
            let stored = try BoundedFileReader.read(destination, maximumBytes: VaultCrypto.maximumFileSize)
            guard stored == bytes else { throw VaultError.message("自动备份字节验证失败。") }
            let verified = try VaultCrypto.document(from: stored, key: key)
            guard verified.id == vaultID else { throw VaultError.message("自动备份密码库身份不一致。") }
        } catch {
            throw VaultError.message("自动加密备份未完成。\(error.localizedDescription)\n备份目录：\(directory.path)")
        }
    }
    /// Pruning is after the main commit. Cleanup failure is a warning, never a
    /// false save failure. Only authenticated, current-key, same-vault files may
    /// be deleted; pins and backups from other password epochs are retained.
    func prune(currentSalt: Data, key: SymmetricKey) -> String? {
        do {
            let candidates = try list(currentSalt: currentSalt).filter { $0.usesCurrentPassword && $0.reason == "pre-save" }
            guard candidates.count > 20 else { return nil }
            var verified: [VaultBackup] = []
            for candidate in candidates {
                let bytes = try BoundedFileReader.read(candidate.url, maximumBytes: VaultCrypto.maximumFileSize)
                let envelope = try VaultCrypto.envelope(from: bytes)
                guard envelope.salt == currentSalt, try VaultCrypto.document(from: bytes, key: key).id == vaultID else { continue }
                verified.append(candidate)
            }
            for old in verified.dropFirst(20) { try FileManager.default.removeItem(at: old.url) }
            return nil
        } catch { return "密码库已保存；旧备份清理未完成，备份仍保留。\(error.localizedDescription)" }
    }
}
