import Foundation

public enum AppLanguage: String, CaseIterable, Sendable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    public static let preferenceKey = "PasswordCraft.language"
    public static var current: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? "") ?? .english
    }
    public var locale: Locale { Locale(identifier: rawValue) }
}

/// A message separates a translation key from interpolated values. Values are
/// never parsed, translated, or substituted again, including literal "{0}" text.
public struct LocalizedMessage: ExpressibleByStringLiteral, ExpressibleByStringInterpolation, Sendable {
    let key: String
    let arguments: [String]
    public init(stringLiteral value: String) { key = value; arguments = [] }
    public init(stringInterpolation: StringInterpolation) {
        key = stringInterpolation.key; arguments = stringInterpolation.arguments
    }
    public struct StringInterpolation: StringInterpolationProtocol {
        var key = ""
        var arguments: [String] = []
        public init(literalCapacity: Int, interpolationCount: Int) {
            key.reserveCapacity(literalCapacity); arguments.reserveCapacity(interpolationCount)
        }
        public mutating func appendLiteral(_ literal: String) { key += literal }
        public mutating func appendInterpolation<T>(_ value: T) {
            key += "{\(arguments.count)}"; arguments.append(String(describing: value))
        }
    }
    public func rendered(language: AppLanguage) -> String {
        let template = language == .english ? EnglishCatalog.messages[key] ?? key : key
        // Scan the template once. Argument text must never become format syntax.
        var result = ""; var cursor = template.startIndex
        while cursor < template.endIndex {
            if template[cursor] == "{", let end = template[cursor...].firstIndex(of: "}"),
               let index = Int(template[template.index(after: cursor)..<end]), arguments.indices.contains(index) {
                result += arguments[index]; cursor = template.index(after: end)
            } else { result.append(template[cursor]); cursor = template.index(after: cursor) }
        }
        return result
    }
}

public func L(_ message: LocalizedMessage) -> String { message.rendered(language: .current) }

public enum L10n {
    /// Only use for known application labels, never arbitrary item text.
    public static func label(_ key: String, language: AppLanguage = .current) -> String {
        language == .english ? EnglishCatalog.messages[key] ?? key : key
    }
    public static func category(_ value: String) -> String {
        ItemTemplates.categories.contains(value) ? label(value) : value
    }
}
