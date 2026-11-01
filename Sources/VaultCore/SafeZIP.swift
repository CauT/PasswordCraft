import Foundation
import Compression

/// ZIP32 stored/deflate reader. Encrypted, multi-disk, ZIP64, symlink, traversal,
/// duplicate or excessive entries fail before decompression. No paths are written to disk.
enum SafeZIP {
    private struct Member { let name: String; let offset: Int; let packed: Int; let unpacked: Int; let method: Int; let flags: Int; let checksum: UInt32 }
    static func read(_ data: Data) throws -> [String: Data] {
        guard data.count <= 64 * 1024 * 1024, data.count >= 22 else { throw invalid() }
        let bytes = [UInt8](data)
        func word(_ offset: Int) throws -> Int {
            guard offset >= 0, offset <= bytes.count - 2 else { throw invalid() }; return Int(bytes[offset]) | Int(bytes[offset+1]) << 8
        }
        func dword(_ offset: Int) throws -> Int {
            guard offset >= 0, offset <= bytes.count - 4 else { throw invalid() }
            return Int(bytes[offset]) | Int(bytes[offset+1]) << 8 | Int(bytes[offset+2]) << 16 | Int(bytes[offset+3]) << 24
        }
        var end: Int?
        for offset in stride(from: bytes.count - 22, through: max(0, bytes.count - 65557), by: -1) {
            if try dword(offset) == 0x06054b50, offset + 22 + (try word(offset + 20)) == bytes.count { end = offset; break }
        }
        guard let end else { throw invalid() }
        guard try word(end+4) == 0, try word(end+6) == 0 else { throw invalid() }
        let count = try word(end+10); let centralOffset = try dword(end+16); let centralSize = try dword(end+12)
        guard count <= 2048, try word(end+8) == count, centralOffset + centralSize == end else { throw invalid() }
        var cursor = centralOffset; var names = Set<String>(); var members: [Member] = []; var total = 0
        var ranges: [Range<Int>] = []
        for _ in 0..<count {
            guard try dword(cursor) == 0x02014b50, cursor + 46 <= end else { throw invalid() }
            let flags = try word(cursor+8); let method = try word(cursor+10)
            let packed = try dword(cursor+20); let unpacked = try dword(cursor+24)
            let nameLength = try word(cursor+28); let extraLength = try word(cursor+30); let commentLength = try word(cursor+32)
            let attributes = try dword(cursor+38); let offset = try dword(cursor+42)
            let next = cursor + 46 + nameLength + extraLength + commentLength
            guard next <= end, try word(cursor+34) == 0, packed != 0xffffffff, unpacked != 0xffffffff, offset != 0xffffffff,
                  flags & ~0x080e == 0, [0,8].contains(method), unpacked <= VaultInterchange.maximumTransferBytes else { throw invalid() }
            guard let name = String(bytes: bytes[(cursor+46)..<(cursor+46+nameLength)], encoding: .utf8), !name.isEmpty,
                  !name.hasPrefix("/"), !name.contains("\\"), !name.contains("\0"), !name.split(separator:"/", omittingEmptySubsequences:false).contains(".."),
                  !name.split(separator:"/").contains("."), names.insert(name).inserted else { throw invalid() }
            let mode = (attributes >> 16) & 0xf000
            guard mode == 0 || mode == 0x8000 || (mode == 0x4000 && name.hasSuffix("/")) else { throw invalid() }
            total += unpacked; guard total <= 64 * 1024 * 1024 else { throw invalid() }
            guard offset >= 0, offset + 30 <= centralOffset, try dword(offset) == 0x04034b50,
                  try word(offset+6) == flags, try word(offset+8) == method else { throw invalid() }
            let localNameLength = try word(offset+26); let localExtraLength = try word(offset+28)
            let start = offset + 30 + localNameLength + localExtraLength
            guard start + packed <= centralOffset,
                  String(bytes: bytes[(offset+30)..<(offset+30+localNameLength)], encoding: .utf8) == name else { throw invalid() }
            if flags & 8 == 0 {
                guard try dword(offset+14) == dword(cursor+16), try dword(offset+18) == packed,
                      try dword(offset+22) == unpacked else { throw invalid() }
            }
            let range = offset..<(start + packed)
            guard !ranges.contains(where: { $0.overlaps(range) }) else { throw invalid() }
            ranges.append(range)
            if name != "export.data" && name != "export.attributes" {
                let parts = name.split(separator: "/", omittingEmptySubsequences: false)
                guard (name == "files/" && unpacked == 0) || (parts.count == 2 && parts[0] == "files" && !parts[1].isEmpty && unpacked <= AttachmentStore.maximumAttachmentBytes) else {
                    throw VaultError.message(L("1PUX 包含不支持的额外路径或超限附件，整批未导入。"))
                }
            }
            members.append(Member(name: name, offset: start, packed: packed, unpacked: unpacked, method: method, flags: flags, checksum: UInt32(try dword(cursor+16))))
            cursor = next
        }
        guard cursor == end, names.isSuperset(of: ["export.data","export.attributes"]) else { throw invalid() }
        var result: [String: Data] = [:]
        for member in members {
            let input = Array(bytes[member.offset..<(member.offset+member.packed)])
            let output: [UInt8]
            if member.method == 0 {
                guard member.packed == member.unpacked else { throw invalid() }; output = input
            } else {
                guard member.packed > 0 else { throw invalid() }
                var decoded = [UInt8](repeating: 0, count: member.unpacked + 1)
                let complete = decoded.withUnsafeMutableBufferPointer { dest in
                    input.withUnsafeBufferPointer { source -> Bool in
                        var stream = compression_stream(dst_ptr: dest.baseAddress!, dst_size: dest.count, src_ptr: source.baseAddress!, src_size: source.count, state: nil)
                        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) != COMPRESSION_STATUS_ERROR else { return false }
                        defer { compression_stream_destroy(&stream) }
                        stream.dst_ptr = dest.baseAddress!; stream.dst_size = dest.count
                        stream.src_ptr = source.baseAddress!; stream.src_size = source.count
                        while true {
                            let beforeInput = stream.src_size, beforeOutput = stream.dst_size
                            let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                            if status == COMPRESSION_STATUS_END { return stream.src_size == 0 && stream.dst_size == 1 }
                            guard status == COMPRESSION_STATUS_OK, stream.dst_size > 0,
                                  stream.src_size < beforeInput || stream.dst_size < beforeOutput else { return false }
                        }
                    }
                }
                guard complete else { throw invalid() }; output = Array(decoded.prefix(member.unpacked))
            }
            guard CRC32.checksum(output) == member.checksum else { throw invalid() }
            result[member.name] = Data(output)
        }
        return result
    }
    private static func invalid() -> VaultError { .message(L("1PUX ZIP 无效、损坏或超出安全读取范围。仅支持非加密 ZIP32 的 stored/deflate 格式。")) }
}
