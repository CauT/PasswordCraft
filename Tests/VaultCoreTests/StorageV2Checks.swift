import Foundation
import VaultCore

private func withStorageFixture(_ body: (URL, URL, URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vault-v2-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(directory, directory.appendingPathComponent("main.localvault"), directory.appendingPathComponent("backups"))
}

func runStorageV2Checks() throws {
    let password = "Synthetic-v2-password-2026"
    try withStorageFixture { _, file, root in
        let session = try VaultSession.create(at: file, password: password, backupRoot: root)
        let original = VaultItem(title: "login", password: "first", tags: ["work"], sections: [VaultSection(title: "custom", fields: [VaultField(label: "PIN", value: "1234", kind: .password)])])
        try session.save(items: [original])
        var changed = original; changed.password = "second"
        try session.save(items: [changed])
        let firstRevision = try XCTUnwrap(session.revisions(for: original.id).first)
        XCTAssertEqual(firstRevision.snapshot, original)
        let reopened = try VaultSession.open(at: file, password: password, backupRoot: root)
        XCTAssertEqual(reopened.revisions(for: original.id), [firstRevision])
        changed.state = .trashed; changed.deletedAt = Date()
        try reopened.save(items: [changed])
        try reopened.restoreRevision(itemID: original.id, revisionID: firstRevision.id)
        XCTAssertEqual(reopened.items[0].password, "first")
        XCTAssertEqual(reopened.items[0].state, .trashed)
        XCTAssertEqual(reopened.items[0].deletedAt, changed.deletedAt)
        XCTAssertEqual(reopened.revisions(for: original.id).count, 3)
        var restored = reopened.items[0]; restored.state = .active; restored.deletedAt = nil
        try reopened.save(items: [restored])
        XCTAssertThrowsError(try reopened.purge(itemID: original.id))
        XCTAssertThrowsError(try reopened.save(items: []))
        restored.state = .trashed; restored.deletedAt = Date()
        try reopened.save(items: [restored])
        try reopened.purge(itemID: original.id)
        XCTAssertTrue(reopened.items.isEmpty); XCTAssertTrue(reopened.allRevisions.isEmpty)
        let final = try VaultSession.open(at: file, password: password, backupRoot: root)
        XCTAssertTrue(final.items.isEmpty); XCTAssertTrue(final.allRevisions.isEmpty)
        print("PASS v2 structured fields, history persistence, trash restore, content rollback and explicit purge")
    }
    try withStorageFixture { directory, file, root in
        let session = try VaultSession.create(at: file, password: password, backupRoot: root)
        let stale = try VaultSession.open(at: file, password: password, backupRoot: root)
        var item = VaultItem(title: "initial", password: "synthetic-secret")
        try session.save(items: [item])
        let firstBytes = try Data(contentsOf: file)
        let firstBackup = try XCTUnwrap(try session.availableBackups().first)
        try XCTAssertEqual(Data(contentsOf: firstBackup.url), firstBytes)
        let firstRecovery = directory.appendingPathComponent("first-item-recovery.localvault")
        try session.recoverBackup(firstBackup.url, to: firstRecovery, password: password)
        try XCTAssertEqual(VaultSession.open(at: firstRecovery, password: password, backupRoot: root).items, [item])
        let initialCount = try session.availableBackups().count
        XCTAssertThrowsError(try stale.save(items: [VaultItem(title: "stale")]))
        try XCTAssertEqual(session.availableBackups().count, initialCount)
        XCTAssertTrue(stale.items.isEmpty)
        try session.save(items: [item])
        try XCTAssertEqual(session.availableBackups().count, initialCount)
        for index in 0..<25 { item.title = "revision \(index)"; try session.save(items: [item]) }
        let backups = try session.availableBackups()
        XCTAssertEqual(backups.count, 20)
        XCTAssertTrue(backups.allSatisfy(\.usesCurrentPassword))
        let latest = try XCTUnwrap(backups.first)
        let recovery = directory.appendingPathComponent("recovered.localvault")
        XCTAssertThrowsError(try session.recoverBackup(latest.url, to: recovery, password: "wrong"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: recovery.path))
        try session.recoverBackup(latest.url, to: recovery, password: password)
        let recovered = try VaultSession.open(at: recovery, password: password, backupRoot: root)
        XCTAssertEqual(recovered.items[0].title, "revision 24")
        XCTAssertThrowsError(try session.recoverBackup(latest.url, to: recovery, password: password))
        // A damaged retention candidate must never turn a completed main-file
        // save into a reported failure or be silently deleted as verified.
        let damaged = try XCTUnwrap(backups.last)
        try Data("corrupted synthetic backup".utf8).write(to: damaged.url)
        item.title = "cleanup warning"
        try session.save(items: [item])
        XCTAssertTrue(session.lastWarning != nil)
        XCTAssertTrue(FileManager.default.fileExists(atPath: damaged.url.path))
        try XCTAssertEqual(VaultSession.open(at: file, password: password, backupRoot: root).items[0].title, "cleanup warning")
        let before = try Data(contentsOf: file)
        try FileManager.default.removeItem(at: session.backupDirectory)
        try Data("not a directory".utf8).write(to: session.backupDirectory)
        item.title = "must fail"
        XCTAssertThrowsError(try session.save(items: [item]))
        try XCTAssertEqual(Data(contentsOf: file), before)
        XCTAssertEqual(session.items[0].title, "cleanup warning")
        XCTAssertFalse(firstBytes.isEmpty)
        print("PASS automatic verified backup retention, no-op suppression, recovery and fail-closed backup errors")
    }
    try withStorageFixture { directory, file, root in
        let session = try VaultSession.create(at: file, password: password, backupRoot: root)
        var item = VaultItem(title: "first", password: "original synthetic")
        try session.save(items: [item])
        try session.changePassword("Synthetic-new-password-2026")
        let beforeChange = try XCTUnwrap(try session.availableBackups().first(where: { $0.reason == "before-password-change" }))
        XCTAssertFalse(beforeChange.usesCurrentPassword)
        XCTAssertThrowsError(try VaultSession.open(at: file, password: password, backupRoot: root))
        let fresh = try VaultSession.open(at: file, password: "Synthetic-new-password-2026", backupRoot: root)
        item.title = "new key content"; try fresh.save(items: [item])
        let backups = try fresh.availableBackups()
        XCTAssertTrue(backups.contains { $0.usesCurrentPassword })
        XCTAssertTrue(backups.contains { !$0.usesCurrentPassword && $0.reason == "before-password-change" })
        let recovery = directory.appendingPathComponent("old-key-recovery.localvault")
        try fresh.recoverBackup(beforeChange.url, to: recovery, password: password)
        try XCTAssertEqual(VaultSession.open(at: recovery, password: password, backupRoot: root).items[0].title, "first")
        print("PASS password-change recovery points retain old-password identity and recover with original password")
    }
    try withStorageFixture { _, file, root in
        let session = try VaultSession.create(at: file, password: password, backupRoot: root)
        let item = VaultItem(title: "import current", password: "new")
        var old = item; old.password = "old"
        let revision = VaultRevision(snapshot: old)
        try session.save(items: [item], importedRevisions: [revision])
        try session.save(items: [item], importedRevisions: [revision])
        XCTAssertEqual(session.allRevisions.count, 1)
        var conflict = revision; conflict.snapshot.title = "conflict"
        XCTAssertThrowsError(try session.save(items: [item], importedRevisions: [conflict]))
        XCTAssertEqual(session.allRevisions, [revision])
        let orphan = VaultRevision(snapshot: VaultItem(title: "missing"))
        XCTAssertThrowsError(try session.save(items: [item], importedRevisions: [orphan]))
        print("PASS imported history merge is lossless, idempotent and rejects conflicts/orphans")
    }
    try withStorageFixture { directory, file, root in
        // Actual synthetic vault produced by delivered LocalVault 0.1 in the
        // preceding normal-launch UI journey. Its password contains no user data.
        let legacy = Data(base64Encoded: legacyV1Fixture)!
        try legacy.write(to: file)
        let session = try VaultSession.open(at: file, password: "Demo-Only-2026!", backupRoot: root)
        XCTAssertEqual(session.items.count, 2)
        XCTAssertTrue(session.items.allSatisfy { $0.state == .active && $0.sections.isEmpty })
        try XCTAssertEqual(Data(contentsOf: file), legacy)
        var updated = session.items; updated[0].notes += " upgraded"
        try session.save(items: updated)
        let envelope = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        XCTAssertEqual(envelope["version"] as? Int, 3)
        let backups = try session.availableBackups()
        XCTAssertEqual(backups.count, 2)
        let legacyBackup = try XCTUnwrap(backups.first(where: { $0.reason == "upgrade-v1" }))
        try XCTAssertEqual(Data(contentsOf: legacyBackup.url), legacy)
        let reopened = try VaultSession.open(at: file, password: "Demo-Only-2026!", backupRoot: root)
        XCTAssertEqual(reopened.vaultID, session.vaultID)
        XCTAssertEqual(reopened.items, updated)
        XCTAssertEqual(reopened.allRevisions.count, 1)
        let restored = directory.appendingPathComponent("legacy-recovered.localvault")
        try reopened.recoverBackup(legacyBackup.url, to: restored, password: "Demo-Only-2026!")
        try XCTAssertEqual(Data(contentsOf: restored), legacy)
        print("PASS actual v1 fixture read-only open, current-format migration, pinned original backup and legacy recovery")
    }
    print("PASS 5 v2 storage journeys")
}

private let legacyV1Fixture = "eyJzZWFsZWQiOiJzaXdYVW9qZmw3RllvS2h2aHFKclFNTGhIWWZLNzBxbnp2Wkh5d0ZISWROVlB0MGhZb1U4RnpNZW13dmFJXC9hRDRxZ3hSc3MzeUZRVkt2dGliTnhEbEc2ZUVpOWxqWW85YU9iVEw2YnIwcUlRQkRkeHFMMGdpeGNIMW5vWHZaRFRXOXdzeHpIV25yNW5xYlJma05JaW5WcDNiMitIdjErSVhLVEpDM1lxeWg1VFJUdXNPUGpMR1MxV2l0d0kyYVAzNE9pWTl5NDBBMkVrODBPYkNGYitJUkR0WU9kZXJQS2EyOG1oWG9KUnROanRNQnU3MldYU1wvTHM1ZktudFp1bFlNWGtaWjNib2tmKzVpQXZnY1ZYZ044NUJqdVkyYmFBU3d2bExscElcL0tkQ3Jjc3daWU1WRUZjRWpEOUszbVFrNGk0RFlSWUZTMHNvamxpcXVqdklhVkZvdjBPXC9UaWRmcmxpVlpYWHVyOXl5QVdUdWNsWWlFRnpwYTRCREdoRmZRbmFNbThlWnRlYTFpQ0R3RHpTQzNiMllPVjJXVnd3RkVtV2hSbXA5OW1penQ2eTR1aVJFSVozMXpjb2dKajczVm1sZW1rS1dsSFQ0QlVuWE5WSldVM1l2Vnl3YjQxSHdXU3pmQVpSNFZNWlNLckVnbTZTXC9Vc1JoSXV4K1VTYU56ZGsxYXpuQkVwZndrQjQycnMzU2hFeTVIREhKUk1sTWdBK3VmV08rTVBOaU96eE9rcnNwOUZsODFlMW12V0tBMXlzc3NhZDg1U2hLU1BhakI5V1ZOOHFSOFU1RGpOVW1aNVpDVXhBTlg4TlFrbEtCenhVbG1UQjFpK3VIbXJYM1pqSzU3ZVN1VVU4bWhnQjhubFhBQnV1ZGM2dE1LaGNzNnRQakdXYnd6RUw4U2dLejdMK2tRRzRxNlFGNlwvUHpxRTVKVjlJZzg0cFJ5S1lDcmVVOHo2Qld2dllBSzNzN2tXWUVlWDBnQk1cL3YwSW1zSFE3bW1WYkcxeGM3N2RQRERmTVQ2U0VKemV0ZkJPd1VLaUNoaXJcL3JWNitPS2c3Mlg2RlZjeWxaR0hZSGNXWmF5TjF3MW1ZTHRaYlNqckVTaGZjMkYyeU9CRDZTQTE4XC9WUDZVQU0yQ2tlT2lmVTFYNXFudUNCb05Md2pMN0NyZEdkcHNQSXplNXFlZjNUVlFOR1RFVzU5Z2dpZHBCZllpdWxFWnBnUzM1aEJWUXRiOHF1T01NSWJ6M3FGRmE2K1lkWVwvNHlsaVBqRTVhU250OCtqdTJRaTZ2eitYMkNRbnB1ZGhqTUtNa3FqSkh3d3FcL09LVHdSR2Q4VVRrSlhIWVZ1MVdGYUMxeTE2aE5ZVEY4N2IzZEFzMnVmdEJDWlh6bHN3UDg4ekUzVmExaDZLZ2hLYlwvWnZ0RHp6RGlnVmVaVTQwNjBkMk5ndExyVFwvY0doZUpPcjRJMEVDbXVZMlZpVXFDeVdidkFaUVJneE9uK3FleGdGMDdpT1gxZzdMc0trQVFFZTJWaXYwOVFqWGliWEIxNHpNcmVzc1UwUENKUXJ3N1lkQ05VXC8xa3VCZ3pOQVhBMmdPV2R1ZFJlaDNcL0I5aUpjMVNxMjB5RFYxamxuMHlDbzk2eVJOT1gxYmhFSXF6WlNJRFJnN3h4eGk1dUF5elwvNnRwaXVkWU1BNDZMTkNMcW5LUjZBcXJJaWVLWmJIMEtPM0VUN2dETk5DalVEM3RiZzYrVVhmTm5vUkQ1NDd6MXI2MmtPWGxLT1J5NEJ4dUdVd3RDaUV1bXNWSEpWU0lvS3lUb0E4ZlR1VUJpZnZyekpWa24yMDhcL0lSUzNFRDJ4SndNbGtaRjNCNXlwdlRGYjZlT21MbjVDMDNNSHBUOEZmMlVvVEMzSUoxc0ZnYTRQSHl5OGRtYW1SbGNWNTZNM1lmVlczYUZLeERnRm9zMWdsRDNzdmdNclBZaFFJUT09IiwidmVyc2lvbiI6MSwiY2lwaGVyIjoiQUVTLTI1Ni1HQ00iLCJrZGYiOiJQQktERjItSE1BQy1TSEEyNTYiLCJyb3VuZHMiOjYwMDAwMCwic2FsdCI6IjhXckpURWNJbGN0OVNDRFVcL3llNlVnPT0ifQ=="
