import Foundation
import CoreFoundation

/// Read-only migration from OPVault's default profile. Never evaluates its JavaScript wrappers.
public enum OPVaultImporter {
    public static func read(from url: URL, password: String) throws -> VaultImportPreview {
        let root = try ReadOnlyPackage(url), rootNames = try root.names()
        guard rootNames.contains("default"), rootNames.isSubset(of: ["default", ".DS_Store"]) else { throw invalid(L("仅支持含 default 配置的 OPVault 目录；额外配置不会被忽略。")) }
        let directory = try root.directory("default"), names = try directory.names()
        let bands = Set("0123456789ABCDEF".map { "band_\($0).js" })
        let attachmentNames = names.filter { $0.hasSuffix(".attachment") }
        guard names.contains("profile.js"), names.subtracting(bands).subtracting(attachmentNames).isSubset(of: ["profile.js", "folders.js", ".DS_Store"]) else { throw invalid(L("目录含未识别文件。")) }
        let files = try directory.snapshot(expectedNames: names, maximumFileBytes: 32 * 1024 * 1024, maximumTotalBytes: 64 * 1024 * 1024)
        let profile = try wrapped(files["profile.js"]!, prefix: "var profile=", suffix: ";")
        guard let profileID = profile["uuid"] as? String, validID(profileID), let iterations = integer(profile["iterations"]) else { throw invalid(L("配置标识或密钥参数无效。")) }
        let derived = try OPVaultCrypto.derive(password: password, salt: OPVaultCrypto.base64(profile["salt"]), iterations: iterations)
        let master = try OPVaultCrypto.seedKeys(OPVaultCrypto.base64(profile["masterKey"]), keys: derived, expectedSize: 256)
        let overviewKeys = try OPVaultCrypto.seedKeys(OPVaultCrypto.base64(profile["overviewKey"]), keys: derived, expectedSize: 64)
        var folders: [String: [String: Any]] = [:]
        if let bytes = files["folders.js"] {
            for (id, value) in try wrapped(bytes, prefix: "loadFolders(", suffix: ");") {
                guard validID(id), var record = value as? [String: Any], record["uuid"] as? String == id else { throw invalid(L("文件夹标识无效。")) }
                let overview = try object(OPVaultCrypto.open(OPVaultCrypto.base64(record["overview"]), keys: overviewKeys, maximumBytes: VaultInterchange.maximumTransferBytes))
                guard overview["title"] is String else { throw invalid(L("文件夹名称无效。")) }
                record["overview"] = overview; folders[id] = record
            }
        }
        var attachmentsByItem: [String: [String]] = [:]
        for name in attachmentNames {
            let parts = String(name.dropLast(".attachment".count)).split(separator: "_", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2, parts.allSatisfy(validID) else { throw invalid(L("附件文件标识无效。")) }
            attachmentsByItem[parts[0], default: []].append(name)
        }
        var items: [VaultItem] = [], revisions: [VaultRevision] = [], blobs: [String: Data] = [:]
        var consumed: Set<String> = [], seenIDs: Set<String> = []
        var warnings = [L("仅在本机读取并迁移，不会修改源 OPVault。原格式没有整体认证清单，无法检测源库中已被移除的文件；请核对项目与附件数量。")]
        for name in names.intersection(bands).sorted() {
            let records = try wrapped(files[name]!, prefix: "ld(", suffix: ");")
            for id in records.keys.sorted() {
                guard validID(id), id.first == name.dropFirst(5).first, seenIDs.insert(id).inserted,
                      let record = records[id] as? [String: Any], record["uuid"] as? String == id,
                      let category = record["category"] as? String else { throw invalid(L("条目标识或分组不匹配。")) }
                try authenticateRecord(record, keys: overviewKeys)
                let source = "opvault:\(profileID):\(id)"
                if category == "099" && record["d"] == nil && record["k"] == nil {
                    guard attachmentsByItem[id] == nil else { throw invalid(L("删除标记仍有关联附件，但没有可用条目密钥。")) }
                    var item = VaultItem(id: OnePasswordImporter.stableID(source), title: "已删除条目（原库仅保留删除标记）", category: "其他", updatedAt: OnePasswordImporter.date(record["updated"]), importedJSON: try json(record), state: .trashed, deletedAt: OnePasswordImporter.date(record["updated"]), sourceIdentity: source)
                    item.notes = "原 OPVault 仅保留删除标记，没有可恢复的原字段。"; items.append(item)
                    warnings.append(L("来源包含删除标记，已保留在回收站；标记不含原内容。"))
                    continue
                }
                let itemKeys = try OPVaultCrypto.itemKeys(OPVaultCrypto.base64(record["k"]), master: master)
                let overview = try object(OPVaultCrypto.open(OPVaultCrypto.base64(record["o"]), keys: overviewKeys, maximumBytes: VaultInterchange.maximumTransferBytes))
                let details = try object(OPVaultCrypto.open(OPVaultCrypto.base64(record["d"]), keys: itemKeys, maximumBytes: VaultInterchange.maximumTransferBytes))
                guard let title = overview["title"] as? String else { throw invalid(L("条目标题无效。")) }
                try OnePasswordImporter.validateArrays(overview, keys: ["URLs"])
                if let tags = overview["tags"], !(tags is [String]) { throw invalid(L("标签结构无效。")) }
                var tags = overview["tags"] as? [String] ?? []
                if let folderID = record["folder"] as? String, !folderID.isEmpty {
                    guard let folder = folders[folderID], let information = folder["overview"] as? [String: Any], let folderName = information["title"] as? String else { throw invalid(L("条目引用的文件夹缺失。")) }
                    tags.append("原文件夹/" + folderName)
                }
                var mappedRecord: [String: Any] = ["uuid": id, "title": title, "typeName": category, "secureContents": details,
                    "location": overview["url"] as? String ?? "", "tags": tags, "createdAt": record["created"] ?? 0,
                    "updatedAt": record["updated"] ?? 0, "trashed": record["trashed"] ?? false, "faveIndex": record["fave"] == nil ? 0 : 1]
                mappedRecord["opvaultProfileID"] = profileID
                mappedRecord["opvaultMetadata"] = record.filter { !["k", "d", "o", "hmac"].contains($0.key) }
                mappedRecord["opvaultOverview"] = overview
                var mapped = try OnePasswordImporter.mapRecord(mappedRecord, original: json(mappedRecord), sourceIdentity: source)
                mapped.item.additionalURLs += (overview["URLs"] as? [[String: Any]] ?? []).compactMap { $0["u"] as? String }.filter { !$0.isEmpty && $0 != mapped.item.url && !mapped.item.additionalURLs.contains($0) }
                var attachmentMetadata: [[String: Any]] = [], removed: [VaultAttachment] = []
                for filename in (attachmentsByItem[id] ?? []).sorted() {
                    let file = try attachment(files[filename]!, filename: filename, itemID: id, source: source, keys: itemKeys, overviewKeys: overviewKeys)
                    consumed.insert(filename); blobs[file.attachment.blobID] = file.data; attachmentMetadata.append(file.metadata)
                    if file.trashed { removed.append(file.attachment) } else { mapped.item.attachments.append(file.attachment) }
                }
                if !attachmentMetadata.isEmpty { mappedRecord["opvaultFileMetadata"] = attachmentMetadata; mapped.item.importedJSON = try json(mappedRecord) }
                if !removed.isEmpty {
                    var snapshot = mapped.item; snapshot.attachments += removed
                    revisions.append(VaultRevision(id: OnePasswordImporter.stableID(source + ":removed-attachments"), createdAt: snapshot.updatedAt, snapshot: snapshot))
                    warnings.append(L("原库已移除的附件保留在迁移历史快照，可通过历史恢复；快照的其他字段来自当前记录。"))
                }
                // The source provides old passwords only, not full past item snapshots.
                revisions += mapped.revisions; items.append(mapped.item); warnings += mapped.warnings
            }
        }
        guard consumed == attachmentNames else { throw invalid(L("存在未关联附件，整批未导入。")) }
        if !folders.isEmpty {
            let source = "opvault:\(profileID):folders"
            items.append(VaultItem(id: OnePasswordImporter.stableID(source), title: "OPVault 原文件夹与智能规则", notes: try json(folders), category: "安全笔记", updatedAt: OnePasswordImporter.date(profile["updatedAt"]), createdAt: OnePasswordImporter.date(profile["createdAt"]), sourceIdentity: source))
            warnings.append(L("普通文件夹已转成标签，并另建一条笔记保留全部文件夹和智能规则；智能规则不自动执行。原格式的文件夹关联未受条目 HMAC 保护。"))
        }
        if items.contains(where: { $0.state == .trashed }) { warnings.append(L("原库 trashed 条目已放入本地回收站，未永久删除。")) }
        let document = VaultTransferDocument(items: items, revisions: revisions, blobs: blobs); try document.validate()
        warnings += OnePasswordImporter.mappingWarnings(items)
        return VaultImportPreview(document: document, formatName: "1Password OPVault", warnings: Array(Set(warnings)).sorted(), sourceIsEncrypted: true)
    }

    private static func authenticateRecord(_ record: [String: Any], keys: OPVaultKeys) throws {
        var message = Data()
        for key in record.keys.sorted() where key != "hmac" && key != "folder" {
            guard key.utf8.allSatisfy({ $0 < 128 }) else { throw invalid(L("条目认证字段不是受支持的 ASCII 标识。")) }
            let value: String
            if let string = record[key] as? String { value = string }
            else if let number = record[key] as? NSNumber { value = number.stringValue }
            else { throw invalid(L("条目认证字段类型不受支持。")) }
            guard value.utf8.allSatisfy({ $0 < 128 }) else { throw invalid(L("条目认证字段编码不受支持。")) }
            message.append(contentsOf: key.utf8); message.append(contentsOf: value.utf8)
        }
        try OPVaultCrypto.verify(OPVaultCrypto.base64(record["hmac"]), message: message, keys: keys)
    }
    private static func attachment(_ bytes: Data, filename: String, itemID: String, source: String, keys: OPVaultKeys, overviewKeys: OPVaultKeys) throws -> (attachment: VaultAttachment, data: Data, metadata: [String: Any], trashed: Bool) {
        guard bytes.count >= 16, bytes.prefix(7) == Data("OPCLDAT".utf8), [1, 2].contains(bytes[7]) else { throw invalid(L("附件头无效。")) }
        let metadataSize = Int(bytes[8]) | Int(bytes[9]) << 8
        let iconSize = bytes[12..<16].enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        let iconStart = 16 + metadataSize, contentStart = iconStart + iconSize
        guard contentStart <= bytes.count else { throw invalid(L("附件长度无效。")) }
        var metadata = try object(Data(bytes[16..<iconStart]))
        let attachmentID = String(filename.dropFirst(33).dropLast(".attachment".count))
        guard metadata["itemUUID"] as? String == itemID, metadata["uuid"] as? String == attachmentID else { throw invalid(L("附件与所属条目的标识不符。")) }
        let overview = try object(OPVaultCrypto.open(OPVaultCrypto.base64(metadata["overview"]), keys: overviewKeys, maximumBytes: 65536))
        guard let name = overview["filename"] as? String, AttachmentStore.validName(name) else { throw invalid(L("附件文件名无效。")) }
        metadata["overview"] = overview
        if iconSize > 0 { metadata["iconBase64"] = try OPVaultCrypto.open(Data(bytes[iconStart..<contentStart]), keys: keys, maximumBytes: AttachmentStore.maximumAttachmentBytes).base64EncodedString() }
        let data = try OPVaultCrypto.open(Data(bytes[contentStart...]), keys: keys, maximumBytes: AttachmentStore.maximumAttachmentBytes)
        if let size = metadata["contentsSize"] { guard integer(size) == data.count else { throw invalid(L("附件声明大小与解密内容不符。")) } }
        let attachment = VaultAttachment(id: OnePasswordImporter.stableID(source + ":attachment:" + attachmentID), name: name, data: data)
        return (attachment, data, metadata, metadata["trashed"] as? Bool == true)
    }
    private static func wrapped(_ bytes: Data, prefix: String, suffix: String) throws -> [String: Any] {
        guard let raw = String(data: bytes, encoding: .utf8) else { throw invalid(L("文件不是 UTF-8。")) }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix(prefix), text.hasSuffix(suffix) else { throw invalid(L("文件包装格式无效；不会执行 JavaScript。")) }
        return try object(Data(text.dropFirst(prefix.count).dropLast(suffix.count).utf8))
    }
    private static func object(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw invalid(L("JSON 数据不是对象。")) }; return object
    }
    private static func json(_ value: Any) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self) }
    private static func validID(_ id: String) -> Bool { id.utf8.count == 32 && id.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) } }
    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
              number.doubleValue >= 0, number.doubleValue < Double(Int.max), number.doubleValue == Double(number.intValue) else { return nil }; return number.intValue
    }
    private static func invalid(_ reason: String) -> VaultError { .message("OPVault：" + reason) }
}
