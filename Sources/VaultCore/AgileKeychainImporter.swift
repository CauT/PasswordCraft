import Foundation

public enum LegacyVaultFormat: String {
    case opvault, agilekeychain
    public init?(url: URL) { self.init(rawValue: url.pathExtension.lowercased()) }
    public var title: String { self == .opvault ? "OPVault" : "AgileKeychain" }
    public func read(from url: URL, password: String) throws -> VaultImportPreview {
        switch self {
        case .opvault: return try OPVaultImporter.read(from: url, password: password)
        case .agilekeychain: return try AgileKeychainImporter.read(from: url, password: password)
        }
    }
}

public enum AgileKeychainImporter {
    public static func read(from url: URL, password: String) throws -> VaultImportPreview {
        let files = try ReadOnlyPackage(url).snapshotTree(maximumFileBytes: 32 * 1024 * 1024, maximumTotalBytes: 64 * 1024 * 1024)
        let prefix = "data/default/"
        let ancillary: Set<String> = ["1Password.html", "config/buildnum", "config/use-thumbnails", "config/newsletter", prefix + "1password.keys", prefix + ".1password.keys", prefix + ".password.hint"]
        var itemFiles: [String: Data] = [:], skippedResources = false
        for (path, data) in files {
            if path == prefix + "contents.js" || path == prefix + "encryptionKeys.js" || path.hasPrefix("a/default/files/") { continue }
            if path.hasPrefix(prefix), path.hasSuffix(".1password") {
                let id = String(path.dropFirst(prefix.count).dropLast(".1password".count))
                guard validID(id), itemFiles.updateValue(data, forKey: id) == nil else { throw invalid("条目文件名无效或重复。") }
            } else if ancillary.contains(path) || path.split(separator: "/").last == ".DS_Store" { continue }
            else if path.hasPrefix("style/") || path.hasPrefix("a/default/thumb/") { skippedResources = true }
            else { throw invalid("包含尚未支持的附件、额外配置或未知文件；不会跳过这些数据。") }
        }
        guard let keyBytes = files[prefix + "encryptionKeys.js"], let indexBytes = files[prefix + "contents.js"] else { throw invalid("缺少密钥或项目清单。") }
        let keyFile = try object(keyBytes)
        guard let definitions = keyFile["list"] as? [[String: Any]], !definitions.isEmpty,
              let primaryID = keyFile["SL5"] as? String, validID(primaryID),
              let index = try JSONSerialization.jsonObject(with: indexBytes) as? [[Any]] else { throw invalid("密钥或清单结构无效。") }
        var recordsByKey: [String: [String: Any]] = [:], rounds = 0
        for definition in definitions {
            guard let id = definition["identifier"] as? String, validID(id), recordsByKey[id] == nil else { throw invalid("密钥标识无效或重复。") }
            rounds += try AgileKeychainCrypto.iterations(definition["iterations"])
            guard rounds <= 10_000_000 else { throw invalid("总密钥派生量超过读取预算。") }
            recordsByKey[id] = definition
        }
        guard recordsByKey[primaryID] != nil else { throw invalid("主安全级别没有对应密钥。") }
        var keys: [String: Data] = [:]
        for id in recordsByKey.keys.sorted() { keys[id] = try AgileKeychainCrypto.unlock(recordsByKey[id]!, password: password) }
        var indexByID: [String: [Any]] = [:]
        for row in index {
            guard row.count >= 8, let id = row[0] as? String, validID(id), row[1] is String, row[2] is String,
                  let trashed = row[7] as? String, ["Y", "N"].contains(trashed), indexByID[id] == nil else { throw invalid("项目清单条目无效或重复。") }
            indexByID[id] = row
        }
        guard Set(indexByID.keys) == Set(itemFiles.keys) else { throw invalid("项目清单与实际文件不一致，请使用完整且停止同步的旧库副本。") }
        var decoded: [String: [String: Any]] = [:]
        for id in itemFiles.keys.sorted() {
            var record = try object(itemFiles[id]!)
            guard record["uuid"] as? String == id, record["title"] is String, let type = record["typeName"] as? String else { throw invalid("条目标识或基本字段无效。") }
            let open = record["openContents"] as? [String: Any] ?? [:]
            let keyID: String
            if let selected = record["keyID"] {
                guard let selected = selected as? String else { throw invalid("条目密钥标识无效。") }; keyID = selected
            } else {
                let level = record["securityLevel"] ?? open["securityLevel"] ?? "SL5"
                guard let level = level as? String, let selected = keyFile[level] as? String else { throw invalid("条目安全级别缺少对应密钥。") }; keyID = selected
            }
            guard let key = keys[keyID] else { throw invalid("条目指定的密钥缺失。") }
            if let encrypted = record.removeValue(forKey: "encrypted") {
                record["secureContents"] = try object(AgileKeychainCrypto.open(AgileKeychainCrypto.base64(encrypted), key: key))
            } else if type == "system.Tombstone" { record["secureContents"] = [String: Any]() }
            else { throw invalid("条目缺少加密内容。") }
            if type == "system.Tombstone" {
                record["trashed"] = true
                if record["title"] as? String == "" { record["title"] = "已删除条目（原库仅保留删除标记）" }
            } else if indexByID[id]![7] as? String == "Y" { record["trashed"] = true }
            record["agileKeychainIndex"] = indexByID[id]!
            decoded[id] = record
        }
        var inventory = AgileAttachmentInventory(files: files)
        var items: [VaultItem] = [], revisions: [VaultRevision] = [], warnings = [
            "AgileKeychain 的标题、网址等元数据可能是明文，旧格式也没有条目认证或整体认证清单。成功解密不证明数据未被修改或删除，请保留源库并核对内容。"
        ]
        for id in decoded.keys.sorted() {
            var record = decoded[id]!
            let resolved = try inventory.resolve(owner: id, source: "agilekeychain:" + id, keys: keys)
            if !resolved.metadata.isEmpty { record["agileKeychainFiles"] = resolved.metadata }
            let original = String(decoding: try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]), as: UTF8.self)
            var mapped = try OnePasswordImporter.mapRecord(record, original: original, sourceIdentity: "agilekeychain:" + id)
            if let folderValue = record["folderUuid"] {
                guard let folder = folderValue as? String else { throw invalid("文件夹引用无效。") }
                if !folder.isEmpty {
                    guard let parent = decoded[folder], OnePasswordImporter.isFolderType(parent["typeName"] as? String ?? ""),
                          let title = parent["title"] as? String else { throw invalid("引用的文件夹缺失。") }
                    mapped.item.tags.append("原文件夹/" + title)
                }
            }
            mapped.item.attachments = resolved.attachments
            for index in mapped.revisions.indices { mapped.revisions[index].snapshot.attachments = resolved.attachments }
            items.append(mapped.item); revisions += mapped.revisions; warnings += mapped.warnings
        }
        if skippedResources { warnings.append("旧版网页程序、样式或缩略图缓存未执行、未迁入；原文件保留在来源目录。") }
        if decoded.values.contains(where: { OnePasswordImporter.isFolderType($0["typeName"] as? String ?? "") }) { warnings.append("文件夹记录与智能规则保留为普通项目，关联转成标签；不会执行原来的智能规则。") }
        warnings += OnePasswordImporter.mappingWarnings(items)
        try inventory.requireComplete()
        if !inventory.blobs.isEmpty { warnings.append("附件已解密并核对原格式 CRC32；CRC32 只能检查意外损坏，不是认证。图标保存在来源快照；密码历史沿用当前附件，不代表完整附件历史。") }
        let document = VaultTransferDocument(items: items, revisions: revisions, blobs: inventory.blobs); try document.validate()
        return VaultImportPreview(document: document, formatName: "1Password AgileKeychain", warnings: Array(Set(warnings)).sorted(), sourceIsEncrypted: true)
    }
    private static func object(_ bytes: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw invalid("JSON 内容不是对象。") }; return value
    }
    // Independent older packages contain UUID hex strings shorter than 32 digits.
    private static func validID(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 32 && value.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) } }
    private static func invalid(_ message: String) -> VaultError { .message("AgileKeychain：" + message) }
}
