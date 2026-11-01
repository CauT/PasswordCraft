import Foundation
import Darwin

/// Public, plaintext interchange schema. Dates use Swift Codable seconds since 2001-01-01.
/// Preserve this schema independently of the authenticated encrypted envelope.
public struct VaultTransferDocument: Codable, Equatable {
    public var format: String
    public var version: Int
    public var items: [VaultItem]
    public var revisions: [VaultRevision]
    public var blobs: [String: Data]
    public init(items: [VaultItem], revisions: [VaultRevision] = [], blobs: [String: Data] = [:]) {
        // Stable interchange schema, also consumed by earlier releases.
        format = "LocalVault-Transfer"; version = 2; self.items = items; self.revisions = revisions; self.blobs = blobs
    }
    enum CodingKeys: String, CodingKey { case format, version, items, revisions, blobs }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decode(String.self, forKey: .format); version = try c.decode(Int.self, forKey: .version)
        items = try c.decode([VaultItem].self, forKey: .items); revisions = try c.decode([VaultRevision].self, forKey: .revisions)
        blobs = try c.decodeIfPresent([String: Data].self, forKey: .blobs) ?? [:]
    }
    public func validate() throws {
        guard format == "LocalVault-Transfer", [1, 2].contains(version) else { throw VaultError.message("不支持的明文导出版本。") }
        guard version == 2 || (blobs.isEmpty && (items + revisions.map(\.snapshot)).allSatisfy({ $0.attachments.isEmpty })) else { throw VaultError.message("旧版导出格式不能包含附件。") }
        guard Set(items.map(\.id)).count == items.count else { throw VaultError.message("导入文件含重复项目 ID，整批未导入。") }
        let ids = Set(items.map(\.id))
        guard Set(revisions.map(\.id)).count == revisions.count, revisions.allSatisfy({ ids.contains($0.snapshot.id) }) else { throw VaultError.message("导入历史标识重复或缺少对应项目。") }
        for item in items + revisions.map(\.snapshot) {
            guard item.state == .trashed || item.deletedAt == nil else { throw VaultError.message("未删除项目不能带有删除时间。") }
            guard Set(item.sections.map(\.id)).count == item.sections.count else { throw VaultError.message("字段分组 ID 重复。") }
            let fields = item.sections.flatMap(\.fields)
            guard Set(fields.map(\.id)).count == fields.count else { throw VaultError.message("自定义字段 ID 重复。") }
        }
        try AttachmentStore.validate(items: items, revisions: revisions, blobs: blobs)
    }
}

public struct VaultImportPreview {
    public var document: VaultTransferDocument
    public var formatName: String
    public var warnings: [String]
    public var sourceIsEncrypted: Bool
    public init(document: VaultTransferDocument, formatName: String, warnings: [String] = [], sourceIsEncrypted: Bool = false) {
        self.document = document; self.formatName = formatName; self.warnings = warnings; self.sourceIsEncrypted = sourceIsEncrypted
    }
    public var items: [VaultItem] { document.items }
    public var revisions: [VaultRevision] { document.revisions }
    public var activeCount: Int { items.filter { $0.state == .active }.count }
    public var archivedCount: Int { items.filter { $0.state == .archived }.count }
    public var trashedCount: Int { items.filter { $0.state == .trashed }.count }
}
public enum VaultMergePolicy { case skipExisting, copies }
public struct VaultImportMerge {
    public let document: VaultTransferDocument
    public let addedCount: Int
    public let skippedCount: Int
    public let conflictCount: Int
    public let warnings: [String]
    public var items: [VaultItem] { document.items }
    public var revisions: [VaultRevision] { document.revisions }
}
public enum VaultExportFormat: String, CaseIterable, Identifiable {
    case nativeJSON, onePIF, csv
    public var id: String { rawValue }
    public var title: String {
        switch self { case .nativeJSON: return "完整 JSON（含历史）"; case .onePIF: return "1Password 1PIF"; case .csv: return "CSV（含完整 JSON 列）" }
    }
    public var fileExtension: String { switch self { case .nativeJSON: return "json"; case .onePIF: return "1pif"; case .csv: return "csv" } }
    public var warning: String {
        switch self {
        case .nativeJSON: return "完整保留当前项目、回收站及历史记录。文件是明文，任何能读取它的人都能看到密码。"
        case .onePIF: return "导出当前字段、标签、状态和密码历史；其他软件可能忽略扩展字段，不保留完整条目历史。文件是明文。"
        case .csv: return "常规列方便其他软件读取；完整字段和历史放在 localvault_json 列中，其他软件可能忽略此列。文件是明文；电子表格软件可能把以 =、+、-、@ 开头的内容当作公式，请仅作为文本导入。"
        }
    }
}

public enum VaultInterchange {
    public static let maximumTransferBytes = 32 * 1024 * 1024
    public static func read(from url: URL) throws -> VaultImportPreview {
        if let format = LegacyVaultFormat(url: url) { throw VaultError.message("\(format.title) 需要源库主密码，请使用旧库读取入口。") }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { throw VaultError.message("找不到导入文件。") }
        if isDirectory.boolValue || url.pathExtension.lowercased() == "1pif" { return try OnePasswordImporter.readPreview(from: url) }
        let bytes = try BoundedFileReader.read(url, maximumBytes: url.pathExtension.lowercased() == "1pux" ? 64 * 1024 * 1024 : maximumTransferBytes)
        switch url.pathExtension.lowercased() {
        case "json": return try decodeJSON(bytes)
        case "csv": return try decodeCSV(bytes)
        case "1pux": return try decode1PUX(bytes)
        default: throw VaultError.message("请选择 .1pif、.1pux、.json 或 .csv 文件。OPVault 或 AgileKeychain 请从旧库读取入口输入主密码。")
        }
    }
    public static func decodeJSON(_ data: Data) throws -> VaultImportPreview {
        guard data.count <= maximumTransferBytes else { throw VaultError.message("导入文件过大。") }
        let document: VaultTransferDocument
        do { document = try JSONDecoder().decode(VaultTransferDocument.self, from: data) }
        catch { throw VaultError.message("不是有效的 PasswordCraft 完整 JSON 导出。") }
        try document.validate()
        return VaultImportPreview(document: document, formatName: "PasswordCraft 完整 JSON")
    }
    public static func planMerge(_ preview: VaultImportPreview, existing: [VaultItem], existingRevisions: [VaultRevision] = [], existingBlobs: [String: Data] = [:], policy: VaultMergePolicy = .skipExisting) throws -> VaultImportMerge {
        try preview.document.validate()
        try VaultTransferDocument(items: existing, revisions: existingRevisions, blobs: existingBlobs).validate()
        var items = existing; var revisions = existingRevisions
        var idMap = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        var sourceMap: [String: VaultItem] = [:]
        for item in existing { if let identity = item.sourceIdentity { sourceMap[identity] = item } }
        var added = 0; var skipped = 0; var conflicts = 0; var warnings = preview.warnings
        let groupedRevisions = Dictionary(grouping: preview.revisions, by: { $0.snapshot.id })
        for original in preview.items {
            let match = idMap[original.id] ?? original.sourceIdentity.flatMap { sourceMap[$0] }
            if let match, policy == .skipExisting {
                skipped += 1
                if !equivalent(match, original) { conflicts += 1 }
                continue
            }
            var item = original
            let copied = policy == .copies
            if copied { item.id = UUID(); item.sourceIdentity = nil }
            items.append(item); idMap[item.id] = item
            if let identity = item.sourceIdentity { sourceMap[identity] = item }
            for var revision in groupedRevisions[original.id] ?? [] {
                if copied { revision.id = UUID(); revision.snapshot.id = item.id; revision.snapshot.sourceIdentity = nil }
                if let prior = revisions.first(where: { $0.id == revision.id }) {
                    guard prior == revision else { throw VaultError.message("导入历史 ID 与现有历史冲突，整批未导入。") }
                } else { revisions.append(revision) }
            }
            added += 1
        }
        if conflicts > 0 { warnings.append("\(conflicts) 个来源项目与现有内容不同，已跳过，未覆盖本地修改。可选择作为副本导入后自行比较。") }
        let mergedBlobs = try AttachmentStore.merging(preview.document.blobs, into: existingBlobs)
        let result = VaultTransferDocument(items: items, revisions: revisions, blobs: AttachmentStore.referenced(items: items, revisions: revisions, in: mergedBlobs))
        try result.validate()
        return VaultImportMerge(document: result, addedCount: added, skippedCount: skipped, conflictCount: conflicts, warnings: warnings)
    }
    private static func equivalent(_ lhs: VaultItem, _ rhs: VaultItem) -> Bool {
        var left = lhs; var right = rhs
        left.id = right.id
        // Original formatting is provenance, not an edited field. Preserve unknown raw content for change detection.
        if let a = left.importedJSON, let b = right.importedJSON,
           let ao = try? JSONSerialization.jsonObject(with: Data(a.utf8)), let bo = try? JSONSerialization.jsonObject(with: Data(b.utf8)),
           let ad = try? JSONSerialization.data(withJSONObject: ao, options: [.sortedKeys]), let bd = try? JSONSerialization.data(withJSONObject: bo, options: [.sortedKeys]), ad == bd {
            left.importedJSON = nil; right.importedJSON = nil
        }
        return left == right
    }
    public static func encode(_ document: VaultTransferDocument, format: VaultExportFormat) throws -> Data {
        try document.validate()
        let bytes: Data
        switch format {
        case .nativeJSON:
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; bytes = try encoder.encode(document)
        case .onePIF:
            guard document.blobs.isEmpty else { throw VaultError.message("1PIF 单文件无法保留这些附件，请选择完整 JSON 或完整 CSV 导出。") }
            bytes = Data(try document.items.map { try encode1PIF($0, revisions: document.revisions) }.joined(separator: "\n***5642bee8-a5ff-11dc-8314-0800200c9a66***\n").utf8)
        case .csv: bytes = try encodeCSV(document)
        }
        guard bytes.count <= maximumTransferBytes else { throw VaultError.message("导出内容超过 32 MiB 限制。请减少数据后重试。") }
        return bytes
    }
    public static func export(_ document: VaultTransferDocument, to url: URL, format: VaultExportFormat) throws {
        try PlaintextExportWriter.write(encode(document, format: format), to: url)
    }
    static func encode1PIF(_ item: VaultItem, revisions: [VaultRevision]) throws -> String {
        var record = item.importedJSON.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? [:]
        // Never export a stale imported secureContents alongside the edited current fields.
        record["uuid"] = item.sourceIdentity?.hasPrefix("1pif:") == true ? String(item.sourceIdentity!.dropFirst(6)) : item.id.uuidString
        record["localvaultID"] = item.id.uuidString; record["title"] = item.title
        record["typeName"] = OnePasswordImporter.typeName(item.category); record["location"] = item.url
        record["createdAt"] = item.createdAt.timeIntervalSince1970; record["updatedAt"] = item.updatedAt.timeIntervalSince1970
        record["faveIndex"] = item.favorite ? 1 : 0; record["favIndex"] = item.favorite ? 1 : 0; record["tags"] = item.tags
        if var open = record["openContents"] as? [String: Any] { open["tags"] = item.tags; record["openContents"] = open }
        record["trashed"] = item.state == .trashed; record["archived"] = item.state == .archived; record["state"] = item.state.rawValue
        record["deletedAt"] = item.deletedAt.map { $0.timeIntervalSince1970 }
        var secure: [String: Any] = ["notesPlain": item.notes, "username": item.username, "password": item.password,
                                     "URLs": ([item.url] + item.additionalURLs).filter { !$0.isEmpty }.map { ["url": $0] }]
        var form: [[String: Any]] = [["designation":"username", "name":"username", "type":"T", "value":item.username], ["designation":"password", "name":"password", "type":"P", "value":item.password]]
        var sections: [[String: Any]] = []
        for section in item.sections {
            var fields: [[String: Any]] = []
            for field in section.fields {
                if let key = field.importedKey, key.hasPrefix("secure:") {
                    secure[String(key.dropFirst(7))] = try decodedOriginalValue(field)
                } else if let key = field.importedKey, key.hasPrefix("form:") {
                    form.append(["name":String(key.dropFirst(5)), "title":field.label, "value":field.value, "type":field.importedKind.flatMap { OnePasswordImporter.fieldKind($0) == field.kind ? $0 : nil } ?? (field.kind == .password ? "P" : "T")])
                } else {
                    fields.append(["n":field.importedKey ?? field.id.uuidString, "t":field.label, "v":sectionValue(field, sectionTitle: section.title, source: record), "k":field.importedKind.flatMap { OnePasswordImporter.fieldKind($0) == field.kind ? $0 : nil } ?? onePIFKind(field.kind), "localvaultID":field.id.uuidString])
                }
            }
            if !fields.isEmpty { sections.append(["title": section.title, "name":section.id.uuidString, "localvaultID":section.id.uuidString, "fields": fields]) }
        }
        secure["fields"] = form; secure["sections"] = sections
        secure["passwordHistory"] = revisions.filter { $0.snapshot.id == item.id && $0.snapshot.password != item.password }.map { ["value":$0.snapshot.password, "time":$0.createdAt.timeIntervalSince1970] as [String:Any] }
        record["secureContents"] = secure
        // A 1PUX source uses a different shape. Keep its original provenance only in the native full export.
        record.removeValue(forKey: "details"); record.removeValue(forKey: "overview")
        return String(data: try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]), encoding: .utf8)!
    }
    private static func sectionValue(_ field: VaultField, sectionTitle: String, source: [String: Any]) -> Any {
        // Preserve structured/numeric source value types, but always serialize the edited value.
        let secure = source["secureContents"] as? [String: Any] ?? source["details"] as? [String: Any] ?? [:]
        for section in secure["sections"] as? [[String: Any]] ?? [] {
            let originalTitle = section["title"] as? String ?? section["name"] as? String ?? ""
            guard originalTitle == sectionTitle else { continue }
            for originalField in section["fields"] as? [[String: Any]] ?? [] {
                let key = originalField["n"] as? String ?? originalField["name"] as? String ?? originalField["id"] as? String
                guard key != nil, key == field.importedKey else { continue }
                var value = originalField["v"] ?? originalField["value"]
                if source["details"] != nil, let typed = value as? [String: Any], typed.count == 1 { value = typed.values.first }
                if value is String { return field.value }
                if value is NSNull, field.value.isEmpty { return NSNull() }
                return (try? JSONSerialization.jsonObject(with: Data(field.value.utf8), options: [.fragmentsAllowed])) ?? field.value
            }
        }
        return field.value
    }
    private static func decodedOriginalValue(_ field: VaultField) throws -> Any {
        switch field.importedKind {
        case "null" where field.value.isEmpty: return NSNull()
        case "number", "boolean", "json", "null":
            guard let object = try? JSONSerialization.jsonObject(with: Data(field.value.utf8), options: [.fragmentsAllowed]) else { return field.value }
            return object
        default: return field.value
        }
    }
    private static func onePIFKind(_ kind: FieldKind) -> String {
        switch kind { case .password: return "concealed"; case .monthYear: return "monthYear"; case .otp: return "totp"; default: return kind.rawValue }
    }
    public static func decodeCSV(_ data: Data) throws -> VaultImportPreview {
        guard data.count <= maximumTransferBytes, let string = String(data: data, encoding: .utf8) else { throw VaultError.message("CSV 必须是 32 MiB 以内的 UTF-8 文件。") }
        let rows = try CSVCodec.parse(string)
        guard let header = rows.first, !header.isEmpty else { throw VaultError.message("CSV 缺少列标题。") }
        let keys = header.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard Set(keys).count == keys.count else { throw VaultError.message("CSV 列标题重复。") }
        var items: [VaultItem] = []; var revisions: [VaultRevision] = []; var warnings = [String](); var blobs: [String: Data] = [:]
        let hasRich = keys.contains("localvault_json")
        for (index, row) in rows.dropFirst().enumerated() {
            if row.allSatisfy(\.isEmpty) { continue }
            guard row.count == keys.count else { throw VaultError.message("CSV 第 \(index + 2) 行列数不匹配，整批未导入。") }
            let values = Dictionary(uniqueKeysWithValues: zip(keys, row))
            if let rich = values["localvault_json"], !rich.isEmpty {
                let part = try decodeJSON(Data(rich.utf8)).document
                guard part.items.count == 1 else { throw VaultError.message("CSV 完整数据列每行必须恰好含一个项目。") }
                var item = part.items[0]
                // Visible CSV columns are authoritative if a user edited them outside the app.
                item.title = values["title"] ?? item.title; item.username = values["username"] ?? item.username
                item.password = values["password"] ?? item.password; item.url = values["url"] ?? item.url
                item.notes = values["notes"] ?? item.notes
                if let category = values["category"] { item.category = category }
                if let state = values["state"] { guard let parsed = ItemState(rawValue: state) else { throw VaultError.message("CSV 项目状态无效。") }; item.state = parsed }
                items.append(item); revisions += part.revisions
                blobs = try AttachmentStore.merging(part.blobs, into: blobs)
            } else {
                let title = values["title"] ?? values["name"] ?? ""
                guard !title.isEmpty else { throw VaultError.message("CSV 第 \(index + 2) 行缺少 title/name。") }
                let canonical = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
                let identity = values["uuid"].flatMap { $0.isEmpty ? nil : "csv:" + $0 } ?? "csv-content:" + OnePasswordImporter.hexDigest(canonical)
                var item = VaultItem(id: OnePasswordImporter.stableID(identity), title: title,
                                     username: values["username"] ?? values["user name"] ?? "", password: values["password"] ?? "",
                                     url: values["url"] ?? values["website"] ?? "", notes: values["notes"] ?? "", category: values["category"] ?? "登录",
                                     updatedAt: Date(timeIntervalSince1970: 0), importedJSON: String(data: canonical, encoding: .utf8), createdAt: Date(timeIntervalSince1970: 0), sourceIdentity: identity)
                if let raw = values["state"], !raw.isEmpty { guard let state = ItemState(rawValue: raw) else { throw VaultError.message("CSV 项目状态无效。") }; item.state = state }
                if item.state == .trashed { item.deletedAt = item.updatedAt }
                if let tags = values["tags"], !tags.isEmpty { item.tags = tags.components(separatedBy: ";") }
                let known: Set<String> = ["title","name","username","user name","password","url","website","notes","category","state","tags","uuid","localvault_json"]
                let fields = keys.filter { !known.contains($0) }.map { VaultField(id: OnePasswordImporter.stableID(identity + ":" + $0), label: $0, value: values[$0]!, kind: .text) }
                if !fields.isEmpty { item.sections = [VaultSection(id: OnePasswordImporter.stableID(identity + ":extra"), title: "CSV 其他字段", fields: fields)] }
                items.append(item)
            }
        }
        if !hasRich { warnings.append("普通 CSV 不含完整历史或类型信息；额外列保留为文本字段。无来源 ID 的记录仅能按完全相同内容去重。") }
        guard !items.isEmpty else { throw VaultError.message("CSV 没有项目。") }
        let document = VaultTransferDocument(items: items, revisions: revisions, blobs: blobs); try document.validate()
        return VaultImportPreview(document: document, formatName: "CSV", warnings: warnings)
    }
    private static func encodeCSV(_ document: VaultTransferDocument) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var result = Data(["title","username","password","url","notes","category","state","localvault_json"].map(CSVCodec.quote).joined(separator: ",").utf8)
        for item in document.items {
            let revisions = document.revisions.filter { $0.snapshot.id == item.id }
            let part = VaultTransferDocument(items: [item], revisions: revisions, blobs: AttachmentStore.referenced(items: [item], revisions: revisions, in: document.blobs))
            let rich = String(data: try encoder.encode(part), encoding: .utf8)!
            let row = "\r\n" + [item.title,item.username,item.password,item.url,item.notes,item.category,item.state.rawValue,rich].map(CSVCodec.quote).joined(separator: ",")
            // Shared blobs repeat across CSV rows. Enforce the output budget
            // before retaining each expanded row, not after building all rows.
            guard row.utf8.count <= maximumTransferBytes - result.count else { throw VaultError.message("CSV 包含重复附件内容，超过 32 MiB 导出限制；请选择完整 JSON。") }
            result.append(contentsOf: row.utf8)
        }
        return result
    }
}

enum PlaintextExportWriter {
    static func write(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".passwordcraft-export-\(UUID().uuidString).tmp")
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw VaultError.message("无法创建导出文件，请检查目录权限。") }
        defer { Darwin.close(fd); unlink(temporary.path) }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw VaultError.message("导出写入失败，未发布半成品。") }; offset += written
            }
        }
        guard fsync(fd) == 0, renamex_np(temporary.path, url.path, UInt32(RENAME_EXCL)) == 0 else { throw VaultError.message("导出失败：文件已存在或磁盘写入失败，原文件未覆盖。") }
    }
}

private enum CSVCodec {
    static func quote(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
    static func parse(_ input: String) throws -> [[String]] {
        let input = input.hasPrefix("\u{feff}") ? String(input.dropFirst()) : input
        var rows: [[String]] = []; var row: [String] = []; var field = ""; var quoted = false; var closed = false
        var index = input.startIndex
        while index < input.endIndex {
            let character = input[index]; let next = input.index(after: index)
            if quoted {
                if character == "\"" {
                    if next < input.endIndex, input[next] == "\"" { field.append("\""); index = input.index(after: next); continue }
                    quoted = false; closed = true
                } else { field.append(character) }
            } else if character == "\"", field.isEmpty, !closed { quoted = true }
            else if character == "," { row.append(field); field = ""; closed = false }
            else if character == "\n" || character == "\r\n" || character == "\r" {
                row.append(field); rows.append(row); row = []; field = ""; closed = false
            } else {
                guard !closed, character != "\"" else { throw VaultError.message("CSV 引号格式不正确。") }; field.append(character)
            }
            index = next
        }
        guard !quoted else { throw VaultError.message("CSV 引号未结束。") }
        if !field.isEmpty || !row.isEmpty || closed { row.append(field); rows.append(row) }
        return rows
    }
}
