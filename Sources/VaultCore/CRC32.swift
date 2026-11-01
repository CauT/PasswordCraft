import Foundation

/// Accidental-corruption checksum only, never authentication.
enum CRC32 {
    static func checksum<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
        var value: UInt32 = 0xffffffff
        for byte in bytes {
            value ^= UInt32(byte)
            for _ in 0..<8 { value = (value >> 1) ^ ((value & 1) != 0 ? 0xedb88320 : 0) }
        }
        return ~value
    }
}
