import Foundation
import CryptoKit
import VaultCore

func runOPVaultChecks() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    func make(_ name: String) throws -> URL {
        let package = root.appendingPathComponent(name + ".opvault")
        try FileManager.default.createDirectory(at: package.appendingPathComponent("default"), withIntermediateDirectories: true)
        for (name, encoded) in syntheticOPVaultFiles { try Data(base64Encoded: encoded)!.write(to: package.appendingPathComponent(name)) }
        return package
    }
    let source = try make("valid"), password = "合成-OPVault-密码!"
    let preview = try OPVaultImporter.read(from: source, password: password)
    XCTAssertEqual(preview.items.count, 4); XCTAssertEqual(preview.trashedCount, 2)
    let login = try XCTUnwrap(preview.items.first { $0.title == "Synthetic OPVault Login" })
    XCTAssertEqual(login.username, "synthetic-user"); XCTAssertEqual(login.password, "synthetic-secret")
    XCTAssertTrue(login.favorite); XCTAssertEqual(login.additionalURLs, ["https://second.invalid"])
    XCTAssertTrue(login.tags.contains("原文件夹/合成文件夹"))
    XCTAssertEqual(login.sections.flatMap(\.fields).first { $0.importedKey == "TOTP_fixture" }?.kind, .otp)
    XCTAssertEqual(login.attachments.count, 2); XCTAssertEqual(preview.document.blobs.count, 3)
    let text = try XCTUnwrap(login.attachments.first { $0.name == "中文.txt" })
    XCTAssertEqual(preview.document.blobs[text.blobID], Data("独立 OPVault 附件\n".utf8))
    XCTAssertTrue(preview.revisions.contains { $0.snapshot.attachments.contains { $0.name == "removed.txt" } })
    XCTAssertTrue(preview.items.contains { $0.notes.contains("synthetic rule preserved") })
    try XCTAssertEqual(OPVaultImporter.read(from: source, password: password).document, preview.document)
    XCTAssertThrowsError(try OPVaultImporter.read(from: source, password: "wrong"))
    for (path, expected) in syntheticOPVaultFiles { try XCTAssertEqual(Data(contentsOf: source.appendingPathComponent(path)), Data(base64Encoded: expected)!) }
    let vault = root.appendingPathComponent("destination.localvault"), backup = root.appendingPathComponent("backups")
    let session = try VaultSession.create(at: vault, password: "Synthetic-new-vault-password!", backupRoot: backup)
    let merge = try VaultInterchange.planMerge(preview, existing: [])
    try session.save(items: merge.items, importedRevisions: merge.revisions, importedBlobs: merge.document.blobs)
    session.lock()
    let reopened = try VaultSession.open(at: vault, password: "Synthetic-new-vault-password!", backupRoot: backup)
    try XCTAssertEqual(reopened.attachmentData(itemID: login.id, attachmentID: text.id), Data("独立 OPVault 附件\n".utf8))
    for format in [VaultExportFormat.nativeJSON, .csv] {
        let bytes = try VaultInterchange.encode(preview.document, format: format)
        let roundtrip = try format == .nativeJSON ? VaultInterchange.decodeJSON(bytes) : VaultInterchange.decodeCSV(bytes)
        XCTAssertEqual(roundtrip.document, preview.document)
    }
    let worker = VaultWorker(backupRoot: backup)
    _ = try await worker.open(vault, password: "Synthetic-new-vault-password!", create: false, generation: 1)
    await worker.invalidate(generation: 2)
    do { _ = try await worker.previewLegacyVault(source, password: password, generation: 1); fatalError("stale preview allowed") } catch {}

    // Mutations remain valid container JSON where applicable, to exercise authentication.
    for (label, path, replace) in [
        ("bad-wrapper", "default/profile.js", ("var profile=", "execute(")),
        ("cost", "default/profile.js", ("\"iterations\":1000", "\"iterations\":10000001")),
        ("identity", "default/band_A.js", ("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAB")),
        ("modified-time", "default/band_A.js", ("\"updated\":200", "\"updated\":201"))
    ] {
        let changed = try make(label), file = changed.appendingPathComponent(path)
        let original = try String(contentsOf: file, encoding: .utf8)
        let updated = original.replacingOccurrences(of: replace.0, with: replace.1)
        XCTAssertTrue(updated != original)
        try Data(updated.utf8).write(to: file)
        XCTAssertThrowsError(try OPVaultImporter.read(from: changed, password: password))
    }
    for field in ["hmac", "k", "d", "o"] {
        let changed = try make("tamper-" + field), file = changed.appendingPathComponent("default/band_A.js")
        let text = try String(contentsOf: file, encoding: .utf8)
        var bands = try JSONSerialization.jsonObject(with: Data(text.dropFirst(3).dropLast(2).utf8)) as! [String: [String: Any]]
        let id = String(repeating: "A", count: 32)
        var data = Data(base64Encoded: bands[id]![field] as! String)!; data[data.count - 1] ^= 1
        bands[id]![field] = data.base64EncodedString()
        if field != "hmac" {
            // Keep the outer record authentic so the inner key/opdata MAC must reject.
            let changed = bands[id]!
            let message = changed.keys.sorted().filter { !["hmac", "folder"].contains($0) }.map { key in
                key + ((changed[key] as? String) ?? (changed[key] as! NSNumber).stringValue)
            }.joined()
            let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: Data(base64Encoded: syntheticOPVaultOverviewMAC)!))
            bands[id]!["hmac"] = Data(mac).base64EncodedString()
        }
        try (Data("ld(".utf8) + JSONSerialization.data(withJSONObject: bands) + Data(");".utf8)).write(to: file)
        XCTAssertThrowsError(try OPVaultImporter.read(from: changed, password: password))
    }
    let attachmentPath = syntheticOPVaultFiles.keys.first { $0.contains("_DDDD") }!
    for offset in [0, 7, 8, 12, Data(base64Encoded: syntheticOPVaultFiles[attachmentPath]!)!.count - 1] {
        let changed = try make("attachment-\(offset)"), file = changed.appendingPathComponent(attachmentPath)
        var bytes = try Data(contentsOf: file); bytes[offset] ^= 0xff; try bytes.write(to: file)
        XCTAssertThrowsError(try OPVaultImporter.read(from: changed, password: password))
    }
    let orphan = try make("orphan")
    try Data(base64Encoded: syntheticOPVaultFiles[attachmentPath]!)!.write(to: orphan.appendingPathComponent(attachmentPath.replacingOccurrences(of: String(repeating: "A", count: 32), with: String(repeating: "8", count: 32))))
    XCTAssertThrowsError(try OPVaultImporter.read(from: orphan, password: password))
    let missingFolder = try make("missing-folder")
    try FileManager.default.removeItem(at: missingFolder.appendingPathComponent("default/folders.js"))
    XCTAssertThrowsError(try OPVaultImporter.read(from: missingFolder, password: password))
    let linked = root.appendingPathComponent("linked.opvault")
    try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: source)
    XCTAssertThrowsError(try OPVaultImporter.read(from: linked, password: password))
    let linkedChild = try make("linked-child"), childFile = linkedChild.appendingPathComponent("default/profile.js")
    try FileManager.default.removeItem(at: childFile)
    try FileManager.default.createSymbolicLink(at: childFile, withDestinationURL: source.appendingPathComponent("default/profile.js"))
    XCTAssertThrowsError(try OPVaultImporter.read(from: linkedChild, password: password))
    let linkedDirectory = root.appendingPathComponent("linked-directory.opvault")
    try FileManager.default.createDirectory(at: linkedDirectory, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: linkedDirectory.appendingPathComponent("default"), withDestinationURL: source.appendingPathComponent("default"))
    XCTAssertThrowsError(try OPVaultImporter.read(from: linkedDirectory, password: password))
    let extra = try make("extra"); try Data().write(to: extra.appendingPathComponent("default/unknown.bin"))
    XCTAssertThrowsError(try OPVaultImporter.read(from: extra, password: password))
    print("PASS independent synthetic OPVault Unicode password, HMAC/keys/records, v1/v2 attachments, OTP, folders/tombstones, encrypted migration, tamper/path/cost/stale-generation rejection")

    if let path = ProcessInfo.processInfo.environment["PASSWORDCRAFT_OPVAULT_REFERENCE_ROOT"] {
        let directory = URL(fileURLWithPath: path).appendingPathComponent("default")
        let referenceFiles = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let original = try Dictionary(uniqueKeysWithValues: referenceFiles.map { ($0, try Data(contentsOf: $0)) })
        let reference = try OPVaultImporter.read(from: URL(fileURLWithPath: path), password: "a")
        XCTAssertEqual(reference.items.count, 8); XCTAssertEqual(reference.trashedCount, 1)
        let login = try XCTUnwrap(reference.items.first { $0.title == "KeePassXC" })
        XCTAssertEqual(login.username, "keepassxc"); XCTAssertEqual(login.password, "opvault")
        XCTAssertEqual(login.url, "https://www.keepassxc.org"); XCTAssertEqual(login.notes, "KeePassXC Account")
        XCTAssertEqual(login.additionalURLs, ["https://snapshot.keepassxc.org"])
        XCTAssertEqual(login.attachments.count, 1)
        XCTAssertEqual(reference.document.blobs[login.attachments[0].blobID], Data("attachment".utf8))
        XCTAssertEqual(login.sections.flatMap(\.fields).first { $0.importedKey?.hasPrefix("TOTP_") == true }?.kind, .otp)
        for (file, expected) in original { try XCTAssertEqual(Data(contentsOf: file), expected) }
        print("PASS pinned KeePassXC public OPVault fixture: 8 items, real wrapped keys, authenticated metadata, archived/trash state, fields, OTP, v2 icon and attachment bytes")
    } else { print("UNVERIFIED external OPVault fixture (set PASSWORDCRAFT_OPVAULT_REFERENCE_ROOT to the pinned public test package)") }
}
