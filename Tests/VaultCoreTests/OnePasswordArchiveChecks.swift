import Foundation
import VaultCore

func runOnePasswordArchiveChecks() throws {
    let fixture = Data(base64Encoded: onePasswordAttachmentFixture)!
    let preview = try VaultInterchange.decode1PUX(fixture)
    var badEmpty = fixture
    let emptyName = try XCTUnwrap(fixture.range(of: Data("files/synthetic-empty___empty.txt".utf8)))
    badEmpty[emptyName.upperBound] = 0xff
    XCTAssertThrowsError(try VaultInterchange.decode1PUX(badEmpty))
    let expected = Data("1PUX synthetic attachment\n中文附件：逐字节保留。\n".utf8)
    XCTAssertEqual(preview.items.count, 3)
    XCTAssertEqual(preview.items[0].category, "文档")
    XCTAssertEqual(preview.items.map { $0.attachments.count }, [1, 1, 1])
    XCTAssertEqual(preview.document.blobs.count, 2)
    XCTAssertEqual(preview.document.blobs[preview.items[0].attachments[0].blobID], expected)
    XCTAssertEqual(preview.document.blobs[preview.items[2].attachments[0].blobID], Data())
    XCTAssertEqual(preview.items[1].sections.first?.fields.count, 1)
    XCTAssertEqual(preview.items[1].sections.first?.fields.first?.value, "kept")
    XCTAssertTrue(preview.items[1].importedJSON?.contains("documentId") == true)
    XCTAssertEqual(preview.items[1].password, "synthetic-password")
    try XCTAssertEqual(VaultInterchange.decode1PUX(fixture).document, preview.document)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source.1pux"); try fixture.write(to: source)
    let vault = root.appendingPathComponent("destination.localvault")
    let session = try VaultSession.create(at: vault, password: "Synthetic-migration-password!", backupRoot: root.appendingPathComponent("backups"))
    let imported = try VaultInterchange.read(from: source)
    let plan = try VaultInterchange.planMerge(imported, existing: [])
    try session.save(items: plan.items, importedRevisions: plan.revisions, importedBlobs: plan.document.blobs)
    session.lock()
    let reopened = try VaultSession.open(at: vault, password: "Synthetic-migration-password!", backupRoot: root.appendingPathComponent("backups"))
    try XCTAssertEqual(reopened.attachmentData(itemID: preview.items[0].id, attachmentID: preview.items[0].attachments[0].id), expected)
    let repeated = try VaultInterchange.planMerge(imported, existing: reopened.items, existingRevisions: reopened.allRevisions, existingBlobs: reopened.transferDocument.blobs)
    XCTAssertEqual(repeated.addedCount, 0); XCTAssertEqual(repeated.conflictCount, 0)
    let copied = try VaultInterchange.planMerge(imported, existing: reopened.items, existingRevisions: reopened.allRevisions, existingBlobs: reopened.transferDocument.blobs, policy: .copies)
    XCTAssertEqual(copied.items.count, 6); XCTAssertEqual(copied.document.blobs.count, 2)
    try XCTAssertEqual(Data(contentsOf: source), fixture)
    for format in [VaultExportFormat.nativeJSON, .csv] {
        let bytes = try VaultInterchange.encode(reopened.transferDocument, format: format)
        let result = try format == .nativeJSON ? VaultInterchange.decodeJSON(bytes) : VaultInterchange.decodeCSV(bytes)
        XCTAssertEqual(result.document, reopened.transferDocument)
    }

    let metadata: [String: Any] = ["documentId": "id", "fileName": "data.txt", "decryptedSize": 1]
    func record(_ code: String = "001", details: [String: Any]) -> [String: Any] {
        ["uuid": "item", "categoryUuid": code, "overview": ["title": "Synthetic"], "details": details]
    }
    func archive(_ records: [[String: Any]], files: [(String, Data)] = []) throws -> Data {
        let json: [String: Any] = ["accounts": [["attrs": ["uuid": "account"], "vaults": [["attrs": ["uuid": "vault"], "items": records]]]]]
        return storedZIP([("export.attributes", Data(#"{"version":3}"#.utf8)), ("export.data", try JSONSerialization.data(withJSONObject: json))] + files)
    }
    let blob = ("files/id___data.txt", Data([1]))
    let good = record(details: ["documentAttributes": metadata])
    try XCTAssertEqual(VaultInterchange.decode1PUX(archive([good], files: [blob])).items[0].attachments.count, 1)
    XCTAssertThrowsError(try VaultInterchange.decode1PUX(archive([good])))
    for (key, value) in [("fileName", "../data.txt" as Any), ("documentId", "../id" as Any), ("decryptedSize", 2 as Any), ("decryptedSize", -1 as Any), ("decryptedSize", true as Any), ("decryptedSize", 0.5 as Any), ("decryptedSize", 16 * 1024 * 1024 + 1 as Any)] {
        var bad = metadata; bad[key] = value
        XCTAssertThrowsError(try VaultInterchange.decode1PUX(archive([record(details: ["documentAttributes": bad])], files: [blob])))
    }
    XCTAssertThrowsError(try VaultInterchange.decode1PUX(archive([good], files: [blob, ("files/unclaimed___icon.png", Data([2]))])))
    XCTAssertThrowsError(try VaultInterchange.decode1PUX(archive([record(details: ["attachments": [metadata]])], files: [blob])))
    XCTAssertThrowsError(try VaultInterchange.decode1PUX(archive([record("006", details: [:])])))
    XCTAssertThrowsError(try VaultInterchange.decode1PUX(archive([good], files: [blob, ("files/sub/file", Data([2]))])))
    XCTAssertThrowsError(try VaultInterchange.decode1PUX(archive([good], files: [blob, blob])))
    let fileField: [String: Any] = ["value": ["file": metadata]]
    let repeatedField = record(details: ["sections": [["fields": [fileField, fileField]]]])
    try XCTAssertEqual(VaultInterchange.decode1PUX(archive([repeatedField], files: [blob])).items[0].attachments.count, 1)
    let mixed = record(details: ["sections": [["fields": [["value": ["file": metadata, "string": "ambiguous"]]]]]])
    XCTAssertThrowsError(try VaultInterchange.decode1PUX(archive([mixed], files: [blob])))
    // Test category facts at the public parser boundary, not only the lookup helper.
    let categories = [("100", "软件许可证"), ("101", "银行账户"), ("106", "护照"), ("110", "服务器"), ("112", "API 凭据"), ("128", "其他")]
    for (code, expectedCategory) in categories {
        let result = try VaultInterchange.decode1PUX(archive([record(code, details: [:])]))
        XCTAssertEqual(result.items[0].category, expectedCategory)
    }
    let password = try VaultInterchange.decode1PUX(archive([record("005", details: ["password": "synthetic-standalone-password"])]))
    XCTAssertEqual(password.items[0].password, "synthetic-standalone-password")
    XCTAssertFalse(password.items[0].sections.flatMap(\.fields).contains { $0.importedKey == "secure:password" })
    var editedPassword = password.items[0]; editedPassword.password = "edited-synthetic-password"
    let pif = try VaultInterchange.encode(VaultTransferDocument(items: [editedPassword]), format: .onePIF)
    let reparsed = try OnePasswordImporter.parsePreview(String(decoding: pif, as: UTF8.self))
    XCTAssertEqual(reparsed.items[0].password, "edited-synthetic-password")
    print("PASS independent compressed 1PUX documents/files/empty attachments, encrypted migration and source preservation, deduplication/transfer, strict file inventory and corrected categories")
}
