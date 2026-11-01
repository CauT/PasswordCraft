import Foundation
import VaultCore

/// Synthetic secrets only. Exercises public import/export APIs used by the delivered UI.
func runInterchangeV2Checks() throws {
    let raw = #"{"uuid":"synthetic-id","title":"卡片","typeName":"wallet.financial.CreditCard","location":"https://example.invalid","createdAt":100,"updatedAt":200,"trashed":true,"tags":["中文","工作"],"secureContents":{"username":"alice","password":"original-secret","ccnum":"1111222233334444","expiry":202912,"enabled":true,"address":{"city":"上海"},"notesPlain":"line one\nline two","URLs":[{"url":"https://example.invalid"},{"url":"https://second.invalid"}],"sections":[{"name":"custom","title":"附加","fields":[{"n":"pin","t":"PIN","k":"concealed","v":"1234"}]}],"passwordHistory":[{"value":"old-secret","time":150}]}}"#
    let preview = try OnePasswordImporter.parsePreview("\u{feff}" + raw + "\r\n***5642bee8-a5ff-11dc-8314-0800200c9a66***\r\n")
    XCTAssertTrue(preview.warnings.contains { $0.contains("专用控件") })
    let item = try XCTUnwrap(preview.items.first)
    XCTAssertEqual(preview.trashedCount, 1); XCTAssertEqual(item.category, "信用卡")
    XCTAssertEqual(item.tags, ["中文","工作"]); XCTAssertEqual(item.additionalURLs, ["https://second.invalid"])
    XCTAssertEqual(item.createdAt, Date(timeIntervalSince1970:100)); XCTAssertEqual(item.deletedAt, Date(timeIntervalSince1970:200))
    XCTAssertEqual(item.sections.flatMap(\.fields).first { $0.importedKey == "secure:expiry" }?.value, "202912")
    XCTAssertEqual(item.sections.flatMap(\.fields).first { $0.importedKey == "secure:enabled" }?.value, "true")
    XCTAssertEqual(item.sections.flatMap(\.fields).first { $0.label == "PIN" }?.kind, .password)
    XCTAssertEqual(item.importedJSON, raw); XCTAssertEqual(preview.revisions.first?.snapshot.password, "old-secret")
    XCTAssertThrowsError(try OnePasswordImporter.parsePreview(raw.replacingOccurrences(of: "\"sections\":[", with: "\"fields\":42,\"sections\":[")))
    let unknownCategory = try OnePasswordImporter.parsePreview(raw.replacingOccurrences(of:"wallet.financial.CreditCard",with:"synthetic.Unknown"))
    XCTAssertTrue(unknownCategory.warnings.contains { $0.contains("专用模板") })
    let repeated = try OnePasswordImporter.parsePreview(raw)
    XCTAssertEqual(repeated.document, preview.document)
    let skipped = try VaultInterchange.planMerge(repeated, existing:preview.items, existingRevisions:preview.revisions)
    XCTAssertEqual(skipped.addedCount, 0); XCTAssertEqual(skipped.skippedCount, 1); XCTAssertEqual(skipped.conflictCount, 0)
    var edited = item; edited.password = "edited-secret"; edited.tags = ["edited"]; edited.state = .archived; edited.deletedAt = nil
    edited.title = "Comma, quote \" and 中文"; edited.notes = "line one\r\nline two\nend"
    edited.sections[0].fields.removeAll { $0.importedKey == "secure:ccnum" }
    let changed = try VaultInterchange.planMerge(repeated, existing:[edited])
    XCTAssertEqual(changed.conflictCount, 1); XCTAssertEqual(changed.items[0].password, "edited-secret")
    let copies = try VaultInterchange.planMerge(repeated, existing:preview.items, existingRevisions:preview.revisions, policy:.copies)
    XCTAssertEqual(copies.addedCount, 1); XCTAssertEqual(copies.items.count, 2)
    XCTAssertTrue(copies.items[1].id != item.id); XCTAssertEqual(copies.items[1].sourceIdentity, nil)
    XCTAssertEqual(copies.revisions.last?.snapshot.id, copies.items[1].id)
    let document = VaultTransferDocument(items:[edited], revisions:preview.revisions)
    for format in [VaultExportFormat.nativeJSON, .csv] {
        let bytes = try VaultInterchange.encode(document, format:format)
        let imported = try format == .nativeJSON ? VaultInterchange.decodeJSON(bytes) : VaultInterchange.decodeCSV(bytes)
        XCTAssertEqual(imported.document, document)
    }
    let pif = try VaultInterchange.encode(document, format:.onePIF)
    let pifObject = try XCTUnwrap(JSONSerialization.jsonObject(with:pif) as? [String:Any])
    let secure = try XCTUnwrap(pifObject["secureContents"] as? [String:Any])
    XCTAssertEqual(secure["password"] as? String, "edited-secret"); XCTAssertEqual(secure["ccnum"] as? String, nil)
    XCTAssertEqual(secure["expiry"] as? Int, 202912); XCTAssertEqual(secure["enabled"] as? Bool, true)
    let reimported = try OnePasswordImporter.parsePreview(String(decoding:pif,as:UTF8.self))
    XCTAssertEqual(reimported.items.first?.password,"edited-secret"); XCTAssertEqual(reimported.items.first?.state,.archived)
    XCTAssertEqual(reimported.items.first?.tags,["edited"]); XCTAssertEqual(reimported.revisions.first?.snapshot.password,"old-secret")
    var invalidState = edited; invalidState.deletedAt = Date()
    XCTAssertThrowsError(try VaultInterchange.encode(VaultTransferDocument(items:[invalidState]),format:.nativeJSON))
    var invalid = document; invalid.version = 999
    XCTAssertThrowsError(try VaultInterchange.decodeJSON(JSONEncoder().encode(invalid)))
    XCTAssertThrowsError(try VaultInterchange.encode(VaultTransferDocument(items:[item,item]),format:.nativeJSON))
    XCTAssertThrowsError(try VaultInterchange.encode(VaultTransferDocument(items:[],revisions:preview.revisions),format:.nativeJSON))
    let plain = try VaultInterchange.decodeCSV(Data("\u{feff}title,username,password,notes,custom\r\n\"中文, title\",alice,\"pa\"\"ss\",\"line1\r\nline2\",extra\r\n".utf8))
    XCTAssertEqual(plain.items[0].password,"pa\"ss"); XCTAssertEqual(plain.items[0].notes,"line1\r\nline2")
    XCTAssertEqual(plain.items[0].sections.first?.fields.first?.value,"extra"); XCTAssertFalse(plain.warnings.isEmpty)
    for bad in ["title,notes\nx,\"unfinished", "title,notes\nx,one,extra", "title,state\nx,invalid", "title,title\nx,x"] {
        XCTAssertThrowsError(try VaultInterchange.decodeCSV(Data(bad.utf8)))
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PasswordCraft-interchange-" + UUID().uuidString)
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    defer { try? FileManager.default.removeItem(at:directory) }
    let export = directory.appendingPathComponent("synthetic.json")
    try VaultInterchange.export(document,to:export,format:.nativeJSON)
    try XCTAssertEqual(try VaultInterchange.read(from:export).document,document)
    try XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:export.path)[.posixPermissions] as? NSNumber)?.intValue,0o600)
    XCTAssertThrowsError(try VaultInterchange.export(document,to:export,format:.nativeJSON))
    let link = directory.appendingPathComponent("link.json")
    try FileManager.default.createSymbolicLink(at:link,withDestinationURL:export)
    XCTAssertThrowsError(try VaultInterchange.export(document,to:link,format:.nativeJSON))
    XCTAssertThrowsError(try VaultInterchange.read(from:link))
    try XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:directory.path).count,2)
    try check1PUXFixtures()
    XCTAssertTrue(ItemTemplates.makeItem(category:"信用卡").sections.flatMap(\.fields).count >= 4)
    print("PASS rich 1PIF, import conflicts/copies, full JSON/CSV histories, secure plaintext publication and bounded 1PUX ZIP")
}

private func check1PUXFixtures() throws {
    // ZIP_DEFLATED fixture independently produced by Python stdlib zipfile, not this parser.
    let fixture = Data(base64Encoded:"UEsDBBQAAAAIAFKtX11MGAkwEAAAAA4AAAARAAAAZXhwb3J0LmF0dHJpYnV0ZXOrVipLLSrOzM9TslIwrgUAUEsDBBQAAAAIAFKtX12pQ3jfwgEAAFgDAAALAAAAZXhwb3J0LmRhdGF1UsFKXDEU/RXJWusbbTfu3EjdiCCu6ixCcp0JZJJHcvOcYRhoQRC0dFdEUVAQtCsFEQsV+jN94/gX5mbeG2ao8jZ5555zcu+56TMuhA0GPVuZ+9JnHNHRsc9CUDIe6jobzM+xggf9PjNVWaQZ3gECtnoG24BKJLFC6FTaWuFrwgIVSbrLi3UjoRurjfgrHHAEuYr0n2URCbmcIEsJ8RiB1KkTbVWAJB8RsZZ1ve3qpixrEGwLcIWCvdQ3KtRJWP44en76Nfr77fn6z/DhaHT7k7jBaSq2EXO/srgIXd7JNXxQpuBayYpRDzTL9SCskRPqoBnJyFuJzKobmpSJBORKj2PUtqXMmgItK1MJXrUMR2UNmQcPLiWbFqEDzCZIZcr5P13Ovd+zTr6jE8E5oP1Sk8Yi+E3NVVKWV6ejy+87prw6GN7fkD4ORrZVg5MAX072y8OL6dVDFx1PC50aaLyKPJpTHrV4c31jurU+i9kJ4BoSu7G0/JEN0lzVe5TSgfczFuXZXXn+ddal5tHZowOgF1OFP7o8To9EYY/Af78Phw+P8ZZBM6VQJ/ZZeYxvaNz8G9FZLcdtpJkbn7KoJ4v4vQJQSwECFAMUAAAACABSrV9dTBgJMBAAAAAOAAAAEQAAAAAAAAAAAAAAgAEAAAAAZXhwb3J0LmF0dHJpYnV0ZXNQSwECFAMUAAAACABSrV9dqUN438IBAABYAwAACwAAAAAAAAAAAAAAgAE/AAAAZXhwb3J0LmRhdGFQSwUGAAAAAAIAAgB4AAAAKgIAAAAA")!
    let preview = try VaultInterchange.decode1PUX(fixture)
    XCTAssertTrue(preview.warnings.contains { $0.contains("专用控件") })
    let item = try XCTUnwrap(preview.items.first)
    XCTAssertEqual(item.title,"压缩迁移测试"); XCTAssertEqual(item.password,"synthetic-current")
    XCTAssertEqual(item.state,.archived); XCTAssertEqual(item.sourceIdentity,"1pux:account:vault:synthetic-item")
    XCTAssertEqual(item.additionalURLs,["https://second.invalid"]); XCTAssertEqual(item.tags,["测试"])
    XCTAssertEqual(item.sections.first?.fields.first?.kind,.password)
    XCTAssertTrue(item.sections.first?.fields.last?.value.contains("上海") == true)
    XCTAssertEqual(preview.revisions.first?.snapshot.password,"synthetic-old")
    try XCTAssertEqual(try VaultInterchange.decode1PUX(fixture).document,preview.document)
    let skipped = try VaultInterchange.planMerge(preview,existing:preview.items,existingRevisions:preview.revisions)
    XCTAssertEqual(skipped.conflictCount,0); XCTAssertEqual(skipped.skippedCount,1)
    let mapped = try VaultInterchange.encode(preview.document,format:.onePIF)
    let mappedObject = try XCTUnwrap(JSONSerialization.jsonObject(with:mapped) as? [String:Any])
    let mappedSecure = try XCTUnwrap(mappedObject["secureContents"] as? [String:Any])
    let mappedSections = try XCTUnwrap(mappedSecure["sections"] as? [[String:Any]])
    let mappedFields = try XCTUnwrap(mappedSections.first?["fields"] as? [[String:Any]])
    XCTAssertEqual(mappedFields.last?["k"] as? String,"address")
    XCTAssertEqual((mappedFields.last?["v"] as? [String:String])?["city"],"上海")
    // Mutate central-directory declarations while leaving the source compressed payload independent.
    let central = findZIPSignature([0x50,0x4b,0x01,0x02],in:fixture)
    var symlink = fixture; symlink[central+38+2] = 0xff; symlink[central+38+3] = 0xa1
    XCTAssertThrowsError(try VaultInterchange.decode1PUX(symlink))
    var emptyPayload = fixture; emptyPayload.replaceSubrange((central+20)..<(central+24),with:[0,0,0,0])
    XCTAssertThrowsError(try VaultInterchange.decode1PUX(emptyPayload))
    var checksum = fixture; checksum[central+16] ^= 1
    XCTAssertThrowsError(try VaultInterchange.decode1PUX(checksum))
    var bomb = fixture; bomb.replaceSubrange((central+24)..<(central+28),with:[0,0,0,4])
    XCTAssertThrowsError(try VaultInterchange.decode1PUX(bomb))
    var traversal = fixture
    let badName = Array("../ort.attributes".utf8)
    traversal.replaceSubrange(30..<(30+badName.count),with:badName)
    traversal.replaceSubrange((central+46)..<(central+46+badName.count),with:badName)
    XCTAssertThrowsError(try VaultInterchange.decode1PUX(traversal))
    var truncated = fixture; truncated.removeLast()
    XCTAssertThrowsError(try VaultInterchange.decode1PUX(truncated))
    // Additional or duplicated members and attachment metadata are rejected before partial import.
    let attrs = Data(#"{"version":3}"#.utf8)
    let empty = Data(#"{"accounts":[]}"#.utf8)
    try XCTAssertEqual(VaultInterchange.decode1PUX(storedZIP([("export.attributes",attrs),("export.data",empty)])).items.count,0)
    XCTAssertThrowsError(try VaultInterchange.decode1PUX(storedZIP([("export.attributes",attrs),("export.data",empty),("export.data",empty)])))
    XCTAssertThrowsError(try VaultInterchange.decode1PUX(storedZIP([("export.attributes",attrs),("export.data",empty),("files/photo.png",Data([1]))])))
    XCTAssertThrowsError(try VaultInterchange.decode1PUX(storedZIP([("export.attributes",Data(#"{"version":4}"#.utf8)),("export.data",empty)])))
}
private func findZIPSignature(_ signature:[UInt8],in bytes:Data)->Int {
    for index in 0...(bytes.count-signature.count) where Array(bytes[index..<(index+signature.count)]) == signature { return index }
    fatalError("Missing ZIP fixture signature")
}
func storedZIP(_ entries:[(String,Data)]) -> Data {
    var body = Data(); var central = Data()
    func number(_ value:Int,_ count:Int)->Data { Data((0..<count).map { UInt8(truncatingIfNeeded:value >> ($0*8)) }) }
    func crc(_ bytes:Data)->UInt32 { var result:UInt32 = 0xffffffff; for byte in bytes { result ^= UInt32(byte); for _ in 0..<8 { result = (result >> 1) ^ ((result & 1) == 1 ? 0xedb88320 : 0) } }; return result ^ 0xffffffff }
    for (name,bytes) in entries {
        let n = Data(name.utf8); let offset = body.count; let checksum = Int(crc(bytes))
        for chunk in [number(0x04034b50,4), number(20,2), Data(repeating:0,count:8), number(checksum,4), number(bytes.count,4), number(bytes.count,4), number(n.count,2), number(0,2), n, bytes] { body += chunk }
        for chunk in [number(0x02014b50,4), number(20,2), number(20,2), Data(repeating:0,count:8), number(checksum,4), number(bytes.count,4), number(bytes.count,4), number(n.count,2), Data(repeating:0,count:12), number(offset,4), n] { central += chunk }
    }
    let offset = body.count; body += central
    body += number(0x06054b50,4) + Data(repeating:0,count:4) + number(entries.count,2) + number(entries.count,2) + number(central.count,4) + number(offset,4) + number(0,2)
    return body
}
