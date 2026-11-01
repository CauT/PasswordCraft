import Foundation
import CommonCrypto
import CryptoKit
import CoreFoundation

/// Compatibility reader for Agile Keychain. CBC padding and key validation are not data authentication.
enum AgileKeychainCrypto {
    static func iterations(_ value: Any?) throws -> Int {
        if value == nil { return 1000 }
        let count: Int?
        if let string = value as? String, !string.isEmpty, string.utf8.allSatisfy({ (48...57).contains($0) }) { count = Int(string) }
        else if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
                number.doubleValue >= 0, number.doubleValue <= 10_000_000, number.doubleValue == Double(number.intValue) { count = number.intValue }
        else { count = nil }
        guard let count, (0...10_000_000).contains(count) else { throw invalid() }
        return max(1000, count)
    }
    static func unlock(_ record: [String: Any], password: String) throws -> Data {
        let rounds = try iterations(record["iterations"]), envelope = try split(base64(record["data"]))
        let salt = envelope.salt ?? Data(repeating: 0, count: 16)
        var derived = [UInt8](repeating: 0, count: 32)
        let status = password.withCString { pointer in
            salt.withUnsafeBytes { bytes in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pointer, password.utf8.count, bytes.bindMemory(to: UInt8.self).baseAddress!, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), UInt32(rounds), &derived, derived.count)
            }
        }
        guard status == kCCSuccess else { throw invalid() }
        let key = try decrypt(envelope.ciphertext, key: Data(derived.prefix(16)), iv: Data(derived.suffix(16)))
        guard key.count == 1024 else { throw invalid() }
        let validation = try open(base64(record["validation"]), key: key)
        guard validation.count == key.count else { throw invalid() }
        var difference: UInt8 = 0
        for (a, b) in zip(validation, key) { difference |= a ^ b }
        guard difference == 0 else { throw invalid() }
        return key
    }
    static func open(_ bytes: Data, key: Data) throws -> Data {
        let envelope = try split(bytes)
        if let salt = envelope.salt {
            let aesKey = Data(Insecure.MD5.hash(data: key + salt))
            let iv = Data(Insecure.MD5.hash(data: aesKey + key + salt))
            return try decrypt(envelope.ciphertext, key: aesKey, iv: iv)
        }
        return try decrypt(envelope.ciphertext, key: Data(Insecure.MD5.hash(data: key)), iv: Data(repeating: 0, count: 16))
    }
    static func base64(_ value: Any?) throws -> Data {
        guard var string = value as? String else { throw invalid() }
        // Legacy JSON encoders appended a single C terminator, present in independent samples.
        if string.last == "\0" { string.removeLast() }
        guard let bytes = Data(base64Encoded: string), bytes.base64EncodedString() == string else { throw invalid() }
        return bytes
    }
    private static func split(_ bytes: Data) throws -> (salt: Data?, ciphertext: Data) {
        let salted = bytes.prefix(8) == Data("Salted__".utf8), offset = salted ? 16 : 0
        guard bytes.count >= offset + 16, (bytes.count - offset) % 16 == 0 else { throw invalid() }
        return (salted ? Data(bytes[8..<16]) : nil, Data(bytes.dropFirst(offset)))
    }
    private static func decrypt(_ ciphertext: Data, key: Data, iv: Data) throws -> Data {
        var output = [UInt8](repeating: 0, count: ciphertext.count + 16), written = 0
        let capacity = output.count
        let status = key.withUnsafeBytes { keyBytes in iv.withUnsafeBytes { ivBytes in ciphertext.withUnsafeBytes { input in
            CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding), keyBytes.baseAddress!, key.count, ivBytes.baseAddress!, input.baseAddress!, ciphertext.count, &output, capacity, &written)
        } } }
        guard status == kCCSuccess else { throw invalid() }
        return Data(output.prefix(written))
    }
    static func invalid() -> VaultError { .message(L("AgileKeychain 密码不正确、加密数据损坏或格式超出支持范围；整批未导入。")) }
}
