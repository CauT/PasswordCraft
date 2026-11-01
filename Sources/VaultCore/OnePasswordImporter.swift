import Foundation
import CryptoKit
import CoreFoundation

public enum OnePasswordImporter {
    public static func read(from selectedURL: URL) throws -> [VaultItem] { try readPreview(from: selectedURL).document.items }
    public static func readPreview(from selectedURL: URL) throws -> VaultImportPreview {
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: selectedURL.path, isDirectory: &directory) else { throw VaultError.message(L("找不到导入文件。")) }
        let package = directory.boolValue ? selectedURL :
            (selectedURL.lastPathComponent == "data.1pif" && selectedURL.deletingLastPathComponent().pathExtension.lowercased() == "1pif" ? selectedURL.deletingLastPathComponent() : nil)
        let files: [String: Data]
        let data: Data
        if let package {
            files = try ReadOnlyPackage(package).snapshotTree(maximumFileBytes: VaultInterchange.maximumTransferBytes, maximumTotalBytes: 64 * 1024 * 1024)
            guard let contents = files["data.1pif"] else { throw VaultError.message(L("导出目录缺少 data.1pif。")) }
            data = contents
        } else { files = [:]; data = try BoundedFileReader.read(selectedURL, maximumBytes: VaultInterchange.maximumTransferBytes) }
        guard let text = String(data: data, encoding: .utf8) else { throw VaultError.message(L("1PIF 必须是 UTF-8 文本。")) }
        return try parsePreview(text, packageFiles: files)
    }
    public static func parse(_ text: String) throws -> [VaultItem] { try parsePreview(text).document.items }
    public static func parsePreview(_ text: String) throws -> VaultImportPreview { try parsePreview(text, packageFiles: [:]) }
    private static func parsePreview(_ text: String, packageFiles: [String: Data]) throws -> VaultImportPreview {
        guard text.utf8.count <= VaultInterchange.maximumTransferBytes else { throw VaultError.message(L("导入内容超过 32 MiB 限制。")) }
        var records: [(record: [String: Any], original: String)] = []
        var recordsByID: [String: [String: Any]] = [:]
        for (number, line) in text.components(separatedBy: "\n").enumerated() {
            var trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if number == 0 { trimmed = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\u{feff}")) }
            if trimmed.isEmpty || trimmed == "***" || trimmed == "***5642bee8-a5ff-11dc-8314-0800200c9a66***" { continue }
            guard let data = trimmed.data(using: .utf8), let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw VaultError.message(L("第 \(number + 1) 行不是支持的 1PIF 条目，整批未导入。"))
            }
            let record = try normalizedPIFRecord(raw)
            if let id = record["uuid"] as? String {
                guard recordsByID.updateValue(record, forKey: id) == nil else { throw VaultError.message(L("1PIF 包含重复来源 UUID，整批未导入。")) }
            }
            records.append((record, trimmed))
        }
        var items: [VaultItem] = [], revisions: [VaultRevision] = [], warnings: [String] = []
        var inventory = PIFAttachmentInventory(files: packageFiles)
        for entry in records {
            var record = entry.record
            if let folder = record["folderUuid"] as? String, !folder.isEmpty {
                if let parent = recordsByID[folder], isFolderType(parent["typeName"] as? String ?? ""), let title = parent["title"] as? String {
                    let tags = record["tags"] as? [String] ?? (record["openContents"] as? [String: Any])?["tags"] as? [String] ?? []
                    record["tags"] = tags + ["原文件夹/" + title]
                } else { warnings.append(L("部分文件夹不在本次导出中，关联 ID 保留在来源快照；未编造文件夹名称。")) }
            }
            var mapped = try mapRecord(record, original: entry.original)
            if let id = record["uuid"] as? String { mapped.item.attachments = try inventory.resolve(owner: id, source: mapped.item.sourceIdentity!) }
            // Password-only history does not describe past attachment state.
            for index in mapped.revisions.indices { mapped.revisions[index].snapshot.attachments = mapped.item.attachments }
            items.append(mapped.item); revisions += mapped.revisions; warnings += mapped.warnings
        }
        guard !items.isEmpty else { throw VaultError.message(L("文件中没有可导入的 1PIF 条目。")) }
        try inventory.requireComplete()
        let document = VaultTransferDocument(items: items, revisions: revisions, blobs: inventory.blobs); try document.validate()
        if !inventory.blobs.isEmpty { warnings.append(L("附件按导出目录中的条目 ID 与文件名迁入。1PIF 没有完整附件清单，无法发现来源中已被删除的附件，请核对原库；密码历史的其他字段与附件沿用当前记录。")) }
        if records.contains(where: { isFolderType($0.record["typeName"] as? String ?? "") }) { warnings.append(L("文件夹关联转成标签，文件夹与智能规则记录保留为普通项目；规则不执行。")) }
        warnings += mappingWarnings(items)
        return VaultImportPreview(document: document, formatName: "1Password 1PIF", warnings: Array(Set(warnings)).sorted())
    }

    /// Windows OPVault-derived 1PIF and Mac legacy 1PIF use different JSON shapes.
    private static func normalizedPIFRecord(_ raw: [String: Any]) throws -> [String: Any] {
        if raw["secureContents"] != nil { return raw }
        guard let overview = raw["overview"] as? [String: Any], let title = overview["title"] as? String else { return raw }
        let type = raw["typeName"] as? String ?? raw["category"] as? String ?? ""
        let details: [String: Any]
        if let value = raw["details"] as? [String: Any] { details = value }
        else if isFolderType(type) { details = overview.filter { $0.key != "title" } }
        else { throw VaultError.message(L("1PIF 条目缺少详情，整批未导入。")) }
        try validateArrays(overview, keys: ["URLs"])
        try validateArrays(details, keys: ["URLs"])
        let urls = (overview["URLs"] as? [[String: Any]] ?? []).compactMap { $0["u"] as? String }
        var record = raw, secure = details
        let existing = secure["URLs"] as? [[String: Any]] ?? []
        secure["URLs"] = existing + urls.map { ["url": $0] }
        record["secureContents"] = secure; record["title"] = title; record["typeName"] = type
        record["location"] = overview["url"] as? String ?? urls.first ?? ""
        record["tags"] = overview["tags"] ?? []; record["folderUuid"] = raw["folder"] ?? raw["parent"]
        record["createdAt"] = raw["created"] ?? 0; record["updatedAt"] = raw["updated"] ?? 0
        record["faveIndex"] = raw["fave"] == nil ? 0 : 1
        return record
    }
    static func isFolderType(_ type: String) -> Bool { type.hasPrefix("system.folder.") || type.hasPrefix("folders.") }

    /// Shared legacy field mapper; callers own container parsing and source identity.
    static func mapRecord(_ record: [String: Any], original: String, sourceIdentity: String? = nil) throws -> (item: VaultItem, revisions: [VaultRevision], warnings: [String]) {
        guard let title = record["title"] as? String, let type = record["typeName"] as? String,
              let secure = record["secureContents"] as? [String: Any] else { throw VaultError.message(L("来源条目缺少标题、分类或字段，整批未导入。")) }
        var revisions: [VaultRevision] = []; var warnings: [String] = []
        try validateArrays(secure, keys: ["fields", "sections", "URLs", "urls", "passwordHistory"])
        for section in secure["sections"] as? [[String: Any]] ?? [] { try validateArrays(section, keys: ["fields"]) }
        if containsAttachments(record) { throw VaultError.message(L("来源条目含未识别的附件结构，整批未导入。请保留完整原始导出。")) }
        let suppliedID = record["uuid"] as? String
        let source = sourceIdentity ?? suppliedID.map { "1pif:" + $0 } ?? "1pif-content:" + hexDigest(Data(original.utf8))
        if suppliedID == nil { warnings.append(L("部分条目没有来源 UUID，只能对完全相同的内容去重。")) }
        let localID = (record["localvaultID"] as? String).flatMap(UUID.init(uuidString:)) ?? stableID(source)
        var item = VaultItem(id: localID, title: title, category: category(type), updatedAt: date(record["updatedAt"]), importedJSON: original,
                             createdAt: date(record["createdAt"]), sourceIdentity: source)
        item.username = secure["username"] as? String ?? ""
        item.password = secure["password"] as? String ?? ""
        item.url = record["location"] as? String ?? secure["url"] as? String ?? ""
        item.notes = secure["notesPlain"] as? String ?? ""
        item.favorite = (((record["faveIndex"] ?? record["favIndex"] ?? (record["openContents"] as? [String: Any])?["faveIndex"]) as? NSNumber)?.intValue ?? 0) > 0
        item.tags = record["tags"] as? [String] ?? (record["openContents"] as? [String: Any])?["tags"] as? [String] ?? []
        item.state = state(record)
        item.deletedAt = item.state == .trashed ? date(record["deletedAt"] ?? record["updatedAt"]) : nil
        var formFields: [VaultField] = []
        for (index, field) in (secure["fields"] as? [[String: Any]] ?? []).enumerated() {
            let designation = field["designation"] as? String ?? ""
            let value = string(field["value"])
            if designation == "username" { item.username = value }
            else if designation == "password" { item.password = value }
            else {
                let name = field["name"] as? String ?? "field-\(index)"
                let kind = field["type"] as? String ?? field["fieldType"] as? String ?? "T"
                formFields.append(VaultField(id: stableID(source + ":form:\(index)"), label: field["title"] as? String ?? name, value: value, kind: fieldKind(kind), importedKind: kind, importedKey: "form:" + name))
            }
        }
        let reserved: Set<String> = ["username", "password", "url", "notesPlain", "fields", "sections", "URLs", "urls", "passwordHistory"]
        let scalarFields = secure.keys.sorted().filter { !reserved.contains($0) }.map { key -> VaultField in
            let value = secure[key]!
            return VaultField(id: stableID(source + ":secure:" + key), label: fieldLabel(key), value: string(value), kind: inferredKind(key), importedKind: jsonKind(value), importedKey: "secure:" + key)
        }
        if !scalarFields.isEmpty { item.sections.append(VaultSection(id: stableID(source + ":secure"), title: "项目字段", fields: scalarFields)) }
        if !formFields.isEmpty { item.sections.append(VaultSection(id: stableID(source + ":form"), title: "网页表单字段", fields: formFields)) }
        for (sectionIndex, section) in (secure["sections"] as? [[String: Any]] ?? []).enumerated() {
            let name = section["name"] as? String ?? "section-\(sectionIndex)"
            let fields = (section["fields"] as? [[String: Any]] ?? []).enumerated().map { index, field -> VaultField in
                let kind = field["k"] as? String ?? field["kind"] as? String ?? "string"
                let identity = field["n"] as? String ?? field["name"] as? String ?? "\(index)"
                return VaultField(id: (field["localvaultID"] as? String).flatMap(UUID.init(uuidString:)) ?? stableID(source + ":" + name + ":\(index):" + identity), label: field["t"] as? String ?? field["title"] as? String ?? identity,
                                  value: string(field["v"] ?? field["value"]), kind: identity.hasPrefix("TOTP_") ? .otp : fieldKind(kind), importedKind: kind, importedKey: identity)
            }
            item.sections.append(VaultSection(id: (section["localvaultID"] as? String).flatMap(UUID.init(uuidString:)) ?? stableID(source + ":section:\(sectionIndex):" + name), title: section["title"] as? String ?? name, fields: fields))
        }
        let urls = (secure["URLs"] ?? secure["urls"]) as? [[String: Any]] ?? []
        item.additionalURLs = urls.compactMap { $0["url"] as? String }.filter { !$0.isEmpty && $0 != item.url }
        let passwordHistory = secure["passwordHistory"] as? [[String: Any]] ?? []
        for (index, previous) in passwordHistory.enumerated() {
            guard let value = previous["value"] as? String else { throw VaultError.message(L("1PIF 密码历史值无效，整批未导入。")) }
            var old = item; old.password = value; old.updatedAt = date(previous["time"])
            revisions.append(VaultRevision(id: stableID(source + ":passwordHistory:\(index)"), createdAt: old.updatedAt, snapshot: old))
        }
        return (item, revisions, warnings)
    }

    /// A preserved value is not a claim that its original specialized control exists.
    static func mappingWarnings(_ items: [VaultItem]) -> [String] {
        var warnings: [String] = []
        let unknownCategories = items.filter { $0.category == "其他" }.count
        if unknownCategories > 0 { warnings.append(L("\(unknownCategories) 个项目的来源分类没有专用模板，已归入「其他」并保留原文。")) }
        let plainKinds: Set<String> = ["t", "s", "text", "string", "number", "integer", "double", "boolean", "bool", "null"]
        let fallback = items.flatMap(\.sections).flatMap(\.fields).filter {
            guard let kind = $0.importedKind?.lowercased() else { return false }
            return $0.kind == .text && !plainKinds.contains(kind)
        }.count
        if fallback > 0 { warnings.append(L("\(fallback) 个复合或未识别类型字段以文本／JSON 保留，可编辑和导出；没有对应的专用控件，请核对来源内容。")) }
        return warnings
    }

    static func validateArrays(_ object: [String: Any], keys: [String]) throws {
        for key in keys {
            if let value = object[key], !(value is NSNull), !(value is [[String: Any]]) {
                throw VaultError.message(L("来源字段结构无效，整批未导入。请保留原始导出。"))
            }
        }
    }
    static func category(_ type: String) -> String {
        switch type {
        case "webforms.WebForm", "001": return "登录"
        case "passwords.Password", "005": return "密码"
        case "securenotes.SecureNote", "003": return "安全笔记"
        case "wallet.financial.CreditCard", "002": return "信用卡"
        case "wallet.financial.BankAccount", "wallet.financial.BankAccountUS", "101": return "银行账户"
        case "identities.Identity", "004": return "身份信息"
        case "wallet.government.Passport", "106": return "护照"
        case "wallet.government.DriversLicense", "103": return "驾驶证"
        case "wallet.computer.License", "100": return "软件许可证"
        case "006": return "文档"
        case "wallet.computer.Database", "102": return "数据库"
        case "wallet.computer.Server", "wallet.computer.UnixServer", "110": return "服务器"
        case "wallet.computer.Router", "109": return "无线网络"
        case "112": return "API 凭据"
        default: return "其他"
        }
    }
    static func typeName(_ category: String) -> String {
        ["登录":"webforms.WebForm", "密码":"passwords.Password", "安全笔记":"securenotes.SecureNote", "信用卡":"wallet.financial.CreditCard", "银行账户":"wallet.financial.BankAccount", "身份信息":"identities.Identity", "护照":"wallet.government.Passport", "驾驶证":"wallet.government.DriversLicense", "软件许可证":"wallet.computer.License", "数据库":"wallet.computer.Database", "服务器":"wallet.computer.Server", "无线网络":"wallet.computer.Router"][category] ?? "securenotes.SecureNote"
    }
    static func state(_ record: [String: Any]) -> ItemState {
        if record["typeName"] as? String == "system.Tombstone" || (record["trashed"] as? Bool == true) || (record["state"] as? String == "trashed") || (record["state"] as? String == "deleted") { return .trashed }
        if (record["archived"] as? Bool == true) || (record["state"] as? String == "archived") { return .archived }
        return .active
    }
    static func fieldKind(_ name: String) -> FieldKind {
        switch name.lowercased() {
        case "p", "concealed", "password", "ccnum", "creditcardnumber": return .password
        case "u", "url": return .url
        case "e", "email": return .email
        case "date": return .date
        case "monthyear", "month/year": return .monthYear
        case "tel", "phone": return .phone
        case "otp", "totp", "onetimepassword": return .otp
        default: return .text
        }
    }
    static func inferredKind(_ key: String) -> FieldKind {
        let value = key.lowercased()
        if ["password", "pin", "ccnum", "cvv", "code", "key", "number"].contains(where: value.contains) { return .password }
        if value.contains("email") { return .email }
        if value.contains("phone") { return .phone }
        if value.contains("url") || value.contains("website") { return .url }
        if value.contains("expiry") || value.contains("expires") { return .monthYear }
        if value.contains("date") || value.contains("birth") { return .date }
        return .text
    }
    static func fieldLabel(_ key: String) -> String {
        ["ccnum":"卡号", "cvv":"安全码", "expiry":"有效期", "cardholder":"持卡人", "type":"类型", "bank":"银行", "accountNo":"账号", "routingNo":"银行代码", "pin":"PIN", "licenseKey":"许可证密钥", "reg_name":"注册人", "reg_email":"注册邮箱", "passportNumber":"护照号码", "firstName":"名字", "lastName":"姓氏", "birthdate":"出生日期", "address":"地址", "company":"公司", "phone":"电话", "email":"邮箱"][key] ?? key
    }
    static func date(_ value: Any?) -> Date { Date(timeIntervalSince1970: (value as? NSNumber)?.doubleValue ?? 0) }
    static func string(_ value: Any?) -> String {
        guard let value else { return "" }
        if value is NSNull { return "" }
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return CFGetTypeID(value) == CFBooleanGetTypeID() ? (value.boolValue ? "true" : "false") : value.stringValue }
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]), let result = String(data: data, encoding: .utf8) { return result }
        return ""
    }
    static func jsonKind(_ value: Any) -> String {
        if value is String { return "string" }; if value is NSNull { return "null" }
        if let number = value as? NSNumber { return CFGetTypeID(number) == CFBooleanGetTypeID() ? "boolean" : "number" }
        return "json"
    }
    static func stableID(_ value: String) -> UUID {
        let hash = Array(SHA256.hash(data: Data(value.utf8)))
        return UUID(uuid: (hash[0],hash[1],hash[2],hash[3],hash[4],hash[5],(hash[6] & 15) | 80,hash[7],(hash[8] & 63) | 128,hash[9],hash[10],hash[11],hash[12],hash[13],hash[14],hash[15]))
    }
    static func hexDigest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func containsAttachments(_ value: Any) -> Bool {
        if let dictionary = value as? [String: Any] {
            for (key, child) in dictionary {
                if ["attachments", "documentAttributes", "attachment", "file"].contains(key) {
                    if child is NSNull { continue }
                    if let array = child as? [Any], array.isEmpty { continue }
                    if let dictionary = child as? [String: Any], dictionary.isEmpty { continue }
                    return true
                }
                if containsAttachments(child) { return true }
            }
        } else if let array = value as? [Any] { return array.contains(where: containsAttachments) }
        return false
    }
}
