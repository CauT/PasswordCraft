import Foundation

extension VaultInterchange {
    /// Parses only bounded in-memory members. No archive paths are written to disk.
    public static func decode1PUX(_ data: Data) throws -> VaultImportPreview {
        let members = try SafeZIP.read(data)
        guard let attributes = members["export.attributes"], let exported = members["export.data"],
              let meta = try JSONSerialization.jsonObject(with: attributes) as? [String: Any], meta["version"] as? Int == 3 else {
            throw VaultError.message(L("仅支持包含 export.attributes/export.data 的 1PUX v3 导出。"))
        }
        guard let root = try JSONSerialization.jsonObject(with: exported) as? [String: Any], let accounts = root["accounts"] as? [[String: Any]] else { throw VaultError.message(L("1PUX 账户数据无效。")) }
        var items: [VaultItem] = []; var revisions: [VaultRevision] = []; var warnings: [String] = []
        var inventory = OnePasswordFileInventory(members: members)
        for (accountIndex, account) in accounts.enumerated() {
            let accountAttrs = account["attrs"] as? [String: Any] ?? [:]
            let accountID = accountAttrs["uuid"] as? String ?? "account-\(accountIndex)"
            guard let vaults = account["vaults"] as? [[String: Any]] else { throw VaultError.message(L("1PUX 缺少密码库列表。")) }
            for (vaultIndex, vault) in vaults.enumerated() {
                let vaultAttrs = vault["attrs"] as? [String: Any] ?? [:]
                let vaultID = vaultAttrs["uuid"] as? String ?? "vault-\(vaultIndex)"
                guard let records = vault["items"] as? [[String: Any]] else { throw VaultError.message(L("1PUX 密码库条目无效。")) }
                for record in records {
                    guard let uuid = record["uuid"] as? String, let overview = record["overview"] as? [String: Any], let title = overview["title"] as? String else { throw VaultError.message(L("1PUX 条目缺少标识或字段，整批未导入。")) }
                    let source = "1pux:\(accountID):\(vaultID):\(uuid)"
                    let resolved = try inventory.resolve(record, source: source)
                    let details = resolved.details
                    try OnePasswordImporter.validateArrays(details, keys: ["loginFields", "sections", "passwordHistory"])
                    try OnePasswordImporter.validateArrays(overview, keys: ["urls"])
                    for section in details["sections"] as? [[String: Any]] ?? [] { try OnePasswordImporter.validateArrays(section, keys: ["fields"]) }
                    let raw = String(data: try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]), encoding: .utf8)!
                    var item = VaultItem(id: OnePasswordImporter.stableID(source), title: title,
                                         url: overview["url"] as? String ?? "", notes: details["notesPlain"] as? String ?? "",
                                         category: OnePasswordImporter.category(record["categoryUuid"] as? String ?? ""),
                                         favorite: (record["favIndex"] as? Int ?? 0) > 0, updatedAt: OnePasswordImporter.date(record["updatedAt"]), importedJSON: raw,
                                         createdAt: OnePasswordImporter.date(record["createdAt"]), state: OnePasswordImporter.state(record), tags: overview["tags"] as? [String] ?? [], sourceIdentity: source)
                    item.attachments = resolved.attachments
                    item.password = details["password"] as? String ?? ""
                    if item.category == "文档", item.attachments.isEmpty { throw VaultError.message(L("1PUX 文档没有可核对的文件，整批未导入。")) }
                    if item.state == .trashed { item.deletedAt = item.updatedAt }
                    item.additionalURLs = (overview["urls"] as? [[String: Any]] ?? []).compactMap { $0["url"] as? String }.filter { !$0.isEmpty && $0 != item.url }
                    var formFields: [VaultField] = []
                    for (index, field) in (details["loginFields"] as? [[String: Any]] ?? []).enumerated() {
                        let value = OnePasswordImporter.string(field["value"])
                        switch field["designation"] as? String {
                        case "username": item.username = value
                        case "password": item.password = value
                        default:
                            let name = field["name"] as? String ?? "field-\(index)"
                            let kind = field["fieldType"] as? String ?? field["type"] as? String ?? "T"
                            formFields.append(VaultField(id: OnePasswordImporter.stableID(source + ":form:\(index)"), label: name, value: value, kind: OnePasswordImporter.fieldKind(kind), importedKind: kind, importedKey: "form:" + name))
                        }
                    }
                    if !formFields.isEmpty { item.sections.append(VaultSection(id: OnePasswordImporter.stableID(source + ":form"), title: "网页表单字段", fields: formFields)) }
                    for (sectionIndex, section) in (details["sections"] as? [[String: Any]] ?? []).enumerated() {
                        let fields = (section["fields"] as? [[String: Any]] ?? []).enumerated().map { index, field -> VaultField in
                            let identifier = field["id"] as? String ?? "field-\(index)"
                            let typed = field["value"] as? [String: Any] ?? [:]
                            // Known field values wrap one typed value, e.g. {concealed: "secret"}.
                            let kind = typed.count == 1 ? typed.keys.first! : "json"
                            let value: Any = typed.count == 1 ? typed[kind]! : (field["value"] ?? "")
                            return VaultField(id: OnePasswordImporter.stableID(source + ":section:\(sectionIndex):field:\(index):" + identifier), label: field["title"] as? String ?? identifier,
                                              value: OnePasswordImporter.string(value), kind: OnePasswordImporter.fieldKind(kind), importedKind: kind, importedKey: identifier)
                        }
                        item.sections.append(VaultSection(id: OnePasswordImporter.stableID(source + ":section:\(sectionIndex)"), title: section["title"] as? String ?? "", fields: fields))
                    }
                    let reserved: Set<String> = ["password","notesPlain","loginFields","sections","passwordHistory"]
                    let remaining = details.keys.sorted().filter { !reserved.contains($0) }.map { key in
                        VaultField(id: OnePasswordImporter.stableID(source + ":detail:" + key), label: key, value: OnePasswordImporter.string(details[key]), kind: OnePasswordImporter.inferredKind(key), importedKind: OnePasswordImporter.jsonKind(details[key]!), importedKey: "secure:" + key)
                    }
                    if !remaining.isEmpty { item.sections.append(VaultSection(id: OnePasswordImporter.stableID(source + ":details"), title: "其他项目字段", fields: remaining)) }
                    for (index, history) in (details["passwordHistory"] as? [[String: Any]] ?? []).enumerated() {
                        guard let previous = history["value"] as? String else { throw VaultError.message(L("1PUX 密码历史值无效。")) }
                        var old = item; old.password = previous; old.updatedAt = OnePasswordImporter.date(history["time"])
                        revisions.append(VaultRevision(id: OnePasswordImporter.stableID(source + ":history:\(index)"), createdAt: old.updatedAt, snapshot: old))
                    }
                    items.append(item)
                }
                if let name = vaultAttrs["name"] as? String, !name.isEmpty { warnings.append(L("来源库「\(name)」的条目将合并到当前本地库；来源库 ID 保留用于去重。")) }
            }
        }
        try inventory.requireComplete()
        let document = VaultTransferDocument(items: items, revisions: revisions, blobs: inventory.blobs); try document.validate()
        if !inventory.blobs.isEmpty { warnings.append(L("附件已按文件标识、文件名、字节数及 ZIP 校验值核对。密码历史仅提供旧密码，其他字段与附件沿用当前记录，不代表来源的完整历史。")) }
        warnings += OnePasswordImporter.mappingWarnings(items)
        return VaultImportPreview(document: document, formatName: "1Password 1PUX v3", warnings: Array(Set(warnings)).sorted())
    }
}
