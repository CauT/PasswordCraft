import Foundation
import CryptoKit

public struct VaultAttachment: Codable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var mediaType: String
    public var byteCount: Int
    public var blobID: String
    public init(id: UUID = UUID(), name: String, mediaType: String = "application/octet-stream", data: Data) {
        self.id = id; self.name = name; self.mediaType = mediaType; byteCount = data.count
        blobID = AttachmentStore.identity(data)
    }
}

/// Content addresses belong to this store. History retains references, not copies.
public enum AttachmentStore {
    public static let maximumAttachmentBytes = 16 * 1024 * 1024
    public static func identity(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func validName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 1024 &&
        !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) &&
        !name.contains("/") && !name.contains("\\") && ![".", ".."].contains(name)
    }
    public static func validate(items: [VaultItem], revisions: [VaultRevision], blobs: [String: Data]) throws {
        var used: Set<String> = []
        for item in items + revisions.map(\.snapshot) {
            guard Set(item.attachments.map(\.id)).count == item.attachments.count else { throw VaultError.message("同一项目含重复附件标识。") }
            for attachment in item.attachments {
                guard validName(attachment.name),
                      !attachment.mediaType.isEmpty, attachment.mediaType.utf8.count <= 256,
                      let bytes = blobs[attachment.blobID], bytes.count == attachment.byteCount,
                      bytes.count <= maximumAttachmentBytes else { throw VaultError.message("附件名称、类型、大小或内容引用无效，未保存。") }
                used.insert(attachment.blobID)
            }
        }
        guard used == Set(blobs.keys) else { throw VaultError.message("附件内容与项目或历史引用不一致。") }
        for (id, bytes) in blobs {
            guard id == identity(bytes) else { throw VaultError.message("附件内容校验失败。") }
        }
    }
    public static func referenced(items: [VaultItem], revisions: [VaultRevision], in blobs: [String: Data]) -> [String: Data] {
        let used = Set((items + revisions.map(\.snapshot)).flatMap(\.attachments).map(\.blobID))
        return blobs.filter { used.contains($0.key) }
    }
    public static func merging(_ added: [String: Data], into existing: [String: Data]) throws -> [String: Data] {
        var result = existing
        for (id, bytes) in added {
            guard bytes.count <= maximumAttachmentBytes, identity(bytes) == id,
                  result[id] == nil || result[id] == bytes else { throw VaultError.message("附件内容标识冲突或校验失败。") }
            result[id] = bytes
        }
        return result
    }
}
