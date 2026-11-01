import Foundation
import CoreFoundation

/// Owns file-reference resolution for 1PUX. Metadata never selects a filesystem path.
/// Supported producers: documentAttributes and sections[].fields[].value.file.
struct OnePasswordFileInventory {
    private let files: [String: Data]
    private var consumed: Set<String> = []
    private(set) var blobs: [String: Data] = [:]
    init(members: [String: Data]) { files = members.filter { $0.key.hasPrefix("files/") && $0.key != "files/" } }

    mutating func resolve(_ record: [String: Any], source: String) throws -> (details: [String: Any], attachments: [VaultAttachment]) {
        guard var details = record["details"] as? [String: Any] else { throw invalid() }
        try OnePasswordImporter.validateArrays(details, keys: ["sections"])
        var attachments: [VaultAttachment] = []
        if let document = details.removeValue(forKey: "documentAttributes"), !(document is NSNull) {
            attachments.append(try resolveFile(document, source: source))
        }
        if let sections = details["sections"] as? [[String: Any]] {
            details["sections"] = try sections.map { original -> [String: Any] in
                var section = original
                try OnePasswordImporter.validateArrays(section, keys: ["fields"])
                if let fields = section["fields"] as? [[String: Any]] {
                    section["fields"] = try fields.filter { field in
                        guard let value = field["value"] as? [String: Any], let file = value["file"] else { return true }
                        guard value.count == 1 else { throw invalid() }
                        attachments.append(try resolveFile(file, source: source))
                        return false
                    }
                }
                return section
            }
        }
        var cleaned = record; cleaned["details"] = details
        guard !OnePasswordImporter.containsAttachments(cleaned) else { throw VaultError.message(L("1PUX 含未识别的附件结构，整批未导入。请保留完整导出。")) }
        // One document may be referenced repeatedly by fields in the same item.
        var unique: [VaultAttachment] = []
        for attachment in attachments {
            if let prior = unique.first(where: { $0.id == attachment.id }) {
                guard prior == attachment else { throw invalid() }
            } else { unique.append(attachment) }
        }
        return (details, unique)
    }

    private mutating func resolveFile(_ value: Any, source: String) throws -> VaultAttachment {
        guard let metadata = value as? [String: Any], let id = metadata["documentId"] as? String,
              !id.isEmpty, id.utf8.count <= 128, id.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }),
              let name = metadata["fileName"] as? String, AttachmentStore.validName(name),
              let size = metadata["decryptedSize"] as? NSNumber, CFGetTypeID(size) != CFBooleanGetTypeID(),
              size.doubleValue >= 0, size.doubleValue <= Double(AttachmentStore.maximumAttachmentBytes),
              size.doubleValue == Double(size.intValue) else { throw invalid() }
        let path = "files/\(id)___\(name)"
        guard let bytes = files[path], bytes.count == size.intValue else { throw VaultError.message(L("1PUX 附件缺失、名称不匹配或长度不符，整批未导入。")) }
        let attachment = VaultAttachment(id: OnePasswordImporter.stableID(source + ":attachment:" + id), name: name, data: bytes)
        blobs[attachment.blobID] = bytes; consumed.insert(path)
        return attachment
    }
    func requireComplete() throws {
        guard consumed == Set(files.keys) else { throw VaultError.message(L("1PUX 有未关联的文件或尚未支持的自定义图标，整批未导入。请保留完整导出。")) }
    }
    private func invalid() -> VaultError { .message(L("1PUX 附件元数据无效或超出 16 MiB 限制，整批未导入。")) }
}
