import Foundation
import VaultCore

/// Tests the cryptographic boundary, not LocalAuthentication/Keychain hardware.
func runDeviceUnlockChecks() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("device.localvault")
    let backups = root.appendingPathComponent("backups")
    let password = "Synthetic-device-master!"
    let session = try VaultSession.create(at: file, password: password, backupRoot: backups)
    let item = VaultItem(title: "device boundary", password: "Synthetic-item-secret!")
    try session.save(items: [item])
    let material = try session.deviceUnlockMaterial()
    let opened = try VaultSession.open(at: file, deviceUnlockMaterial: material, backupRoot: backups)
    XCTAssertEqual(opened.items, [item])
    opened.lock()
    XCTAssertThrowsError(try opened.deviceUnlockMaterial())
    XCTAssertThrowsError(try VaultSession.open(at: file, deviceUnlockMaterial: Data(repeating: 1, count: 1025), backupRoot: backups))
    var parts = try XCTUnwrap(JSONSerialization.jsonObject(with: material) as? [String: Any])
    parts["vaultID"] = UUID().uuidString
    XCTAssertThrowsError(try VaultSession.open(at: file, deviceUnlockMaterial: JSONSerialization.data(withJSONObject: parts), backupRoot: backups))
    parts = try XCTUnwrap(JSONSerialization.jsonObject(with: material) as? [String: Any])
    parts["key"] = Data(repeating: 0, count: 32).base64EncodedString()
    XCTAssertThrowsError(try VaultSession.open(at: file, deviceUnlockMaterial: JSONSerialization.data(withJSONObject: parts), backupRoot: backups))
    let foreign = root.appendingPathComponent("foreign.localvault")
    _ = try VaultSession.create(at: foreign, password: password, backupRoot: backups)
    XCTAssertThrowsError(try VaultSession.open(at: foreign, deviceUnlockMaterial: material, backupRoot: backups))
    var edited = item; edited.notes = "same key after edit"
    try session.save(items: [edited])
    try XCTAssertEqual(VaultSession.open(at: file, deviceUnlockMaterial: material, backupRoot: backups).items, [edited])
    try session.changePassword("Replacement-device-master!")
    XCTAssertThrowsError(try VaultSession.open(at: file, deviceUnlockMaterial: material, backupRoot: backups))
    let fresh = try session.deviceUnlockMaterial()
    try XCTAssertEqual(VaultSession.open(at: file, deviceUnlockMaterial: fresh, backupRoot: backups).items, [edited])
    let worker = VaultWorker(backupRoot: backups)
    await worker.invalidate(generation: 2)
    do { _ = try await worker.open(file, deviceUnlockMaterial: fresh, generation: 1); fatalError("stale device unlock") } catch {}
    _ = try await worker.open(file, deviceUnlockMaterial: fresh, generation: 3)
    await worker.cancel(generation: 1)
    let retrieved = try await worker.deviceUnlockMaterial(generation: 3)
    try XCTAssertEqual(VaultSession.open(at: file, deviceUnlockMaterial: retrieved, backupRoot: backups).items, [edited])
    await worker.invalidate(generation: 4)
    do { _ = try await worker.deviceUnlockMaterial(generation: 3); fatalError("locked key export") } catch {}
    print("PASS device key authentication, identity, corruption, lock, edit/rekey and worker cancellation boundaries (no biometric hardware claim)")
}
