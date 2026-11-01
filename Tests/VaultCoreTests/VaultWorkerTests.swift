import Foundation
import VaultCore

final class VaultWorkerTests {
    private let password = "Lifecycle test password 123!"

    func testStaleOperationsCannotAffectReplacementSession() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first.localvault")
        let second = directory.appendingPathComponent("second.localvault")
        let worker = VaultWorker(backupRoot: directory.appendingPathComponent("backups"))
        _ = try await worker.open(first, password: password, create: true, generation: 1)
        await worker.invalidate(generation: 2)
        _ = try await worker.open(second, password: password, create: true, generation: 3)
        await worker.cancel(generation: 1)
        await worker.invalidate(generation: 2)
        do { try await worker.save([VaultItem(title: "stale data")], generation: 1); fatalError("stale save accepted") } catch {}
        do { try await worker.changePassword("Stale replacement password", generation: 1); fatalError("stale password change accepted") } catch {}
        do { try await worker.backup(directory.appendingPathComponent("stale-backup"), generation: 1); fatalError("stale backup accepted") } catch {}
        let item = VaultItem(title: "replacement session")
        try await worker.save([item], generation: 3)
        try XCTAssertEqual(VaultSession.open(at: second, password: password, backupRoot: directory.appendingPathComponent("backups")).items, [item])
        try XCTAssertEqual(VaultSession.open(at: first, password: password, backupRoot: directory.appendingPathComponent("backups")).items, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("stale-backup").path))
    }

    func testInvalidationBeforeOpenPreventsLateUnlockAndCreation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("late.localvault")
        let worker = VaultWorker(backupRoot: directory.appendingPathComponent("backups"))
        await worker.invalidate(generation: 2)
        for generation in [UInt64(1), UInt64(2)] {
            do { _ = try await worker.open(file, password: password, create: true, generation: generation); fatalError("invalidated open accepted") } catch {}
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        _ = try await worker.open(file, password: password, create: true, generation: 3)
        await worker.cancel(generation: 3)
        do { try await worker.save([], generation: 3); fatalError("cancelled session retained") } catch {}
        do { _ = try await worker.open(file, password: password, create: false, generation: 3); fatalError("generation reused") } catch {}
        _ = try await worker.open(file, password: password, create: false, generation: 4)
        try await worker.save([VaultItem(title: "fresh unlock")], generation: 4)
    }
}

func runVaultWorkerChecks() async throws {
    let tests = VaultWorkerTests()
    try await tests.testStaleOperationsCannotAffectReplacementSession()
    print("PASS stale worker operations cannot affect replacement vault")
    try await tests.testInvalidationBeforeOpenPreventsLateUnlockAndCreation()
    print("PASS invalidation fences late opens and single-use generations")
}
