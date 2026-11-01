import Foundation
import CoreFoundation

struct AgileAttachmentInventory {
    private let files: [String: Data]
    private let byOwner: [String: [(path: String, id: String, base: String)]]
    private var consumed: Set<String> = []
    private(set) var blobs: [String: Data] = [:]
    init(files: [String: Data]) {
        self.files = files.filter { $0.key.hasPrefix("a/default/files/") && $0.key.split(separator: "/").last != ".DS_Store" }
        var owners: [String: [(path: String, id: String, base: String)]] = [:]
        for path in self.files.keys.sorted() where path.hasSuffix(".def") {
            let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            if parts.count == 5 { owners[parts[3], default: []].append((path, String(parts[4].dropLast(4)), String(path.dropLast(4)))) }
        }
        byOwner = owners
    }
    mutating func resolve(owner: String, source: String, keys: [String: Data]) throws -> (attachments: [VaultAttachment], metadata: [[String: Any]]) {
        var attachments: [VaultAttachment] = [], metadata: [[String: Any]] = []
        for entry in byOwner[owner] ?? [] {
            let path = entry.path, id = entry.id, base = entry.base
            guard !id.isEmpty, id.utf8.count <= 32, id.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) }),
                  var definition = try JSONSerialization.jsonObject(with: files[path]!) as? [String: Any],
                  let name = definition["filename"] as? String, AttachmentStore.validName(name),
                  let encrypted = definition["encrypted"] as? NSNumber, CFGetTypeID(encrypted) == CFBooleanGetTypeID(), encrypted.boolValue,
                  let keyID = definition["encryptionKey"] as? String, let key = keys[keyID],
                  let checksum = definition["contentsHash"] as? String, !checksum.isEmpty, checksum.utf8.count <= 8,
                  let expected = UInt32(checksum, radix: 16), let ciphertext = files[base] else { throw invalid() }
            let bytes = try AgileKeychainCrypto.open(ciphertext, key: key)
            guard bytes.count <= AttachmentStore.maximumAttachmentBytes, CRC32.checksum(bytes) == expected else { throw invalid() }
            if let icon = files[base + ".icn"] {
                let decoded = try AgileKeychainCrypto.open(icon, key: key)
                guard decoded.count <= AttachmentStore.maximumAttachmentBytes else { throw invalid() }
                definition["iconBase64"] = decoded.base64EncodedString(); consumed.insert(base + ".icn")
            }
            definition["sourceAttachmentID"] = id
            let attachment = VaultAttachment(id: OnePasswordImporter.stableID(source + ":attachment:" + id), name: name, data: bytes)
            attachments.append(attachment); metadata.append(definition); blobs[attachment.blobID] = bytes
            consumed.insert(path); consumed.insert(base)
        }
        return (attachments, metadata)
    }
    func requireComplete() throws {
        guard consumed == Set(files.keys) else { throw VaultError.message("AgileKeychain 包含未关联的附件、缺失定义或未知附件文件；整批未导入。") }
    }
    private func invalid() -> VaultError { .message("AgileKeychain 附件定义、密钥、长度或 CRC32 损坏检查失败；整批未导入。") }
}
