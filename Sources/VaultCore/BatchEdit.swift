import Foundation

public enum BatchEdit {
    public enum Operation { case archive, trash, restore, favorite(Bool), addTag(String) }
    /// Produces one complete candidate; callers commit once through VaultSession.save.
    public static func applying(_ operation: Operation, to items: [VaultItem], ids: Set<UUID>, at date: Date = Date()) throws -> [VaultItem] {
        guard !ids.isEmpty, ids.isSubset(of: Set(items.map(\.id))) else { throw VaultError.message("批量选择已经失效，请重新选择项目。") }
        if case .addTag(let tag) = operation, tag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw VaultError.message("标签不能为空。") }
        return try items.map { original in
            guard ids.contains(original.id) else { return original }
            var item = original
            switch operation {
            case .restore: item.state = .active; item.deletedAt = nil
            case .archive, .trash, .favorite, .addTag:
                guard original.state != .trashed else { throw VaultError.message("回收站内的项目请先恢复，再进行此批量操作。") }
                switch operation {
                case .archive: item.state = .archived
                case .trash: item.state = .trashed; item.deletedAt = date
                case .favorite(let value): item.favorite = value
                case .addTag(let value):
                    let tag = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !item.tags.contains(tag) { item.tags.append(tag) }
                case .restore: break
                }
            }
            if item != original { item.updatedAt = date }
            return item
        }
    }
}
