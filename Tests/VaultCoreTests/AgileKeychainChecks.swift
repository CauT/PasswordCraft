import Foundation
import VaultCore

func runAgileKeychainChecks() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    func make(_ name: String) throws -> URL {
        let package = root.appendingPathComponent(name + ".agilekeychain")
        for (name, encoded) in syntheticAgileKeychainFiles {
            let file = package.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(base64Encoded: encoded)!.write(to: file)
        }
        return package
    }
    let source = try make("valid"), password = "合成-Agile-密码!"
    let preview = try AgileKeychainImporter.read(from: source, password: password)
    XCTAssertEqual(preview.items.count, 4); XCTAssertEqual(preview.trashedCount, 1)
    XCTAssertTrue(preview.sourceIsEncrypted)
    let login = try XCTUnwrap(preview.items.first { $0.title == "Synthetic Agile Login" })
    XCTAssertEqual(login.username, "agile-user"); XCTAssertEqual(login.password, "agile-secret")
    XCTAssertTrue(login.tags.contains("原文件夹/合成文件夹")); XCTAssertTrue(login.tags.contains("synthetic"))
    XCTAssertEqual(login.sections.flatMap(\.fields).first { $0.importedKey == "TOTP_agile" }?.kind, .otp)
    XCTAssertTrue(preview.revisions.contains { $0.snapshot.password == "agile-old" })
    XCTAssertEqual(preview.items.first { $0.title == "Synthetic Agile SL3" }?.notes, "unsalted content\t\n")
    XCTAssertTrue(preview.warnings.contains { $0.contains("没有条目认证") })
    try XCTAssertEqual(AgileKeychainImporter.read(from: source, password: password).document, preview.document)
    XCTAssertThrowsError(try AgileKeychainImporter.read(from: source, password: "wrong"))
    XCTAssertThrowsError(try VaultInterchange.read(from: source))
    let destination = root.appendingPathComponent("destination.localvault"), backup = root.appendingPathComponent("backup")
    let session = try VaultSession.create(at: destination, password: "Synthetic-destination!", backupRoot: backup)
    let plan = try VaultInterchange.planMerge(preview, existing: [])
    try session.save(items: plan.items, importedRevisions: plan.revisions)
    session.lock()
    let reopened = try VaultSession.open(at: destination, password: "Synthetic-destination!", backupRoot: backup)
    XCTAssertEqual(reopened.items, plan.items)
    let repeated = try VaultInterchange.planMerge(preview, existing: reopened.items)
    XCTAssertEqual(repeated.addedCount, 0)
    let worker = VaultWorker(backupRoot: backup)
    _ = try await worker.open(destination, password: "Synthetic-destination!", create: false, generation: 1)
    let workerPreview = try await worker.previewLegacyVault(source, password: password, generation: 1)
    XCTAssertEqual(workerPreview.document, preview.document)
    await worker.invalidate(generation: 2)
    do { _ = try await worker.previewLegacyVault(source, password: password, generation: 1); fatalError("stale import accepted") } catch {}
    for (path, expected) in syntheticAgileKeychainFiles { try XCTAssertEqual(Data(contentsOf: source.appendingPathComponent(path)), Data(base64Encoded: expected)!) }

    func mutate(_ name: String, path: String, action: (inout [String: Any]) throws -> Void) throws {
        let changed = try make(name), file = changed.appendingPathComponent(path)
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        try action(&object); try JSONSerialization.data(withJSONObject: object).write(to: file)
        XCTAssertThrowsError(try AgileKeychainImporter.read(from: changed, password: password))
    }
    let keyPath = "data/default/encryptionKeys.js", itemPath = "data/default/" + String(repeating: "A", count: 32) + ".1password"
    for field in ["data", "validation"] {
        try mutate("key-" + field, path: keyPath) { object in
            var list = object["list"] as! [[String: Any]]
            var bytes = Data(base64Encoded: (list[0][field] as! String).trimmingCharacters(in: CharacterSet(charactersIn: "\0")))!
            bytes[bytes.count - 1] ^= 0xff; list[0][field] = bytes.base64EncodedString(); object["list"] = list
        }
    }
    for count in [10_000_001, -1] {
        try mutate("cost-\(count)", path: keyPath) { object in
            var list = object["list"] as! [[String: Any]]; list[0]["iterations"] = count; object["list"] = list
        }
    }
    try mutate("aggregate-cost", path: keyPath) { object in
        var list = object["list"] as! [[String: Any]]
        for index in list.indices { list[index]["iterations"] = 6_000_000 }; object["list"] = list
    }
    try mutate("missing-key", path: itemPath) { $0["keyID"] = "9" }
    try mutate("identity", path: itemPath) { $0["uuid"] = "9" }
    try mutate("broken-cipher", path: itemPath) { $0["encrypted"] = "AA==" }
    try mutate("folder", path: itemPath) { $0["folderUuid"] = "9" }
    try mutate("declared-attachment", path: itemPath) { $0["attachments"] = [["name": "missing.txt"]] }
    let missing = try make("missing-file")
    try FileManager.default.removeItem(at: missing.appendingPathComponent(itemPath))
    XCTAssertThrowsError(try AgileKeychainImporter.read(from: missing, password: password))
    let extra = try make("extra-file")
    try Data("not silently omitted".utf8).write(to: extra.appendingPathComponent("data/default/unknown.attachment"))
    XCTAssertThrowsError(try AgileKeychainImporter.read(from: extra, password: password))
    let linked = root.appendingPathComponent("linked.agilekeychain")
    try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: source)
    XCTAssertThrowsError(try AgileKeychainImporter.read(from: linked, password: password))
    let child = try make("linked-child"), file = child.appendingPathComponent(itemPath)
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: source.appendingPathComponent(itemPath))
    XCTAssertThrowsError(try AgileKeychainImporter.read(from: child, password: password))
    let directoryLink = try make("directory-link")
    try FileManager.default.createSymbolicLink(at: directoryLink.appendingPathComponent("style/linked"), withDestinationURL: source.appendingPathComponent("data"))
    XCTAssertThrowsError(try AgileKeychainImporter.read(from: directoryLink, password: password))
    let deep = try make("deep")
    try FileManager.default.createDirectory(at: deep.appendingPathComponent("style/a/b/c/d/e/f/g/h/i"), withIntermediateDirectories: true)
    XCTAssertThrowsError(try AgileKeychainImporter.read(from: deep, password: password))
    // This format cannot authenticate even the title. Preserve the warning, never claim tamper-proof import.
    let changedMetadata = try make("unauthenticated-title"), changedFile = changedMetadata.appendingPathComponent(itemPath)
    var record = try JSONSerialization.jsonObject(with: Data(contentsOf: changedFile)) as! [String: Any]
    record["title"] = "Changed outside encryption"
    try JSONSerialization.data(withJSONObject: record).write(to: changedFile)
    let changedPreview = try AgileKeychainImporter.read(from: changedMetadata, password: password)
    XCTAssertTrue(changedPreview.items.contains { $0.title == "Changed outside encryption" })
    XCTAssertTrue(changedPreview.warnings.contains { $0.contains("没有条目认证") })
    print("PASS synthetic AgileKeychain Unicode password, strict PKCS7/validation, salted/unsalted SL5/SL3, key precedence, folders/tombstones/history/OTP, encrypted migration, source preservation and invalid package rejection")

    if let path = ProcessInfo.processInfo.environment["PASSWORDCRAFT_AGILE_REFERENCE_ROOT"] {
        let reference = try AgileKeychainImporter.read(from: URL(fileURLWithPath: path), password: "badger")
        XCTAssertEqual(reference.items.count, 5); XCTAssertEqual(reference.trashedCount, 1)
        for (title, secret) in [("onetosix", "123456"), ("atof", "abcdef"), ("foobar", "foobar"), ("Generic Account", "flibble")] {
            XCTAssertEqual(reference.items.first { $0.title == title }?.password, secret)
        }
        XCTAssertEqual(reference.items.first { $0.title == "onetosix" }?.username, "user")
        XCTAssertEqual(reference.items.first { $0.title == "onetosix" }?.url, "http://onetosix.example.com")
        print("PASS pinned independent 1pass AgileKeychain: 5 records, 4 known passwords, SL5/SL3 key validation, legacy NUL base64, login fields and tombstone")
    } else { print("UNVERIFIED public AgileKeychain fixture (set PASSWORDCRAFT_AGILE_REFERENCE_ROOT to the pinned public test package)") }
    if let path = ProcessInfo.processInfo.environment["PASSWORDCRAFT_AGILE_LEGACY_REFERENCE_ROOT"] {
        let reference = try AgileKeychainImporter.read(from: URL(fileURLWithPath: path), password: "strongpassword")
        XCTAssertEqual(reference.items.count, 9)
        XCTAssertEqual(reference.items.first { $0.sourceIdentity == "agilekeychain:379A9F9791EA4853B318111C0EEEC94F" }?.password, "3SOPpQZI9lSvPP")
        XCTAssertEqual(reference.items.first { $0.sourceIdentity == "agilekeychain:679B9BA4639A4D66BF629405E37D29C9" }?.password, "I9lz9ykKmcfDtl")
        XCTAssertTrue(reference.items.contains { $0.title == "Github" })
        XCTAssertTrue(reference.warnings.contains { $0.contains("缩略图缓存") })
        print("PASS pinned gwik legacy AgileKeychain: 9 records, shortened IDs, absent iteration defaults, known passwords, nested resources/thumbnails")
    } else { print("UNVERIFIED second legacy AgileKeychain fixture (set PASSWORDCRAFT_AGILE_LEGACY_REFERENCE_ROOT)") }
}
