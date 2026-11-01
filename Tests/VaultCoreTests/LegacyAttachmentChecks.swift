import Foundation
import VaultCore

func runLegacyAttachmentChecks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    func write(_ files: [String: Data], name: String) throws -> URL {
        let package = root.appendingPathComponent(name)
        for (path, bytes) in files {
            let target = package.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: target)
        }
        return package
    }
    let id = String(repeating: "A", count: 32)
    let record: [String: Any] = ["uuid": id, "title": "Synthetic PIF attachments", "typeName": "webforms.WebForm", "secureContents": ["password": "synthetic-pif-password", "passwordHistory": [["value": "old-synthetic", "time": 100]]]]
    let plain: [String: Data] = ["data.1pif": try JSONSerialization.data(withJSONObject: record), "attachments/\(id)/中文.txt": Data("独立明文附件\n".utf8), "attachments/\(id)/empty.bin": Data()]
    let pif = try write(plain, name: "synthetic.1pif"), imported = try OnePasswordImporter.readPreview(from: pif)
    XCTAssertEqual(imported.items[0].attachments.count, 2); XCTAssertEqual(imported.document.blobs.count, 2)
    XCTAssertEqual(imported.revisions[0].snapshot.attachments, imported.items[0].attachments)
    try XCTAssertEqual(OnePasswordImporter.readPreview(from: pif.appendingPathComponent("data.1pif")).document, imported.document)
    var orphan = plain; orphan["attachments/UNKNOWN/orphan.bin"] = Data([1])
    XCTAssertThrowsError(try OnePasswordImporter.readPreview(from: write(orphan, name: "orphan.1pif")))
    var previewFile = plain; previewFile["previews/unknown.png"] = Data([1])
    XCTAssertThrowsError(try OnePasswordImporter.readPreview(from: write(previewFile, name: "preview.1pif")))
    let malformedWindows: [String: Any] = ["uuid": id, "category": "001", "overview": ["title": "Malformed Windows export"], "details": ["URLs": "not an array"]]
    let malformedText = String(decoding: try JSONSerialization.data(withJSONObject: malformedWindows), as: UTF8.self)
    XCTAssertThrowsError(try OnePasswordImporter.parsePreview(malformedText))
    let linked = try write(plain, name: "linked.1pif"), linkedFile = linked.appendingPathComponent("attachments/\(id)/empty.bin")
    try FileManager.default.removeItem(at: linkedFile)
    try FileManager.default.createSymbolicLink(at: linkedFile, withDestinationURL: pif.appendingPathComponent("attachments/\(id)/empty.bin"))
    XCTAssertThrowsError(try OnePasswordImporter.readPreview(from: linked))

    let agileFiles = syntheticAgileKeychainFiles.merging(syntheticAgileAttachmentFiles) { _, new in new }.mapValues { Data(base64Encoded: $0)! }
    let agile = try write(agileFiles, name: "synthetic.agilekeychain")
    let encrypted = try AgileKeychainImporter.read(from: agile, password: "合成-Agile-密码!")
    let owner = try XCTUnwrap(encrypted.items.first { $0.title == "Synthetic Agile Login" })
    XCTAssertEqual(owner.attachments.count, 2); XCTAssertEqual(encrypted.document.blobs.count, 2)
    let attachment = try XCTUnwrap(owner.attachments.first { $0.name == "中文附件.txt" })
    XCTAssertEqual(encrypted.document.blobs[attachment.blobID], Data("独立加密附件\n".utf8))
    XCTAssertTrue(owner.importedJSON?.contains(Data("synthetic icon bytes".utf8).base64EncodedString()) == true)
    XCTAssertTrue(encrypted.revisions.filter { $0.snapshot.id == owner.id }.allSatisfy { $0.snapshot.attachments == owner.attachments })
    let base = "a/default/files/\(id)/" + String(repeating: "D", count: 32)
    for path in [base, base + ".def"] {
        var missing = agileFiles; missing.removeValue(forKey: path)
        XCTAssertThrowsError(try AgileKeychainImporter.read(from: write(missing, name: UUID().uuidString + ".agilekeychain"), password: "合成-Agile-密码!"))
    }
    var noIcon = agileFiles; noIcon.removeValue(forKey: base + ".icn")
    let noIconPreview = try AgileKeychainImporter.read(from: write(noIcon, name: "no-icon.agilekeychain"), password: "合成-Agile-密码!")
    XCTAssertEqual(noIconPreview.document.blobs, encrypted.document.blobs)
    for (key, value) in [("filename", "../unsafe.txt"), ("encryptionKey", "UNKNOWN"), ("contentsHash", "00000000")] {
        var broken = agileFiles, definition = try JSONSerialization.jsonObject(with: agileFiles[base + ".def"]!) as! [String: Any]
        definition[key] = value; broken[base + ".def"] = try JSONSerialization.data(withJSONObject: definition)
        XCTAssertThrowsError(try AgileKeychainImporter.read(from: write(broken, name: key + ".agilekeychain"), password: "合成-Agile-密码!"))
    }
    var unexpected = agileFiles; unexpected[base + ".unknown"] = Data([1])
    XCTAssertThrowsError(try AgileKeychainImporter.read(from: write(unexpected, name: "unknown.agilekeychain"), password: "合成-Agile-密码!"))

    func roundTrip(_ preview: VaultImportPreview) throws {
        let vault = root.appendingPathComponent(UUID().uuidString + ".localvault"), backups = root.appendingPathComponent(UUID().uuidString)
        let session = try VaultSession.create(at: vault, password: "Synthetic-transfer-password!", backupRoot: backups)
        let plan = try VaultInterchange.planMerge(preview, existing: [])
        try session.save(items: plan.items, importedRevisions: plan.revisions, importedBlobs: plan.document.blobs)
        session.lock()
        let reopened = try VaultSession.open(at: vault, password: "Synthetic-transfer-password!", backupRoot: backups)
        XCTAssertEqual(reopened.transferDocument, preview.document)
        let repeatPlan = try VaultInterchange.planMerge(preview, existing: reopened.items, existingRevisions: reopened.transferDocument.revisions, existingBlobs: reopened.transferDocument.blobs)
        XCTAssertEqual(repeatPlan.addedCount, 0)
        for format in [VaultExportFormat.nativeJSON, .csv] {
            let bytes = try VaultInterchange.encode(preview.document, format: format)
            let roundtrip = try format == .nativeJSON ? VaultInterchange.decodeJSON(bytes) : VaultInterchange.decodeCSV(bytes)
            XCTAssertEqual(roundtrip.document, preview.document)
        }
    }
    try roundTrip(imported); try roundTrip(encrypted)
    for (path, data) in agileFiles { try XCTAssertEqual(Data(contentsOf: agile.appendingPathComponent(path)), data) }
    for (path, data) in plain { try XCTAssertEqual(Data(contentsOf: pif.appendingPathComponent(path)), data) }
    print("PASS 1PIF/Agile attachments: independent plaintext/encrypted/empty files, optional icons, strict inventory/CRC/path/key rejection, source preservation, encrypted histories, dedup and full transfer")

    if let path = ProcessInfo.processInfo.environment["PASSWORDCRAFT_LEGACY_FILES_REFERENCE_ROOT"] {
        let reference = URL(fileURLWithPath: path)
        for (name, count) in [("1P3-MacOSX.1pif", 52), ("1P3-MacOSX-1P4-Windows.1pif", 52), ("1P4-Windows.1pif", 40), ("1P6-macOS.1pif", 40), ("1P7-macOS-Cloud.1pif", 17), ("Sample vault.agilekeychain", 52)] {
            let url = reference.appendingPathComponent(name)
            let preview = try name.hasSuffix("agilekeychain") ? AgileKeychainImporter.read(from: url, password: "Sample vault") : OnePasswordImporter.readPreview(from: url)
            XCTAssertEqual(preview.items.count, count)
            if !name.contains("Cloud") {
                let login = try XCTUnwrap(preview.items.first { $0.title == "Login - full" })
                XCTAssertEqual(login.attachments.count, 2); XCTAssertEqual(preview.document.blobs.count, 2)
                XCTAssertEqual(login.username, "designated.username@email.com"); XCTAssertEqual(login.password, "designated password")
                XCTAssertTrue(login.tags.contains("原文件夹/A regular subfolder"))
                for (name, expected) in [("attachment.txt", "1\n"), ("attachment2.txt", "2\n")] {
                    let file = try XCTUnwrap(login.attachments.first { $0.name == name })
                    XCTAssertEqual(preview.document.blobs[file.blobID], Data(expected.utf8))
                }
            }
            try roundTrip(preview)
        }
        print("PASS pinned independent 1Password 3/4/6/7 exports and AgileKeychain with attachments: exact fields/file bytes, folder links, encrypted migration and complete JSON/CSV histories")
    } else { print("UNVERIFIED independent legacy attachment packages (set PASSWORDCRAFT_LEGACY_FILES_REFERENCE_ROOT)") }
}
