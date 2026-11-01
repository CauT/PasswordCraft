import Foundation
import VaultCore

func runWorkspaceChecks() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let backups = root.appendingPathComponent("backups")
    let first = root.appendingPathComponent("personal.localvault"), second = root.appendingPathComponent("work.localvault")
    let passwordA = "Workspace-first-synthetic!", passwordB = "Workspace-second-synthetic!"
    let source = try VaultSession.create(at: first, password: passwordA, backupRoot: backups)
    let bytes = Data("跨库附件 · original bytes\n".utf8)
    var item = VaultItem(title: "Shared search title", username: "synthetic-user", password: "hidden-search-secret", notes: "notes query", sections: [VaultSection(title: "Extra", fields: [VaultField(label: "Key label", value: "custom-hidden-value", kind: .password), VaultField(label: "Office", value: "visible-search-value")])])
    let other = VaultItem(title: "Second batch item", state: .archived)
    try source.save(items: [item, other])
    try source.addAttachment(itemID: item.id, name: "中文.txt", mediaType: "text/plain", data: bytes)
    item = source.items[0]; item.password = "updated-hidden-secret"
    try source.save(items: [item, other])
    let original = source.transferDocument
    let backupDirectory = source.backupDirectory
    source.lock()
    let target = try VaultSession.create(at: second, password: passwordB, backupRoot: backups); target.lock()
    let worker = VaultWorker(backupRoot: backups)
    _ = try await worker.open(first, password: passwordA, create: false, generation: 1)
    _ = try await worker.open(second, password: passwordB, create: false, generation: 2)
    var workspace = try await worker.select(first, generation: 3)
    XCTAssertEqual(workspace.unlockedVaults.count, 2)
    XCTAssertEqual(workspace.active?.items, original.items)
    XCTAssertEqual(VaultSearch.search(workspace.unlockedVaults, query: "visible-search-value").count, 1)
    for hidden in ["updated-hidden-secret", "custom-hidden-value", "Second batch item"] {
        XCTAssertTrue(VaultSearch.search(workspace.unlockedVaults, query: hidden).isEmpty)
    }
    do { try await worker.save([], generation: 2); fatalError("stale workspace save accepted") } catch {}
    _ = try await worker.transfer(itemIDs: [item.id], to: second, move: false, generation: 3)
    let firstCopy = try Data(contentsOf: second)
    _ = try await worker.transfer(itemIDs: [item.id], to: second, move: false, generation: 3)
    try XCTAssertEqual(Data(contentsOf: second), firstCopy)
    workspace = try await worker.workspace(generation: 3)
    let hits = VaultSearch.search(workspace.unlockedVaults, query: item.title)
    XCTAssertEqual(hits.count, 2); XCTAssertEqual(Set(hits.map(\.id)).count, 2)
    let reopened = try VaultSession.open(at: second, password: passwordB, backupRoot: backups)
    XCTAssertEqual(reopened.items, [item]); XCTAssertEqual(reopened.allRevisions, original.revisions)
    try XCTAssertEqual(reopened.attachmentData(itemID: item.id, attachmentID: item.attachments[0].id), bytes)
    reopened.lock()
    // A stale target must reject even an identical/no-op copy, before source mutation.
    let external = try VaultSession.open(at: second, password: passwordB, backupRoot: backups)
    try external.save(items: external.items + [VaultItem(title: "external change")]); external.lock()
    let sourceBefore = try Data(contentsOf: first), destinationBefore = try Data(contentsOf: second)
    do { _ = try await worker.transfer(itemIDs: [item.id], to: second, move: true, generation: 3); fatalError("stale target accepted") } catch {}
    try XCTAssertEqual(Data(contentsOf: first), sourceBefore); try XCTAssertEqual(Data(contentsOf: second), destinationBefore)
    _ = try await worker.lockVault(second, generation: 4)
    _ = try await worker.open(second, password: passwordB, create: false, generation: 5)
    _ = try await worker.select(first, generation: 6)
    // Source commit fails AFTER destination durability: no items disappear; retry is idempotent.
    let heldBackups = root.appendingPathComponent("held-source-backups")
    try fm.moveItem(at: backupDirectory, to: heldBackups)
    try Data("blocking backup directory".utf8).write(to: backupDirectory)
    let result = try await worker.transfer(itemIDs: [item.id, other.id], to: second, move: true, generation: 6)
    guard case .sourceRetained(2, _) = result else { fatalError("partial move was not reported") }
    try XCTAssertEqual(Data(contentsOf: first), sourceBefore)
    let partialTarget = try VaultSession.open(at: second, password: passwordB, backupRoot: backups)
    XCTAssertTrue(partialTarget.items.contains(other)); partialTarget.lock()
    let savedTarget = try Data(contentsOf: second)
    try fm.removeItem(at: backupDirectory); try fm.moveItem(at: heldBackups, to: backupDirectory)
    let retried = try await worker.transfer(itemIDs: [item.id, other.id], to: second, move: true, generation: 6)
    guard case .moved(2, _) = retried else { fatalError("move retry did not finish") }
    try XCTAssertEqual(Data(contentsOf: second), savedTarget)
    let movedSource = try VaultSession.open(at: first, password: passwordA, backupRoot: backups)
    XCTAssertTrue(movedSource.items.allSatisfy { $0.state == .trashed })
    try XCTAssertEqual(movedSource.attachmentData(itemID: item.id, attachmentID: item.attachments[0].id), bytes)
    movedSource.lock()
    let afterMove = try await worker.workspace(generation: 6)
    XCTAssertEqual(VaultSearch.search(afterMove.unlockedVaults, query: item.title).count, 1)
    // Selecting a locked vault retains others, and invalidation still clears every session.
    workspace = try await worker.select(root.appendingPathComponent("not-opened"), generation: 7)
    XCTAssertTrue(workspace.active == nil); XCTAssertEqual(workspace.unlockedVaults.count, 2)
    await worker.invalidate(generation: 8)
    workspace = try await worker.workspace(generation: 8)
    XCTAssertTrue(workspace.unlockedVaults.isEmpty); XCTAssertTrue(workspace.active == nil)
    do { _ = try await worker.open(first, password: passwordA, create: false, generation: 7); fatalError("late open accepted") } catch {}
    _ = try await worker.open(second, password: passwordB, create: false, generation: 9)
    await worker.cancel(generation: 1); await worker.invalidate(generation: 8)
    workspace = try await worker.workspace(generation: 9); XCTAssertEqual(workspace.unlockedVaults.count, 1)
    // Aliases cannot produce independent writable sessions or copy into the same file.
    let alias = root.appendingPathComponent("alias.localvault")
    try fm.createSymbolicLink(at: alias, withDestinationURL: second)
    workspace = try await worker.select(alias, generation: 10)
    XCTAssertEqual(workspace.unlockedVaults.count, 1)
    do { _ = try await worker.transfer(itemIDs: [item.id], to: alias, move: true, generation: 10); fatalError("same-file move accepted") } catch {}
    let duplicate = root.appendingPathComponent("duplicate.localvault")
    try fm.copyItem(at: second, to: duplicate)
    do { _ = try await worker.open(duplicate, password: passwordB, create: false, generation: 11); fatalError("same-identity backup opened concurrently") } catch {}
    workspace = try await worker.workspace(generation: 11); XCTAssertEqual(workspace.unlockedVaults.count, 1)
    // A mismatched item with the same UUID never overwrites either vault.
    _ = try await worker.open(first, password: passwordA, create: false, generation: 12)
    var changed = item; changed.notes = "diverged content"
    try await worker.save([changed, other], generation: 12)
    let conflictSource = try Data(contentsOf: first), conflictTarget = try Data(contentsOf: second)
    do { _ = try await worker.transfer(itemIDs: [item.id], to: second, move: true, generation: 12); fatalError("conflicting identity accepted") } catch {}
    try XCTAssertEqual(Data(contentsOf: first), conflictSource); try XCTAssertEqual(Data(contentsOf: second), conflictTarget)
    // Re-select detects external replacement and removes stale plaintext from the workspace.
    let freshExternal = try VaultSession.open(at: second, password: passwordB, backupRoot: backups)
    try freshExternal.save(items: freshExternal.items + [VaultItem(title: "later external change")]); freshExternal.lock()
    do { _ = try await worker.select(second, generation: 13); fatalError("stale selection accepted") } catch {}
    workspace = try await worker.workspace(generation: 13)
    XCTAssertEqual(workspace.unlockedVaults.count, 1); XCTAssertTrue(workspace.active == nil)
    _ = try await worker.select(first, generation: 14)
    await worker.cancel(generation: 12)
    workspace = try await worker.workspace(generation: 14)
    XCTAssertTrue(workspace.active != nil)
    await worker.invalidate(generation: 15)
    // Resident-vault bound rejects before creating another file; locking frees a slot.
    for index in 0..<VaultWorker.maximumUnlockedVaults {
        _ = try await worker.open(root.appendingPathComponent("bounded-\(index).localvault"), password: passwordA, create: true, generation: UInt64(16 + index))
    }
    let excess = root.appendingPathComponent("excess.localvault")
    do { _ = try await worker.open(excess, password: passwordA, create: true, generation: 24); fatalError("resident limit exceeded") } catch {}
    XCTAssertFalse(fm.fileExists(atPath: excess.path))
    _ = try await worker.lockVault(root.appendingPathComponent("bounded-0.localvault"), generation: 25)
    _ = try await worker.open(excess, password: passwordA, create: true, generation: 26)
    workspace = try await worker.workspace(generation: 26); XCTAssertEqual(workspace.unlockedVaults.count, VaultWorker.maximumUnlockedVaults)
    await worker.invalidate(generation: 27)
    print("PASS workspace lifecycle, independent passwords, scoped search, alias rejection, attachment/history transfer and recoverable move retry")
}
