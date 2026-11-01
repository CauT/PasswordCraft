import Foundation
import VaultCore

private let contentionPassword = "Synthetic-process-contention!"

func runContentionChild(_ arguments: [String]) throws {
    let root = URL(fileURLWithPath: arguments[2]), name = arguments[3]
    let session = try VaultSession.open(at: root.appendingPathComponent("shared.localvault"), password: contentionPassword, backupRoot: root.appendingPathComponent("backups"))
    try Data().write(to: root.appendingPathComponent(name + ".ready"))
    let deadline = Date().addingTimeInterval(10)
    while !FileManager.default.fileExists(atPath: root.appendingPathComponent("go").path) {
        guard Date() < deadline else { throw VaultError.message("Contention barrier timed out") }; Thread.sleep(forTimeInterval: 0.01)
    }
    let outcome: String
    do { try session.save(items: [VaultItem(title: name)]); outcome = "saved" }
    catch { outcome = "rejected" }
    try Data(outcome.utf8).write(to: root.appendingPathComponent(name + ".result"))
}

func runConcurrentSaveChecks() throws {
    let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let session = try VaultSession.create(at: root.appendingPathComponent("shared.localvault"), password: contentionPassword, backupRoot: root.appendingPathComponent("backups"))
    session.lock()
    var processes: [Process] = []
    defer { for process in processes where process.isRunning { process.terminate(); process.waitUntilExit() } }
    for name in ["first", "second"] {
        let process = Process(); process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["--contention-child", root.path, name]
        try process.run(); processes.append(process)
    }
    let deadline = Date().addingTimeInterval(15)
    while !["first", "second"].allSatisfy({ fm.fileExists(atPath: root.appendingPathComponent($0 + ".ready").path) }) {
        guard Date() < deadline else { throw VaultError.message("Children failed to reach the save barrier") }; Thread.sleep(forTimeInterval: 0.01)
    }
    try Data().write(to: root.appendingPathComponent("go"))
    while processes.contains(where: \.isRunning) {
        guard Date() < deadline else { throw VaultError.message("Concurrent save timed out") }; Thread.sleep(forTimeInterval: 0.01)
    }
    XCTAssertTrue(processes.allSatisfy { $0.terminationStatus == 0 })
    let outcomes = try ["first", "second"].map { try String(contentsOf: root.appendingPathComponent($0 + ".result"), encoding: .utf8) }
    XCTAssertEqual(outcomes.sorted(), ["rejected", "saved"])
    let reopened = try VaultSession.open(at: root.appendingPathComponent("shared.localvault"), password: contentionPassword, backupRoot: root.appendingPathComponent("backups"))
    XCTAssertEqual(reopened.items.count, 1)
    XCTAssertEqual(reopened.items[0].title, outcomes[0] == "saved" ? "first" : "second")
    print("PASS two real processes race one vault: exactly one commit, no lost update or partial file")
}
