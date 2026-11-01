import Foundation

/// Offline advisory rules, not an entropy estimate or an online breach check.
public enum PasswordHealth {
    public enum Reason: String, Equatable {
        case short, common, repeating, sequence, reused
        public var explanation: String {
            switch self {
            case .short: return "少于 12 个字符"
            case .common: return "包含常见易猜密码模式"
            case .repeating: return "由短模式重复组成"
            case .sequence: return "包含连续数字、字母或键盘顺序"
            case .reused: return "与其他项目使用相同密码"
            }
        }
    }
    public struct Finding: Identifiable, Equatable {
        public let itemID: UUID
        public let reasons: [Reason]
        public let reuseCount: Int
        public var id: UUID { itemID }
    }
    public static func inspect(_ items: [VaultItem]) -> [Finding] {
        let candidates = items.filter { $0.state != .trashed && !$0.password.isEmpty }
        let grouped = Dictionary(grouping: candidates, by: \.password)
        return candidates.compactMap { item in
            let password = item.password
            let lower = password.lowercased()
            var reasons: [Reason] = []
            if password.count < 12 { reasons.append(.short) }
            if ["password", "qwerty", "letmein", "welcome", "admin", "changeme"].contains(where: { lower == $0 || lower.hasPrefix($0) && lower.dropFirst($0.count).allSatisfy { $0.isNumber || !$0.isLetter } }) { reasons.append(.common) }
            let characters = Array(password)
            if (1...min(4,characters.count)).contains(where: { width in characters.count >= width*3 && characters.enumerated().allSatisfy { $0.element == characters[$0.offset % width] } }) { reasons.append(.repeating) }
            if ["012345", "123456", "654321", "abcdef", "fedcba", "qwerty", "asdfgh"].contains(where: lower.contains) { reasons.append(.sequence) }
            let reuse = grouped[password]?.count ?? 1
            if reuse > 1 { reasons.append(.reused) }
            return reasons.isEmpty ? nil : Finding(itemID: item.id, reasons: reasons, reuseCount: reuse)
        }
    }
}
