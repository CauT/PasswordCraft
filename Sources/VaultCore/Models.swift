import Foundation

public enum ItemState: String, Codable, CaseIterable { case active, archived, trashed }
public enum FieldKind: String, Codable, CaseIterable { case text, password, url, email, date, monthYear, phone, otp }

public struct VaultField: Codable, Identifiable, Equatable {
    public var id: UUID
    public var label: String
    public var value: String
    public var kind: FieldKind
    public var importedKind: String?
    public var importedKey: String?
    public init(id: UUID = UUID(), label: String, value: String = "", kind: FieldKind = .text, importedKind: String? = nil, importedKey: String? = nil) {
        self.id = id; self.label = label; self.value = value; self.kind = kind
        self.importedKind = importedKind; self.importedKey = importedKey
    }
}

public struct VaultSection: Codable, Identifiable, Equatable {
    public var id: UUID
    public var title: String
    public var fields: [VaultField]
    public init(id: UUID = UUID(), title: String = "", fields: [VaultField] = []) {
        self.id = id; self.title = title; self.fields = fields
    }
}

public struct VaultItem: Codable, Identifiable, Equatable {
    public var id: UUID
    public var title: String
    public var username: String
    public var password: String
    public var url: String
    public var notes: String
    public var category: String
    public var favorite: Bool
    public var updatedAt: Date
    public var importedJSON: String?
    public var createdAt: Date
    public var state: ItemState
    public var deletedAt: Date?
    public var tags: [String]
    public var additionalURLs: [String]
    public var sections: [VaultSection]
    public var sourceIdentity: String?
    public var attachments: [VaultAttachment]
    public init(id: UUID = UUID(), title: String = "", username: String = "", password: String = "", url: String = "", notes: String = "", category: String = "登录", favorite: Bool = false, updatedAt: Date = Date(), importedJSON: String? = nil, createdAt: Date? = nil, state: ItemState = .active, deletedAt: Date? = nil, tags: [String] = [], additionalURLs: [String] = [], sections: [VaultSection] = [], sourceIdentity: String? = nil, attachments: [VaultAttachment] = []) {
        self.id = id; self.title = title; self.username = username; self.password = password
        self.url = url; self.notes = notes; self.category = category; self.favorite = favorite
        self.updatedAt = updatedAt; self.importedJSON = importedJSON; self.createdAt = createdAt ?? updatedAt
        self.state = state; self.deletedAt = deletedAt; self.tags = tags; self.additionalURLs = additionalURLs
        self.sections = sections; self.sourceIdentity = sourceIdentity
        self.attachments = attachments
    }
    enum CodingKeys: String, CodingKey {
        case id, title, username, password, url, notes, category, favorite, updatedAt, importedJSON
        case createdAt, state, deletedAt, tags, additionalURLs, sections, sourceIdentity, attachments
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        username = try c.decode(String.self, forKey: .username)
        password = try c.decode(String.self, forKey: .password)
        url = try c.decode(String.self, forKey: .url)
        notes = try c.decode(String.self, forKey: .notes)
        category = try c.decode(String.self, forKey: .category)
        favorite = try c.decode(Bool.self, forKey: .favorite)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        importedJSON = try c.decodeIfPresent(String.self, forKey: .importedJSON)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? updatedAt
        state = try c.decodeIfPresent(ItemState.self, forKey: .state) ?? .active
        deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        additionalURLs = try c.decodeIfPresent([String].self, forKey: .additionalURLs) ?? []
        sections = try c.decodeIfPresent([VaultSection].self, forKey: .sections) ?? []
        sourceIdentity = try c.decodeIfPresent(String.self, forKey: .sourceIdentity)
        attachments = try c.decodeIfPresent([VaultAttachment].self, forKey: .attachments) ?? []
    }
}

public struct VaultRevision: Codable, Identifiable, Equatable {
    public var id: UUID
    public var createdAt: Date
    public var snapshot: VaultItem
    public var itemID: UUID { snapshot.id }
    public init(id: UUID = UUID(), createdAt: Date = Date(), snapshot: VaultItem) {
        self.id = id; self.createdAt = createdAt; self.snapshot = snapshot
    }
}

struct VaultDocument: Codable {
    let schemaVersion: Int
    let id: UUID
    var items: [VaultItem]
    var revisions: [VaultRevision]
    var blobs: [String: Data]
    init(id: UUID = UUID(), items: [VaultItem] = [], revisions: [VaultRevision] = [], blobs: [String: Data] = [:]) {
        schemaVersion = 3; self.id = id; self.items = items; self.revisions = revisions; self.blobs = blobs
    }
    enum CodingKeys: String, CodingKey { case schemaVersion, id, items, revisions, blobs }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .schemaVersion)
        guard [2, 3].contains(version) else { throw VaultError.message(L("不支持的密码库数据版本。")) }
        id = try c.decode(UUID.self, forKey: .id)
        items = try c.decode([VaultItem].self, forKey: .items)
        revisions = try c.decode([VaultRevision].self, forKey: .revisions)
        blobs = try c.decodeIfPresent([String: Data].self, forKey: .blobs) ?? [:]
        guard version == 3 || (blobs.isEmpty && (items + revisions.map(\.snapshot)).allSatisfy({ $0.attachments.isEmpty })) else { throw VaultError.message(L("旧格式不能包含附件。")) }
        schemaVersion = 3
    }
}

public struct VaultBackup: Identifiable, Equatable {
    public let url: URL
    public let createdAt: Date
    public let reason: String
    public let usesCurrentPassword: Bool
    public let formatVersion: Int
    public var id: String { url.lastPathComponent }
}

public struct VaultSnapshot {
    public let items: [VaultItem]
    public let revisions: [VaultRevision]
    public let blobs: [String: Data]
    public let backups: [VaultBackup]
    public let backupDirectory: URL
    public let warning: String?
}
