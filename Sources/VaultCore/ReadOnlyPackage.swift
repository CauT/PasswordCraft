import Foundation
import Darwin

/// Holds directory descriptors so package members cannot redirect reads through symlinks.
final class ReadOnlyPackage {
    private let descriptor: Int32
    init(_ url: URL) throws {
        descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Self.invalid() }
    }
    private init(descriptor: Int32) { self.descriptor = descriptor }
    deinit { Darwin.close(descriptor) }
    func directory(_ name: String) throws -> ReadOnlyPackage {
        guard AttachmentStore.validName(name) else { throw Self.invalid() }
        let child = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard child >= 0 else { throw Self.invalid() }
        return ReadOnlyPackage(descriptor: child)
    }
    func names() throws -> Set<String> {
        // A newly opened descriptor has its own enumeration offset.
        let enumerator = openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard enumerator >= 0 else { throw Self.invalid() }
        guard let directory = fdopendir(enumerator) else { Darwin.close(enumerator); throw Self.invalid() }
        defer { closedir(directory) }
        var names: Set<String> = []
        errno = 0
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(validatingUTF8: $0) }
            }
            guard let name else { throw Self.invalid() }
            if name == "." || name == ".." { errno = 0; continue }
            guard AttachmentStore.validName(name), names.insert(name).inserted, names.count <= 4096 else { throw Self.invalid() }
            errno = 0
        }
        guard errno == 0 else { throw Self.invalid() }
        return names
    }
    func snapshot(expectedNames: Set<String>, maximumFileBytes: Int, maximumTotalBytes: Int) throws -> [String: Data] {
        guard try names() == expectedNames else { throw Self.invalid() }
        var result: [String: Data] = [:], stamps: [String: stat] = [:]
        var total = 0
        for name in expectedNames.sorted() {
            let fd = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw Self.invalid() }
            defer { Darwin.close(fd) }
            var before = stat(), after = stat()
            guard fstat(fd, &before) == 0 else { throw Self.invalid() }
            let bytes = try BoundedFileReader.read(descriptor: fd, maximumBytes: min(maximumFileBytes, maximumTotalBytes - total))
            guard fstat(fd, &after) == 0, Self.same(before, after) else { throw Self.invalid() }
            total += bytes.count; result[name] = bytes; stamps[name] = after
        }
        guard try names() == expectedNames else { throw Self.invalid() }
        for (name, stamp) in stamps {
            var current = stat()
            guard fstatat(descriptor, name, &current, AT_SYMLINK_NOFOLLOW) == 0, Self.same(stamp, current) else { throw Self.invalid() }
        }
        return result
    }
    /// Bounded recursive snapshot for legacy packages containing resources and nested data.
    func snapshotTree(maximumFileBytes: Int, maximumTotalBytes: Int) throws -> [String: Data] {
        var result: [String: Data] = [:], total = 0, entries = 0
        var validations: [() throws -> Void] = []
        func visit(_ package: ReadOnlyPackage, prefix: String, depth: Int) throws {
            guard depth <= 8 else { throw Self.invalid() }
            let names = try package.names()
            var stamps: [String: stat] = [:]
            for name in names.sorted() {
                entries += 1; guard entries <= 4096 else { throw Self.invalid() }
                var before = stat()
                guard fstatat(package.descriptor, name, &before, AT_SYMLINK_NOFOLLOW) == 0 else { throw Self.invalid() }
                stamps[name] = before
                let path = prefix + name
                switch before.st_mode & S_IFMT {
                case S_IFDIR:
                    let child = try package.directory(name)
                    var opened = stat()
                    guard fstat(child.descriptor, &opened) == 0, Self.same(before, opened) else { throw Self.invalid() }
                    try visit(child, prefix: path + "/", depth: depth + 1)
                case S_IFREG:
                    let fd = openat(package.descriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                    guard fd >= 0 else { throw Self.invalid() }
                    defer { Darwin.close(fd) }
                    var opened = stat(), after = stat()
                    guard fstat(fd, &opened) == 0, Self.same(before, opened) else { throw Self.invalid() }
                    let bytes = try BoundedFileReader.read(descriptor: fd, maximumBytes: min(maximumFileBytes, maximumTotalBytes - total))
                    guard fstat(fd, &after) == 0, Self.same(before, after) else { throw Self.invalid() }
                    total += bytes.count; result[path] = bytes
                default: throw Self.invalid()
                }
            }
            validations.append {
                guard try package.names() == names else { throw Self.invalid() }
                for (name, stamp) in stamps {
                    var after = stat()
                    guard fstatat(package.descriptor, name, &after, AT_SYMLINK_NOFOLLOW) == 0, Self.same(stamp, after) else { throw Self.invalid() }
                }
            }
        }
        try visit(self, prefix: "", depth: 0)
        for validate in validations { try validate() }
        return result
    }
    private static func same(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode == b.st_mode && a.st_size == b.st_size &&
        a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
        a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
    private static func invalid() -> VaultError { .message(L("密码库目录无效、含链接/特殊文件、读取期间发生变化或超出读取范围；整批未导入。")) }
}
