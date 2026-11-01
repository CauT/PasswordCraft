import Foundation
import CryptoKit

/// RFC6238 generator. Provisioning input remains in the encrypted item's OTP field.
public struct TOTPConfiguration {
    public enum Algorithm: String { case sha1 = "SHA1", sha256 = "SHA256", sha512 = "SHA512" }
    private let secret: Data
    public let algorithm: Algorithm
    public let digits: Int
    public let period: Int

    public init(_ input: String) throws {
        guard input.utf8.count <= 8192 else { throw Self.invalid("验证码设置过长。") }
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var encoded = value
        var algorithm = Algorithm.sha1; var digits = 6; var period = 30
        if value.lowercased().hasPrefix("otpauth:") {
            guard let url = URLComponents(string: value), url.scheme?.lowercased() == "otpauth", url.host?.lowercased() == "totp",
                  url.user == nil, url.password == nil, url.port == nil, url.fragment == nil, url.path.count > 1 else {
                throw Self.invalid("需要 otpauth://totp/ 链接；不支持计数器 HOTP。")
            }
            var parameters: [String: String] = [:]
            for query in url.queryItems ?? [] {
                let key = query.name.lowercased()
                guard ["secret", "issuer", "algorithm", "digits", "period"].contains(key), parameters[key] == nil, let content = query.value else {
                    throw Self.invalid("验证码链接包含未知、重复或缺少值的参数。")
                }
                parameters[key] = content
            }
            guard let key = parameters["secret"], !key.isEmpty else { throw Self.invalid("验证码链接缺少 secret。") }
            encoded = key
            if let name = parameters["algorithm"] {
                guard let parsed = Algorithm(rawValue: name.uppercased()) else { throw Self.invalid("仅支持 SHA1、SHA256 和 SHA512。") }
                algorithm = parsed
            }
            if let count = parameters["digits"] {
                guard let parsed = Int(count), (6...8).contains(parsed) else { throw Self.invalid("验证码位数需要是 6、7 或 8。") }
                digits = parsed
            }
            if let interval = parameters["period"] {
                guard let parsed = Int(interval), parsed > 0, parsed <= Int(Int32.max) else { throw Self.invalid("验证码周期必须是正的 32 位秒数。") }
                period = parsed
            }
        }
        secret = try Self.decodeBase32(encoded)
        self.algorithm = algorithm; self.digits = digits; self.period = period
    }

    public struct Code: Equatable {
        public let value: String
        public let validUntil: Date
        public func remaining(at date: Date) -> TimeInterval { max(0, validUntil.timeIntervalSince(date)) }
    }
    public func code(at date: Date = Date()) throws -> Code {
        let seconds = date.timeIntervalSince1970
        // Double(UInt64.max) rounds up; the strict bound avoids integer conversion traps.
        let tick = floor(seconds / Double(period))
        guard seconds.isFinite, seconds >= 0, tick < Double(UInt64.max) else { throw Self.invalid("系统时间不适用于验证码生成。") }
        var counter = UInt64(tick).bigEndian
        let message = withUnsafeBytes(of: &counter) { Data($0) }
        let key = SymmetricKey(data: secret)
        let hash: [UInt8]
        switch algorithm {
        case .sha1: hash = Array(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: key))
        case .sha256: hash = Array(HMAC<SHA256>.authenticationCode(for: message, using: key))
        case .sha512: hash = Array(HMAC<SHA512>.authenticationCode(for: message, using: key))
        }
        let offset = Int(hash.last! & 0x0f)
        let truncated = (UInt32(hash[offset] & 0x7f) << 24) | (UInt32(hash[offset+1]) << 16) | (UInt32(hash[offset+2]) << 8) | UInt32(hash[offset+3])
        let modulus = (0..<digits).reduce(UInt32(1)) { value, _ in value * 10 }
        let text = String(truncated % modulus)
        return Code(value: String(repeating: "0", count: digits - text.count) + text,
                    validUntil: Date(timeIntervalSince1970: (tick + 1) * Double(period)))
    }

    private static func decodeBase32(_ input: String) throws -> Data {
        let normalized = input.filter { !$0.isWhitespace }.uppercased()
        let symbols = Array(normalized.utf8)
        let padStart = symbols.firstIndex(of: 61) ?? symbols.count
        let data = Array(symbols.prefix(padStart)); let padding = symbols.count - padStart
        guard !data.isEmpty, data.count <= 4096,
              symbols.dropFirst(padStart).allSatisfy({ $0 == 61 }),
              [0, 2, 4, 5, 7].contains(data.count % 8),
              padding == 0 || (symbols.count % 8 == 0 && padding == (8 - data.count % 8) % 8) else {
            throw invalid("密钥不是有效的 Base32 编码。")
        }
        var bits: UInt32 = 0; var count = 0; var result = Data()
        for symbol in data {
            let value: UInt32
            switch symbol {
            case 65...90: value = UInt32(symbol - 65)
            case 50...55: value = UInt32(symbol - 50 + 26)
            default: throw invalid("Base32 密钥只能包含 A–Z、2–7 和末尾填充符。")
            }
            bits = (bits << 5) | value; count += 5
            if count >= 8 { count -= 8; result.append(UInt8((bits >> count) & 255)) }
            bits &= (1 << count) - 1
        }
        guard bits == 0, !result.isEmpty else { throw invalid("Base32 密钥含有无效的末尾位。") }
        return result
    }
    private static func invalid(_ message: String) -> VaultError { .message(message) }
}
