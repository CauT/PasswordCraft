import Foundation
import VaultCore
import CryptoKit

final class VaultCoreTests {
    var directory: URL!
    let password = "Test-only long password 123!"
    func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    var file: URL { directory.appendingPathComponent("test.localvault") }
    func testPersistenceEncryptionLockAndBackup() throws {
        let session = try VaultSession.create(at: file, password: password, backupRoot: directory.appendingPathComponent("backups"))
        let item = VaultItem(title: "test-site", username: "user", password: "plaintext-secret-do-not-store", notes: "private", importedJSON: "{\"custom\":true}")
        try session.save(items: [item])
        let bytes = try Data(contentsOf: file)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains(item.password))
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let backup = directory.appendingPathComponent("backup.localvault")
        try session.backup(to: backup)
        try XCTAssertEqual(bytes, Data(contentsOf: backup))
        XCTAssertThrowsError(try session.backup(to: backup))
        try XCTAssertEqual(bytes, Data(contentsOf: backup))
        let remaining = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertFalse(remaining.contains { $0.pathExtension == "tmp" })
        session.lock(); XCTAssertFalse(session.isUnlocked); XCTAssertTrue(session.items.isEmpty)
        XCTAssertThrowsError(try session.save(items: [item]))
        let reopened = try VaultSession.open(at: file, password: password, backupRoot: directory.appendingPathComponent("backups"))
        XCTAssertEqual(reopened.items, [item])
    }
    func testWrongPasswordAndTamperingFail() throws {
        _ = try VaultSession.create(at: file, password: password, backupRoot: directory.appendingPathComponent("backups"))
        XCTAssertThrowsError(try VaultSession.open(at: file, password: "incorrect password", backupRoot: directory.appendingPathComponent("backups")))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var sealed = try XCTUnwrap(Data(base64Encoded: object["sealed"] as! String))
        sealed[sealed.count - 1] ^= 1
        object["sealed"] = sealed.base64EncodedString()
        try JSONSerialization.data(withJSONObject: object).write(to: file)
        XCTAssertThrowsError(try VaultSession.open(at: file, password: password, backupRoot: directory.appendingPathComponent("backups")))
    }
    func testMalformedParametersAndUnknownVersionFail() throws {
        _ = try VaultSession.create(at: file, password: password, backupRoot: directory.appendingPathComponent("backups"))
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        for (key, value) in [("rounds", 1), ("rounds", 4_000_000_000), ("version", 99), ("version", 2)] {
            var object = original; object[key] = value
            try JSONSerialization.data(withJSONObject: object).write(to: file)
            XCTAssertThrowsError(try VaultSession.open(at: file, password: password, backupRoot: directory.appendingPathComponent("backups")))
        }
    }
    func testConflictingSaveAndCreateNeverOverwrite() throws {
        let first = try VaultSession.create(at: file, password: password, backupRoot: directory.appendingPathComponent("backups"))
        let second = try VaultSession.open(at: file, password: password, backupRoot: directory.appendingPathComponent("backups"))
        let item = VaultItem(title: "first")
        try first.save(items: [item])
        let saved = try Data(contentsOf: file)
        XCTAssertThrowsError(try second.save(items: [VaultItem(title: "second")]))
        XCTAssertThrowsError(try VaultSession.create(at: file, password: password, backupRoot: directory.appendingPathComponent("backups")))
        try XCTAssertEqual(Data(contentsOf: file), saved)
        XCTAssertEqual(second.items, [])
    }
    func testSaveFailurePreservesMemory() throws {
        let session = try VaultSession.create(at: file, password: password, backupRoot: directory.appendingPathComponent("backups"))
        try FileManager.default.removeItem(at: file)
        XCTAssertThrowsError(try session.save(items: [VaultItem(title: "unsaved")]))
        XCTAssertTrue(session.items.isEmpty)
    }
    func testPasswordChangeAndDuplicateIDs() throws {
        let session = try VaultSession.create(at: file, password: password, backupRoot: directory.appendingPathComponent("backups"))
        let item = VaultItem(title: "same")
        XCTAssertThrowsError(try session.save(items: [item, item]))
        try session.save(items: [item])
        try session.changePassword("New test passphrase 456!")
        XCTAssertThrowsError(try VaultSession.open(at: file, password: password, backupRoot: directory.appendingPathComponent("backups")))
        try XCTAssertEqual(VaultSession.open(at: file, password: "New test passphrase 456!", backupRoot: directory.appendingPathComponent("backups")).items, [item])
    }
    func testImportPreservesAllFieldsAndRejectsPartial() throws {
        let line = #"{"title":"Example","typeName":"webforms.WebForm","location":"https://example.test","secureContents":{"fields":[{"designation":"username","value":"alice"},{"designation":"password","value":"secret"}],"notesPlain":"memo","sections":[{"custom":"retained"}]},"uuid":"original-id"}"#
        let imported = try OnePasswordImporter.parse(line + "\n***5642bee8-a5ff-11dc-8314-0800200c9a66***\n")
        XCTAssertEqual(imported.count, 1)
        XCTAssertEqual(imported[0].username, "alice"); XCTAssertEqual(imported[0].password, "secret")
        XCTAssertEqual(imported[0].importedJSON, line)
        let unicodeLine = line.replacingOccurrences(of: "memo", with: "memo\u{2028}line\u{0085}next\u{2029}end")
        let unicodeImported = try OnePasswordImporter.parse(unicodeLine + "\r\n***5642bee8-a5ff-11dc-8314-0800200c9a66***\r\n")
        XCTAssertEqual(unicodeImported[0].notes, "memo\u{2028}line\u{0085}next\u{2029}end")
        XCTAssertEqual(unicodeImported[0].importedJSON, unicodeLine)
        XCTAssertThrowsError(try OnePasswordImporter.parse(line + "\n{broken"))
        XCTAssertThrowsError(try OnePasswordImporter.parse(#"{"title":"Document","typeName":"securenotes.SecureNote","secureContents":{"attachments":[{"name":"doc"}]}}"#))
    }
    func testImportDirectoryRejectsAttachments() throws {
        try Data().write(to: directory.appendingPathComponent("data.1pif"))
        try Data().write(to: directory.appendingPathComponent("attachment.pdf"))
        XCTAssertThrowsError(try OnePasswordImporter.read(from: directory))
    }
    func testPasswordGeneratorAndMinimumMasterPassword() throws {
        let passwords = try (0..<100).map { _ in try PasswordGenerator.generate() }
        XCTAssertEqual(Set(passwords).count, 100)
        XCTAssertTrue(passwords.allSatisfy { $0.count == 24 })
        XCTAssertThrowsError(try PasswordGenerator.generate(length: 1))
        XCTAssertThrowsError(try VaultSession.create(at: file, password: "short", backupRoot: directory.appendingPathComponent("backups")))
    }
    func testSymlinkRejected() throws {
        let destination = directory.appendingPathComponent("real.localvault")
        _ = try VaultSession.create(at: destination, password: password, backupRoot: directory.appendingPathComponent("backups"))
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: destination)
        XCTAssertThrowsError(try VaultSession.open(at: file, password: password, backupRoot: directory.appendingPathComponent("backups")))
        XCTAssertThrowsError(try OnePasswordImporter.read(from: file))
    }
    func testImportSizeBound() throws {
        let large = directory.appendingPathComponent("oversized.1pif")
        XCTAssertTrue(FileManager.default.createFile(atPath: large.path, contents: nil))
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: UInt64(32 * 1024 * 1024 + 1))
        try handle.close()
        XCTAssertThrowsError(try OnePasswordImporter.read(from: large))
    }
}


func XCTAssertTrue(_ value: @autoclosure () throws -> Bool, file: StaticString = #filePath, line: UInt = #line) rethrows {
    if try !value() { fatalError("Assertion true failed at \(file):\(line)") }
}
func XCTAssertFalse(_ value: @autoclosure () throws -> Bool, file: StaticString = #filePath, line: UInt = #line) rethrows {
    if try value() { fatalError("Assertion false failed at \(file):\(line)") }
}
func XCTAssertEqual<T: Equatable>(_ lhs: @autoclosure () throws -> T, _ rhs: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) rethrows {
    if try lhs() != rhs() { fatalError("Assertion equal failed at \(file):\(line)") }
}
func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
    do { _ = try expression() } catch { return }
    fatalError("Expected error at \(file):\(line)")
}
func XCTUnwrap<T>(_ value: T?) throws -> T {
    guard let value else { throw VaultError.message("Test fixture unwrap failed") }
    return value
}

@main struct CoreChecks {
    static func main() async throws {
        setbuf(stdout, nil)
        if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--contention-child" { try runContentionChild(CommandLine.arguments); return }
        let suite = VaultCoreTests()
        let cases: [(String, () throws -> Void)] = [
            ("encrypted persistence, permissions, lock and backup", suite.testPersistenceEncryptionLockAndBackup),
            ("wrong password and tamper rejection", suite.testWrongPasswordAndTamperingFail),
            ("untrusted format and KDF parameters", suite.testMalformedParametersAndUnknownVersionFail),
            ("concurrent edits and no-overwrite creation", suite.testConflictingSaveAndCreateNeverOverwrite),
            ("failed save preserves memory", suite.testSaveFailurePreservesMemory),
            ("password change and duplicate IDs", suite.testPasswordChangeAndDuplicateIDs),
            ("lossless 1PIF fields and malformed rejection", suite.testImportPreservesAllFieldsAndRejectsPartial),
            ("attachment package rejection", suite.testImportDirectoryRejectsAttachments),
            ("password generator and master minimum", suite.testPasswordGeneratorAndMinimumMasterPassword),
            ("symlink rejection", suite.testSymlinkRejected),
            ("bounded import reads", suite.testImportSizeBound)
        ]
        for (name, check) in cases {
            try suite.setUpWithError()
            do { try check(); try suite.tearDownWithError() }
            catch { try? suite.tearDownWithError(); throw error }
            print("PASS \(name)")
        }
        print("PASS \(cases.count) core checks")
        try await runVaultWorkerChecks()
        try await runWorkspaceChecks()
        try runConcurrentSaveChecks()
        try runStorageV2Checks()
        try runInterchangeV2Checks()
        try runOnePasswordArchiveChecks()
        try await runOPVaultChecks()
        try await runAgileKeychainChecks()
        try runLegacyAttachmentChecks()
        try runTOTPChecks()
        try runManagementChecks()
        try await runDeviceUnlockChecks()
        try await runAttachmentChecks()
    }
}
