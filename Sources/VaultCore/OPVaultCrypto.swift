import Foundation
import CommonCrypto
import CryptoKit

/// OPVault's encrypt-then-MAC format. No plaintext is returned before authentication.
struct OPVaultKeys {
    let encryption: Data
    let authentication: Data
    init(_ bytes: Data) throws {
        guard bytes.count == 64 else { throw OPVaultCrypto.invalid() }
        encryption = Data(bytes.prefix(32)); authentication = Data(bytes.suffix(32))
    }
}

enum OPVaultCrypto {
    static func derive(password: String, salt: Data, iterations: Int) throws -> OPVaultKeys {
        guard salt.count == 16, (1...10_000_000).contains(iterations) else { throw VaultError.message(L("OPVault 的盐或 PBKDF2 参数无效或超过读取范围。")) }
        var result = [UInt8](repeating: 0, count: 64)
        let status = password.withCString { pointer in
            salt.withUnsafeBytes { bytes in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pointer, password.utf8.count, bytes.bindMemory(to: UInt8.self).baseAddress!, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512), UInt32(iterations), &result, result.count)
            }
        }
        guard status == kCCSuccess else { throw invalid() }
        return try OPVaultKeys(Data(result))
    }
    static func seedKeys(_ bytes: Data, keys: OPVaultKeys, expectedSize: Int) throws -> OPVaultKeys {
        let seed = try open(bytes, keys: keys, maximumBytes: expectedSize)
        guard seed.count == expectedSize else { throw invalid() }
        return try OPVaultKeys(Data(SHA512.hash(data: seed)))
    }
    static func itemKeys(_ bytes: Data, master: OPVaultKeys) throws -> OPVaultKeys {
        guard bytes.count == 112 else { throw invalid() }
        try authenticate(bytes, keys: master)
        return try OPVaultKeys(decrypt(Data(bytes[16..<80]), iv: Data(bytes.prefix(16)), key: master.encryption))
    }
    static func open(_ bytes: Data, keys: OPVaultKeys, maximumBytes: Int) throws -> Data {
        guard bytes.count >= 80, bytes.prefix(8) == Data("opdata01".utf8), (bytes.count - 64) % 16 == 0 else { throw invalid() }
        try authenticate(bytes, keys: keys)
        let length = bytes[8..<16].enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * $1.offset) }
        guard length <= UInt64(maximumBytes), length <= UInt64(Int.max) else { throw invalid() }
        let count = Int(length), paddedCount = bytes.count - 64
        guard paddedCount == count + 16 - count % 16 else { throw invalid() }
        let plaintext = try decrypt(Data(bytes[32..<(bytes.count - 32)]), iv: Data(bytes[16..<32]), key: keys.encryption)
        return Data(plaintext.suffix(count))
    }
    static func verify(_ mac: Data, message: Data, keys: OPVaultKeys) throws {
        guard mac.count == 32, HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: message, using: SymmetricKey(data: keys.authentication)) else {
            throw VaultError.message(L("OPVault 密码不正确，或数据的完整性校验失败；整批未导入。"))
        }
    }
    private static func authenticate(_ data: Data, keys: OPVaultKeys) throws {
        try verify(Data(data.suffix(32)), message: Data(data.dropLast(32)), keys: keys)
    }
    private static func decrypt(_ ciphertext: Data, iv: Data, key: Data) throws -> Data {
        guard key.count == 32, iv.count == 16, !ciphertext.isEmpty, ciphertext.count % 16 == 0 else { throw invalid() }
        var output = [UInt8](repeating: 0, count: ciphertext.count)
        var written = 0
        let capacity = output.count
        let status = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                ciphertext.withUnsafeBytes { input in
                    CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(0), keyBytes.baseAddress!, key.count, ivBytes.baseAddress!, input.baseAddress!, ciphertext.count, &output, capacity, &written)
                }
            }
        }
        guard status == kCCSuccess, written == ciphertext.count else { throw invalid() }
        return Data(output)
    }
    static func base64(_ value: Any?) throws -> Data {
        guard let string = value as? String, let bytes = Data(base64Encoded: string), bytes.base64EncodedString() == string else { throw invalid() }
        return bytes
    }
    static func invalid() -> VaultError { .message(L("OPVault 加密结构无效或超出读取范围；整批未导入。")) }
}
