import Foundation
import VaultCore

func runTOTPChecks() throws {
    // RFC6238 Appendix B; seeds differ by algorithm as specified in reference code.
    let seeds = ["12345678901234567890", "12345678901234567890123456789012", "1234567890123456789012345678901234567890123456789012345678901234"]
    let algorithms = ["SHA1", "SHA256", "SHA512"]
    let times: [TimeInterval] = [59,1111111109,1111111111,1234567890,2000000000,20000000000]
    let expected = [["94287082","46119246","90693936"], ["07081804","68084774","25091201"], ["14050471","67062674","99943326"], ["89005924","91819424","93441116"], ["69279037","90698825","38618901"], ["65353130","77737706","47863826"]]
    for algorithm in 0..<3 {
        let key = base32Fixture(Data(seeds[algorithm].utf8))
        let config = try TOTPConfiguration("otpauth://totp/RFC:fixture?secret=\(key)&algorithm=\(algorithms[algorithm])&digits=8&period=30")
        for index in times.indices {
            let date = Date(timeIntervalSince1970:times[index])
            let code = try config.code(at:date)
            XCTAssertEqual(code.value,expected[index][algorithm])
            XCTAssertTrue(code.remaining(at:date) > 0 && code.remaining(at:date) <= 30)
        }
    }
    // RFC4226 counter vectors are also TOTP vectors at timestamps counter * 30.
    let key = base32Fixture(Data(seeds[0].utf8))
    let config = try TOTPConfiguration(key.lowercased())
    let hotp = ["755224","287082","359152","969429","338314","254676","287922","162583","399871","520489"]
    for (counter,value) in hotp.enumerated() {
        try XCTAssertEqual(config.code(at:Date(timeIntervalSince1970:Double(counter*30))).value,value)
    }
    let before = try config.code(at:Date(timeIntervalSince1970:29.9))
    XCTAssertEqual(before.value,"755224"); XCTAssertEqual(before.validUntil,Date(timeIntervalSince1970:30))
    try XCTAssertEqual(config.code(at:Date(timeIntervalSince1970:30)).value,"287082")
    let custom = try TOTPConfiguration("otpauth://totp/Test?secret=\(key)&period=60&digits=7")
    try XCTAssertEqual(custom.code(at:Date(timeIntervalSince1970:59)).value,"4755224")
    try XCTAssertEqual(TOTPConfiguration("MY======").code(at:Date(timeIntervalSince1970:59)),TOTPConfiguration("m y").code(at:Date(timeIntervalSince1970:59)))
    let bad = ["", "A", "AB", "M0", "MZ======", "MY=====", "MY=======", "MY=AA", "otpauth://hotp/Test?secret=\(key)&counter=0", "otpauth://totp/Test?secret=\(key)&secret=\(key)", "otpauth://totp/Test?secret=\(key)&period=0", "otpauth://totp/Test?secret=\(key)&algorithm=MD5", "otpauth://totp/Test?secret=\(key)&digits=10", "otpauth://totp/Test?secret=\(key)&unknown=1", "otpauth://totp/Test?issuer=missing", String(repeating:"A",count:9000)]
    for input in bad { XCTAssertThrowsError(try TOTPConfiguration(input)) }
    for value in [-1,Double.infinity,Double.nan,Double.greatestFiniteMagnitude] {
        XCTAssertThrowsError(try config.code(at:Date(timeIntervalSince1970:value)))
    }
    // OTP secrets survive the same encrypted-store and transfer boundaries as ordinary fields.
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    defer { try? FileManager.default.removeItem(at:root) }
    let file = root.appendingPathComponent("otp.localvault")
    let session = try VaultSession.create(at:file,password:"Synthetic-test-master!",backupRoot:root.appendingPathComponent("backups"))
    let item = VaultItem(title:"Synthetic OTP",sections:[VaultSection(title:"OTP",fields:[VaultField(label:"OTP",value:key,kind:.otp)])])
    try session.save(items:[item]); session.lock()
    let reopened = try VaultSession.open(at:file,password:"Synthetic-test-master!",backupRoot:root.appendingPathComponent("backups"))
    XCTAssertEqual(reopened.items,[item])
    let exported = try VaultInterchange.encode(VaultTransferDocument(items:reopened.items),format:.nativeJSON)
    try XCTAssertEqual(VaultInterchange.decodeJSON(exported).items,[item])
    print("PASS RFC6238 all18 vectors, RFC4226 counters, strict OTP provisioning, rollover and encrypted persistence")
}

private func base32Fixture(_ input: Data) -> String {
    let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
    let bits = input.flatMap { byte in (0..<8).reversed().map { Int((byte >> $0) & 1) } }
    return stride(from:0,to:bits.count,by:5).map { start in
        var value = 0
        for offset in 0..<5 { value = value*2 + (start+offset < bits.count ? bits[start+offset] : 0) }
        return String(alphabet[value])
    }.joined()
}
