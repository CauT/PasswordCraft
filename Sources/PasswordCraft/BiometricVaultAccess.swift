import Foundation
import LocalAuthentication
import Security
import CryptoKit
import VaultCore

/// Preferences are only a UI hint. Unlock always requires protected Keychain
/// retrieval and authentication of the encrypted vault with the retrieved key.
@MainActor final class BiometricVaultAccess {
    struct Capability { let available: Bool; let explanation: String }
    private var activeContext: LAContext?
    private let service = (Bundle.main.bundleIdentifier ?? "io.github.CauT.PasswordCraft") + ".biometric-vault-key.v1"
    func capability() -> Capability {
        let context = LAContext()
        defer { context.invalidate() }
        var error: NSError?
        let available = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        guard available, context.biometryType == .touchID else {
            let explanation: String
            switch error?.code {
            case LAError.biometryNotPaired.rawValue: explanation = L("没有配对的 Touch ID 设备。请使用主密码解锁。")
            case LAError.biometryDisconnected.rawValue: explanation = L("Touch ID 设备未连接。请连接设备或使用主密码。")
            case LAError.biometryNotEnrolled.rawValue: explanation = L("系统尚未录入指纹。请使用主密码。")
            case LAError.biometryLockout.rawValue: explanation = L("Touch ID 暂时被系统锁定。请使用主密码。")
            default: explanation = L("当前无法使用 Touch ID。请使用主密码。")
            }
            return Capability(available: false, explanation: explanation)
        }
        return Capability(available: true, explanation: L("Touch ID 可用。主密码始终可用于解锁。"))
    }
    private func account(_ url: URL) -> String {
        SHA256.hash(data: Data(url.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func hint(_ url: URL) -> String { service + ".enabled." + account(url) }
    func isEnabled(_ url: URL) -> Bool { UserDefaults.standard.bool(forKey: hint(url)) }
    private func query(_ url: URL) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account(url), kSecUseDataProtectionKeychain as String: true,
         kSecAttrSynchronizable as String: false]
    }
    func enable(_ material: Data, for url: URL) throws {
        let status = capability()
        guard status.available else { throw VaultError.message(status.explanation) }
        var error: Unmanaged<CFError>?
        guard let control = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .biometryCurrentSet, &error) else {
            _ = error?.takeRetainedValue()
            throw VaultError.message(L("无法创建系统指纹保护，未保存设备解锁密钥。"))
        }
        var attributes = query(url)
        attributes[kSecAttrAccessControl as String] = control
        attributes[kSecValueData as String] = material
        attributes[kSecAttrLabel as String] = L("PasswordCraft Touch ID 解锁")
        let result = SecItemAdd(attributes as CFDictionary, nil)
        guard result == errSecSuccess else {
            if result == errSecDuplicateItem { throw VaultError.message(L("设备解锁记录已存在，请先停用 Touch ID，再重新启用。")) }
            throw VaultError.message(L("无法保存受指纹保护的密钥（系统代码 \(result)）。主密码解锁不受影响。"))
        }
        UserDefaults.standard.set(true, forKey: hint(url))
    }
    func disable(for url: URL) throws {
        cancel()
        let result = SecItemDelete(query(url) as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else {
            throw VaultError.message(L("无法移除设备解锁记录（系统代码 \(result)），请重试。"))
        }
        UserDefaults.standard.removeObject(forKey: hint(url))
    }
    func retrieve(for url: URL) async throws -> Data {
        let status = capability()
        guard status.available else { throw VaultError.message(status.explanation) }
        let context = LAContext()
        context.localizedReason = L("使用 Touch ID 解锁 PasswordCraft")
        context.localizedFallbackTitle = ""
        context.touchIDAuthenticationAllowableReuseDuration = 0
        activeContext = context
        var request = query(url)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        request[kSecUseAuthenticationContext as String] = context
        defer { context.invalidate(); if activeContext === context { activeContext = nil } }
        return try await Task.detached(priority: .userInitiated) {
            var result: CFTypeRef?
            let status = SecItemCopyMatching(request as CFDictionary, &result)
            guard status == errSecSuccess, let data = result as? Data else {
                throw VaultError.message(L("Touch ID 解锁未完成（系统代码 \(status)）。可以重试或使用主密码；主密码更改或指纹重新录入后需重新启用。"))
            }
            return data
        }.value
    }
    func cancel() { activeContext?.invalidate(); activeContext = nil }
}
