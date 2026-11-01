import Foundation
import VaultCore

func runAttachmentChecks() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("attachments.localvault"), backups = root.appendingPathComponent("backups")
    let password = "Synthetic-attachment-master!"
    let session = try VaultSession.create(at: file, password: password, backupRoot: backups)
    let item = VaultItem(title: "attachment owner")
    try session.save(items: [item])
    let content = Data("PRIVATE SYNTHETIC ATTACHMENT\n中文附件\n".utf8)
    try session.addAttachment(itemID: item.id, name: "测试.txt", mediaType: "text/plain", data: content)
    let first = try XCTUnwrap(session.items.first?.attachments.first)
    try XCTAssertEqual(session.attachmentData(itemID: item.id, attachmentID: first.id), content)
    let encrypted = try Data(contentsOf: file)
    XCTAssertFalse(String(data: encrypted, encoding: .utf8)!.contains("PRIVATE SYNTHETIC"))
    try session.addAttachment(itemID: item.id, name: "second.txt", mediaType: "text/plain", data: content)
    XCTAssertEqual(session.transferDocument.blobs.count, 1)
    try session.removeAttachment(itemID: item.id, attachmentID: first.id)
    let previous = try XCTUnwrap(session.revisions(for: item.id).first { $0.snapshot.attachments.count == 2 })
    XCTAssertThrowsError(try session.attachmentData(itemID: item.id, attachmentID: first.id))
    try XCTAssertEqual(session.attachmentData(itemID: item.id, attachmentID: first.id, revisionID: previous.id), content)
    try session.restoreRevision(itemID: item.id, revisionID: previous.id)
    XCTAssertEqual(session.items[0].attachments.count, 2)
    let export = root.appendingPathComponent("export.txt")
    try session.exportAttachment(itemID: item.id, attachmentID: first.id, to: export)
    try XCTAssertEqual(Data(contentsOf: export), content)
    let permissions = try FileManager.default.attributesOfItem(atPath: export.path)[.posixPermissions] as! NSNumber
    XCTAssertEqual(permissions.intValue & 0o777, 0o600)
    XCTAssertThrowsError(try session.exportAttachment(itemID: item.id, attachmentID: first.id, to: export))
    try XCTAssertEqual(Data(contentsOf: export), content)
    let saved = try Data(contentsOf: file)
    for name in ["../escape", "path/file", "path\\file", "", "bad\0name"] {
        XCTAssertThrowsError(try session.addAttachment(itemID: item.id, name: name, mediaType: "text/plain", data: content))
    }
    try XCTAssertEqual(Data(contentsOf: file), saved)
    let transfer = session.transferDocument
    for format in [VaultExportFormat.nativeJSON, .csv] {
        let bytes = try VaultInterchange.encode(transfer, format: format)
        let decoded = try format == .nativeJSON ? VaultInterchange.decodeJSON(bytes) : VaultInterchange.decodeCSV(bytes)
        XCTAssertEqual(decoded.document, transfer)
        let merged = try VaultInterchange.planMerge(decoded, existing: [], policy: .copies)
        try merged.document.validate()
        XCTAssertEqual(merged.document.blobs, transfer.blobs)
        XCTAssertTrue(merged.items[0].id != item.id)
        let skipped = try VaultInterchange.planMerge(decoded, existing: transfer.items, existingRevisions: transfer.revisions, existingBlobs: transfer.blobs)
        XCTAssertEqual(skipped.document, transfer)
    }
    XCTAssertThrowsError(try VaultInterchange.encode(transfer, format: .onePIF))
    var corrupt = transfer; corrupt.blobs[first.blobID] = Data("bad".utf8)
    XCTAssertThrowsError(try corrupt.validate())
    corrupt = transfer; corrupt.blobs = [:]; XCTAssertThrowsError(try corrupt.validate())
    corrupt = transfer; corrupt.blobs[AttachmentStore.identity(Data())] = Data(); XCTAssertThrowsError(try corrupt.validate())
    corrupt = transfer; corrupt.version = 1; XCTAssertThrowsError(try corrupt.validate())
    let oldBackup = try XCTUnwrap(session.availableBackups().first)
    try session.changePassword("New-synthetic-attachment-master!")
    let reopened = try VaultSession.open(at: file, password: "New-synthetic-attachment-master!", backupRoot: backups)
    try XCTAssertEqual(reopened.attachmentData(itemID: item.id, attachmentID: first.id), content)
    let recovered = root.appendingPathComponent("recovered.localvault")
    try reopened.recoverBackup(oldBackup.url, to: recovered, password: password)
    try XCTAssertEqual(VaultSession.open(at: recovered, password: password, backupRoot: backups).transferDocument, transfer)
    var removed = reopened.items; removed[0].state = .trashed; removed[0].deletedAt = Date()
    try reopened.save(items: removed); try reopened.purge(itemID: item.id)
    XCTAssertEqual(reopened.transferDocument.blobs.count, 0)
    XCTAssertEqual(reopened.allRevisions.count, 0)
    reopened.lock()
    XCTAssertThrowsError(try reopened.attachmentData(itemID: item.id, attachmentID: first.id))

    // The actual previous app's encrypted fixture proves format migration, not
    // merely a v3 file with its outer version number edited.
    let legacy = root.appendingPathComponent("legacy.localvault"), original = Data(base64Encoded: legacyV2Fixture)!
    try original.write(to: legacy)
    let old = try VaultSession.open(at: legacy, password: "Synthetic-V3-Only!", backupRoot: backups)
    try XCTAssertEqual(Data(contentsOf: legacy), original)
    let oldID = old.vaultID, oldItems = old.items
    let token = try old.deviceUnlockMaterial()
    try old.addAttachment(itemID: old.items.first(where: { $0.state == .active })!.id, name: "upgrade.txt", mediaType: "text/plain", data: content)
    let envelope = try JSONSerialization.jsonObject(with: Data(contentsOf: legacy)) as! [String: Any]
    XCTAssertEqual(envelope["version"] as? Int, 3)
    XCTAssertEqual(old.vaultID, oldID); XCTAssertEqual(old.items.count, oldItems.count)
    let pinned = try XCTUnwrap(old.availableBackups().first { $0.reason == "upgrade-v2" })
    try XCTAssertEqual(Data(contentsOf: pinned.url), original)
    let tokenOpen = try VaultSession.open(at: legacy, deviceUnlockMaterial: token, backupRoot: backups)
    XCTAssertEqual(tokenOpen.transferDocument, old.transferDocument)

    // Enforce the existing whole-vault bound as well as the individual-file bound.
    let capacityFile = root.appendingPathComponent("capacity.localvault")
    let capacity = try VaultSession.create(at: capacityFile, password: password, backupRoot: backups)
    let capacityItem = VaultItem(title: "capacity"); try capacity.save(items: [capacityItem])
    let full = Data(repeating: 0x41, count: AttachmentStore.maximumAttachmentBytes)
    try capacity.addAttachment(itemID: capacityItem.id, name: "a.bin", mediaType: "application/octet-stream", data: full)
    let before = try Data(contentsOf: capacityFile)
    XCTAssertThrowsError(try capacity.addAttachment(itemID: capacityItem.id, name: "b.bin", mediaType: "application/octet-stream", data: Data(repeating: 0x42, count: full.count)))
    try XCTAssertEqual(Data(contentsOf: capacityFile), before)
    XCTAssertEqual(capacity.items[0].attachments.count, 1)
    let sharedItems = (0..<50).map { index -> VaultItem in var copy = capacity.items[0]; copy.id = UUID(); copy.title = "shared \(index)"; return copy }
    let sharedTransfer = VaultTransferDocument(items: sharedItems, blobs: capacity.transferDocument.blobs)
    try sharedTransfer.validate()
    XCTAssertThrowsError(try VaultInterchange.encode(sharedTransfer, format: .csv))
    let largeSource = root.appendingPathComponent("too-large.bin")
    FileManager.default.createFile(atPath: largeSource.path, contents: nil)
    let handle = try FileHandle(forWritingTo: largeSource); try handle.truncate(atOffset: UInt64(full.count + 1)); try handle.close()
    let worker = VaultWorker(backupRoot: backups)
    _ = try await worker.open(capacityFile, password: password, create: false, generation: 1)
    do { try await worker.addAttachment(itemID: capacityItem.id, from: largeSource, mediaType: "application/octet-stream", generation: 1); fatalError("oversized attachment read") } catch {}
    await worker.invalidate(generation: 2)
    do { _ = try await worker.attachmentData(itemID: capacityItem.id, attachmentID: first.id, generation: 1); fatalError("locked attachment read") } catch {}
    print("PASS encrypted attachments, normalized history, export and transfer, tamper rejection, rekey/backup, purge, actual v2 migration and capacity/lock boundaries")
}
