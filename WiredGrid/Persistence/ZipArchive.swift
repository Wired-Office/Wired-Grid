import Foundation
import Compression

/// A minimal ZIP reader and writer, enough for `.grid` and `.xlsx` files.
///
/// Writes uncompressed ("stored") entries, which every spreadsheet app reads.
/// Reads stored and deflated entries, so files from Excel and other tools open.
enum ZipArchive {
    enum ZipError: Error {
        case malformed
        case unsupportedCompression(UInt16)
        case checksumMismatch(String)
    }

    // MARK: Writing

    static func write(_ entries: [(path: String, data: Data)]) -> Data {
        var archive = Data()
        var directory = Data()
        let (time, date) = dosTimestamp(Date())

        for entry in entries {
            let name = Data(entry.path.utf8)
            let crc = crc32(entry.data)
            let size = UInt32(entry.data.count)
            let offset = UInt32(archive.count)

            archive.appendLE(UInt32(0x0403_4B50))        // local file header
            archive.appendLE(UInt16(20))                 // version needed
            archive.appendLE(UInt16(0x0800))             // flags: UTF-8 names
            archive.appendLE(UInt16(0))                  // method: stored
            archive.appendLE(time)
            archive.appendLE(date)
            archive.appendLE(crc)
            archive.appendLE(size)                       // compressed size
            archive.appendLE(size)                       // uncompressed size
            archive.appendLE(UInt16(name.count))
            archive.appendLE(UInt16(0))                  // extra length
            archive.append(name)
            archive.append(entry.data)

            directory.appendLE(UInt32(0x0201_4B50))      // central directory header
            directory.appendLE(UInt16(20))               // version made by
            directory.appendLE(UInt16(20))               // version needed
            directory.appendLE(UInt16(0x0800))
            directory.appendLE(UInt16(0))
            directory.appendLE(time)
            directory.appendLE(date)
            directory.appendLE(crc)
            directory.appendLE(size)
            directory.appendLE(size)
            directory.appendLE(UInt16(name.count))
            directory.appendLE(UInt16(0))                // extra length
            directory.appendLE(UInt16(0))                // comment length
            directory.appendLE(UInt16(0))                // disk number
            directory.appendLE(UInt16(0))                // internal attributes
            directory.appendLE(UInt32(0))                // external attributes
            directory.appendLE(offset)
            directory.append(name)
        }

        let directoryOffset = UInt32(archive.count)
        archive.append(directory)
        archive.appendLE(UInt32(0x0605_4B50))            // end of central directory
        archive.appendLE(UInt16(0))
        archive.appendLE(UInt16(0))
        archive.appendLE(UInt16(entries.count))
        archive.appendLE(UInt16(entries.count))
        archive.appendLE(UInt32(directory.count))
        archive.appendLE(directoryOffset)
        archive.appendLE(UInt16(0))                      // comment length
        return archive
    }

    // MARK: Reading

    static func read(_ data: Data) throws -> [String: Data] {
        let bytes = [UInt8](data)
        // The end-of-central-directory record sits in the last 64 KiB + 22 bytes.
        guard bytes.count >= 22 else { throw ZipError.malformed }
        var end = bytes.count - 22
        let lowest = max(0, bytes.count - 22 - 0xFFFF)
        while end >= lowest, bytes.u32(at: end) != 0x0605_4B50 { end -= 1 }
        guard end >= lowest else { throw ZipError.malformed }

        let count = Int(bytes.u16(at: end + 10))
        var cursor = Int(bytes.u32(at: end + 16))
        var entries: [String: Data] = [:]

        for _ in 0..<count {
            guard cursor + 46 <= bytes.count, bytes.u32(at: cursor) == 0x0201_4B50 else { throw ZipError.malformed }
            let method = bytes.u16(at: cursor + 10)
            let crc = bytes.u32(at: cursor + 16)
            let compressedSize = Int(bytes.u32(at: cursor + 20))
            let size = Int(bytes.u32(at: cursor + 24))
            let nameLength = Int(bytes.u16(at: cursor + 28))
            let extraLength = Int(bytes.u16(at: cursor + 30))
            let commentLength = Int(bytes.u16(at: cursor + 32))
            let localOffset = Int(bytes.u32(at: cursor + 42))
            guard cursor + 46 + nameLength <= bytes.count else { throw ZipError.malformed }
            let name = String(decoding: bytes[(cursor + 46)..<(cursor + 46 + nameLength)], as: UTF8.self)
            cursor += 46 + nameLength + extraLength + commentLength

            guard localOffset + 30 <= bytes.count, bytes.u32(at: localOffset) == 0x0403_4B50 else { throw ZipError.malformed }
            let start = localOffset + 30 + Int(bytes.u16(at: localOffset + 26)) + Int(bytes.u16(at: localOffset + 28))
            guard start + compressedSize <= bytes.count else { throw ZipError.malformed }
            if name.hasSuffix("/") { continue }                // directory entry

            let stored = Data(bytes[start..<(start + compressedSize)])
            let contents: Data
            switch method {
            case 0: contents = stored
            case 8: contents = try inflate(stored, expectedSize: size)
            default: throw ZipError.unsupportedCompression(method)
            }
            guard crc32(contents) == crc else { throw ZipError.checksumMismatch(name) }
            entries[name] = contents
        }
        return entries
    }

    /// Raw DEFLATE (what ZIP uses) is `COMPRESSION_ZLIB` in Apple's Compression framework.
    private static func inflate(_ data: Data, expectedSize: Int) throws -> Data {
        if expectedSize == 0 { return Data() }
        var output = [UInt8](repeating: 0, count: expectedSize)
        let written = data.withUnsafeBytes { source in
            compression_decode_buffer(
                &output, expectedSize,
                source.bindMemory(to: UInt8.self).baseAddress!, data.count,
                nil, COMPRESSION_ZLIB
            )
        }
        guard written == expectedSize else { throw ZipError.malformed }
        return Data(output)
    }

    // MARK: Helpers

    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
        return value
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }

    private static func dosTimestamp(_ date: Date) -> (time: UInt16, date: UInt16) {
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let time = (parts.hour ?? 0) << 11 | (parts.minute ?? 0) << 5 | (parts.second ?? 0) / 2
        let day = max((parts.year ?? 1980) - 1980, 0) << 9 | (parts.month ?? 1) << 5 | (parts.day ?? 1)
        return (UInt16(time), UInt16(day))
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}

private extension [UInt8] {
    func u16(at offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        return UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }

    func u32(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        return UInt32(self[offset]) | UInt32(self[offset + 1]) << 8 | UInt32(self[offset + 2]) << 16 | UInt32(self[offset + 3]) << 24
    }
}
