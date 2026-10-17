import Foundation

/// CRC-32 (IEEE 802.3, the polynomial zip and PNG use).
public enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    public static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { buffer in
            for byte in buffer { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

/// A minimal zip writer: entries are stored uncompressed (method 0), which every unzip tool,
/// Excel and Numbers accept. No zip64, so the archive must stay under 4 GB.
public struct ZipWriter {
    public enum ZipError: LocalizedError {
        case tooLarge
        public var errorDescription: String? { "The archive is larger than 4 GB, which this zip writer does not support." }
    }

    private struct Entry {
        let name: Data
        let crc: UInt32
        let size: UInt32
        let offset: UInt32
    }

    private var body = Data()
    private var entries: [Entry] = []
    private let dosTime: UInt16
    private let dosDate: UInt16

    public init(date: Date = Date()) {
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        dosTime = UInt16((parts.hour ?? 0) << 11 | (parts.minute ?? 0) << 5 | (parts.second ?? 0) / 2)
        dosDate = UInt16(min(127, max(0, (parts.year ?? 1980) - 1980)) << 9 | (parts.month ?? 1) << 5 | (parts.day ?? 1))
    }

    public mutating func add(_ path: String, data: Data) throws {
        let name = Data(path.utf8)
        guard body.count + data.count + name.count + 30 < Int(UInt32.max), data.count < Int(UInt32.max) else { throw ZipError.tooLarge }
        let entry = Entry(name: name, crc: CRC32.checksum(data), size: UInt32(data.count), offset: UInt32(body.count))
        // Local file header.
        body.append(le32: 0x0403_4B50)
        body.append(le16: 20)              // version needed
        body.append(le16: 1 << 11)         // UTF-8 names
        body.append(le16: 0)               // stored
        body.append(le16: dosTime)
        body.append(le16: dosDate)
        body.append(le32: entry.crc)
        body.append(le32: entry.size)      // compressed
        body.append(le32: entry.size)      // uncompressed
        body.append(le16: UInt16(name.count))
        body.append(le16: 0)               // extra
        body.append(name)
        body.append(data)
        entries.append(entry)
    }

    public mutating func add(_ path: String, text: String) throws {
        try add(path, data: Data(text.utf8))
    }

    /// The finished archive: entries, central directory and end record.
    public func finish() throws -> Data {
        var out = body
        let directoryOffset = out.count
        for entry in entries {
            out.append(le32: 0x0201_4B50)
            out.append(le16: 20)           // version made by
            out.append(le16: 20)           // version needed
            out.append(le16: 1 << 11)
            out.append(le16: 0)
            out.append(le16: dosTime)
            out.append(le16: dosDate)
            out.append(le32: entry.crc)
            out.append(le32: entry.size)
            out.append(le32: entry.size)
            out.append(le16: UInt16(entry.name.count))
            out.append(le16: 0)            // extra
            out.append(le16: 0)            // comment
            out.append(le16: 0)            // disk
            out.append(le16: 0)            // internal attributes
            out.append(le32: 0)            // external attributes
            out.append(le32: entry.offset)
            out.append(entry.name)
        }
        let directorySize = out.count - directoryOffset
        guard out.count < Int(UInt32.max), entries.count < Int(UInt16.max) else { throw ZipError.tooLarge }
        out.append(le32: 0x0605_4B50)
        out.append(le16: 0)
        out.append(le16: 0)
        out.append(le16: UInt16(entries.count))
        out.append(le16: UInt16(entries.count))
        out.append(le32: UInt32(directorySize))
        out.append(le32: UInt32(directoryOffset))
        out.append(le16: 0)
        return out
    }
}

/// Reads the stored (uncompressed) entries of a zip, enough to check what ZipWriter produced.
public enum ZipReader {
    public static func entries(_ data: Data) -> [String: Data]? {
        let bytes = [UInt8](data)
        func u16(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 }
        func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }
        guard bytes.count >= 22 else { return nil }
        // The end record is the last 22 bytes when there is no archive comment.
        var end = bytes.count - 22
        while end >= 0 && u32(end) != 0x0605_4B50 { end -= 1 }
        guard end >= 0 else { return nil }
        let count = u16(end + 10)
        var p = u32(end + 16)
        var result: [String: Data] = [:]
        for _ in 0..<count {
            guard p + 46 <= bytes.count, u32(p) == 0x0201_4B50, u16(p + 10) == 0 else { return nil }
            let size = u32(p + 20), nameLength = u16(p + 28), extra = u16(p + 30), comment = u16(p + 32), offset = u32(p + 42)
            let name = String(decoding: bytes[(p + 46)..<(p + 46 + nameLength)], as: UTF8.self)
            guard offset + 30 <= bytes.count, u32(offset) == 0x0403_4B50 else { return nil }
            let start = offset + 30 + u16(offset + 26) + u16(offset + 28)
            guard start + size <= bytes.count else { return nil }
            let content = Data(bytes[start..<(start + size)])
            guard CRC32.checksum(content) == UInt32(u32(p + 16)) else { return nil }
            result[name] = content
            p += 46 + nameLength + extra + comment
        }
        return result
    }
}

extension Data {
    mutating func append(le16 value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8(value >> 8))
    }

    mutating func append(le32 value: UInt32) {
        append(le16: UInt16(value & 0xFFFF))
        append(le16: UInt16(value >> 16))
    }
}
