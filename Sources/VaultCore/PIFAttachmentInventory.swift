import Foundation

/// 1PIF names attachments by owner UUID and original basename, without an authenticated manifest.
struct PIFAttachmentInventory {
    private let files: [String: Data]
    private let byOwner: [String: [(path: String, name: String)]]
    private var consumed: Set<String> = []
    private(set) var blobs: [String: Data] = [:]
    init(files: [String: Data]) {
        self.files = files.filter { $0.key != "data.1pif" && $0.key.split(separator: "/").last != ".DS_Store" }
        var owners: [String: [(path: String, name: String)]] = [:]
        for path in self.files.keys.sorted() {
            let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            if parts.count == 3, parts[0] == "attachments" { owners[parts[1], default: []].append((path, parts[2])) }
        }
        byOwner = owners
    }
    mutating func resolve(owner: String, source: String) throws -> [VaultAttachment] {
        var attachments: [VaultAttachment] = []
        for entry in byOwner[owner] ?? [] {
            let data = files[entry.path]!
            guard AttachmentStore.validName(entry.name), data.count <= AttachmentStore.maximumAttachmentBytes else { throw invalid() }
            let attachment = VaultAttachment(id: OnePasswordImporter.stableID(source + ":attachment:" + entry.name), name: entry.name, data: data)
            attachments.append(attachment); blobs[attachment.blobID] = data; consumed.insert(entry.path)
        }
        return attachments
    }
    func requireComplete() throws {
        guard consumed == Set(files.keys) else { throw VaultError.message("1PIF 导出包有未关联附件、未知预览或额外文件，整批未导入。请保留完整原始导出。") }
    }
    private func invalid() -> VaultError { .message("1PIF 附件名称无效或超过 16 MiB，整批未导入。") }
}
