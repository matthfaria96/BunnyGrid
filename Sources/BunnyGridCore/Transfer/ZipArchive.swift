import Compression
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

/// Raw DEFLATE (RFC 1951, what zip method 8 holds) through the Compression framework, whose ZLIB
/// algorithm reads and writes raw deflate streams without the zlib header.
public enum Deflate {
    public static func compress(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        let capacity = data.count + data.count / 16 + 64
        var out = Data(count: capacity)
        let written = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        out.count = written
        return out
    }

    /// Inflates `data`, which must expand to exactly `size` bytes (the size the zip directory records).
    public static func decompress(_ data: Data, size: Int) -> Data? {
        guard size > 0 else { return Data() }
        guard !data.isEmpty else { return nil }
        var out = Data(count: size)
        let written = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, size,
                                          src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        return written == size ? out : nil
    }
}

/// A minimal zip writer: entries are deflated (method 8) when that makes them smaller, otherwise
/// stored (method 0); every unzip tool, Excel and Numbers accept both. No zip64, so the archive
/// must stay under 4 GB.
public struct ZipWriter {
    public enum ZipError: LocalizedError {
        case tooLarge
        public var errorDescription: String? { "The archive is larger than 4 GB, which this zip writer does not support." }
    }

    private struct Entry {
        let name: Data
        let crc: UInt32
        let size: UInt32
        let compressedSize: UInt32
        let method: UInt16
        let offset: UInt32
    }

    private var body = Data()
    private var entries: [Entry] = []
    private let dosTime: UInt16
    private let dosDate: UInt16

    /// Deflate entries (false writes every entry stored, as earlier versions did).
    public var compresses = true

    public init(date: Date = Date()) {
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        dosTime = UInt16((parts.hour ?? 0) << 11 | (parts.minute ?? 0) << 5 | (parts.second ?? 0) / 2)
        dosDate = UInt16(min(127, max(0, (parts.year ?? 1980) - 1980)) << 9 | (parts.month ?? 1) << 5 | (parts.day ?? 1))
    }

    public mutating func add(_ path: String, data: Data) throws {
        let name = Data(path.utf8)
        guard body.count + data.count + name.count + 30 < Int(UInt32.max), data.count < Int(UInt32.max) else { throw ZipError.tooLarge }
        let deflated = compresses ? Deflate.compress(data).flatMap { $0.count < data.count ? $0 : nil } : nil
        let payload = deflated ?? data
        let entry = Entry(name: name, crc: CRC32.checksum(data), size: UInt32(data.count), compressedSize: UInt32(payload.count),
                          method: deflated == nil ? 0 : 8, offset: UInt32(body.count))
        // Local file header.
        body.append(le32: 0x0403_4B50)
        body.append(le16: 20)              // version needed
        body.append(le16: 1 << 11)         // UTF-8 names
        body.append(le16: entry.method)
        body.append(le16: dosTime)
        body.append(le16: dosDate)
        body.append(le32: entry.crc)
        body.append(le32: entry.compressedSize)
        body.append(le32: entry.size)      // uncompressed
        body.append(le16: UInt16(name.count))
        body.append(le16: 0)               // extra
        body.append(name)
        body.append(payload)
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
            out.append(le16: entry.method)
            out.append(le16: dosTime)
            out.append(le16: dosDate)
            out.append(le32: entry.crc)
            out.append(le32: entry.compressedSize)
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

/// Reads the stored and deflated entries of a zip (what ZipWriter, Excel and Numbers write).
/// No zip64, encryption or other methods: such an archive returns nil.
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
            guard p + 46 <= bytes.count, u32(p) == 0x0201_4B50, u16(p + 8) & 1 == 0 else { return nil }
            let method = u16(p + 10)
            guard method == 0 || method == 8 else { return nil }
            let size = u32(p + 20), uncompressed = u32(p + 24), nameLength = u16(p + 28), extra = u16(p + 30), comment = u16(p + 32), offset = u32(p + 42)
            let name = String(decoding: bytes[(p + 46)..<(p + 46 + nameLength)], as: UTF8.self)
            guard offset + 30 <= bytes.count, u32(offset) == 0x0403_4B50 else { return nil }
            let start = offset + 30 + u16(offset + 26) + u16(offset + 28)
            guard start + size <= bytes.count else { return nil }
            let raw = Data(bytes[start..<(start + size)])
            guard let content = method == 0 ? raw : Deflate.decompress(raw, size: uncompressed) else { return nil }
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
