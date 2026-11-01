import Foundation

/// Paths identify independently opened files; vault IDs inside copied backups are
/// intentionally not usable as workspace keys. Only unlocked items leave the actor.
public struct UnlockedVault: Identifiable {
    public let url: URL
    public let items: [VaultItem]
    public let masterPassword: Bool
    public var id: URL { url }
}

public struct VaultWorkspaceSnapshot {
    public let active: VaultSnapshot?
    public let unlockedVaults: [UnlockedVault]
}

public struct VaultSearchHit: Identifiable {
    public struct ID: Hashable { public let vaultURL: URL; public let itemID: UUID }
    public let vaultURL: URL
    public let item: VaultItem
    public var id: ID { ID(vaultURL: vaultURL, itemID: item.id) }
}

public enum VaultSearch {
    public static func matches(_ item: VaultItem, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let fields = item.sections.flatMap { section in
            [section.title] + section.fields.flatMap { [$0.label] + ($0.kind == .password || $0.kind == .otp ? [] : [$0.value]) }
        }
        let values = [item.title, item.username, item.url, item.notes, item.category] + item.tags + item.additionalURLs + fields
        return values.contains { $0.localizedCaseInsensitiveContains(query) }
    }
    public static func search(_ vaults: [UnlockedVault], query: String) -> [VaultSearchHit] {
        vaults.flatMap { vault in
            vault.items.filter { $0.state == .active && matches($0, query: query) }.map { VaultSearchHit(vaultURL: vault.url, item: $0) }
        }.sorted {
            let order = $0.item.title.localizedStandardCompare($1.item.title)
            if order != .orderedSame { return order == .orderedAscending }
            if $0.vaultURL != $1.vaultURL { return $0.vaultURL.path < $1.vaultURL.path }
            return $0.item.id.uuidString < $1.item.id.uuidString
        }
    }
}

public enum VaultMoveResult {
    case copied(Int, warning: String?)
    case moved(Int, warning: String?)
    case sourceRetained(Int, reason: String)

    public var message: String {
        switch self {
        case .copied(let count, let warning):
            return "已复制 \(count) 个项目及历史、附件。重复执行不会增加相同副本。" + suffix(warning)
        case .moved(let count, let warning):
            return "已移动 \(count) 个项目及历史、附件。源库副本保留在回收站和已有备份中。" + suffix(warning)
        case .sourceRetained(let count, let reason):
            return "目标库已保存 \(count) 个项目，但源库移入回收站未完成。源项目保留；请核对两库后重试。\(reason)"
        }
    }
    private func suffix(_ warning: String?) -> String {
        guard let warning, !warning.isEmpty else { return "" }; return "\n" + warning
    }
}
