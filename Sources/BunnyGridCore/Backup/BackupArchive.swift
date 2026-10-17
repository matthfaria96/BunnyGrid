import Foundation

/// A table or view inside a backup (Codable twin of `DatabaseObject`).
public struct BackupObject: Codable, Hashable, Sendable, Identifiable {
    public var schema: String?
    public var name: String
    public var kind: DatabaseObjectKind

    public init(schema: String?, name: String, kind: DatabaseObjectKind) {
        self.schema = schema
        self.name = name
        self.kind = kind
    }

    public init(_ object: DatabaseObject) {
        self.init(schema: object.schema, name: object.name, kind: object.kind)
    }

    public var object: DatabaseObject { DatabaseObject(schema: schema, name: name, kind: kind) }
    public var id: String { object.id }
}

/// How a backup holds the database.
public enum BackupMethod: String, Codable, CaseIterable, Sendable, Identifiable {
    /// A SQL script (CREATE + INSERT) made by `SQLDumper`: works on every engine and restores into any database of the same engine.
    case sql
    /// A page-level copy of the whole SQLite file made with the `sqlite3_backup` API.
    case sqliteFile

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .sql: "SQL (structure and data)"
        case .sqliteFile: "SQLite file copy"
        }
    }
}

/// What a backup contains; stored at the start of the `.bgbackup` file so listing never reads the payload.
public struct BackupManifest: Codable, Hashable, Sendable, Identifiable {
    public static let currentFormatVersion = 1

    public var id: UUID
    public var formatVersion: Int
    public var connectionID: UUID
    public var connectionName: String
    public var engine: DatabaseKind
    public var database: String
    /// The schema (PostgreSQL) the backup was made of; nil for engines without schemas.
    public var schema: String?
    public var createdAt: Date
    public var comment: String
    public var method: BackupMethod
    public var objects: [BackupObject]
    public var includeStructure: Bool
    public var includeData: Bool
    /// Rows written (SQL backups).
    public var rowCount: Int?
    /// Payload size before compression.
    public var uncompressedSize: Int
    public var serverVersion: String?

    public init(id: UUID = UUID(), connectionID: UUID, connectionName: String, engine: DatabaseKind, database: String,
                schema: String?, createdAt: Date = Date(), comment: String = "", method: BackupMethod = .sql,
                objects: [BackupObject] = [], includeStructure: Bool = true, includeData: Bool = true,
                rowCount: Int? = nil, uncompressedSize: Int = 0, serverVersion: String? = nil) {
        self.id = id
        self.formatVersion = Self.currentFormatVersion
        self.connectionID = connectionID
        self.connectionName = connectionName
        self.engine = engine
        self.database = database
        self.schema = schema
        self.createdAt = createdAt
        self.comment = comment
        self.method = method
        self.objects = objects
        self.includeStructure = includeStructure
        self.includeData = includeData
        self.rowCount = rowCount
        self.uncompressedSize = uncompressedSize
        self.serverVersion = serverVersion
    }

    /// "20261017143005", the name Navicat gives a backup.
    public var defaultName: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMddHHmmss"
        return formatter.string(from: createdAt)
    }
}

/// The `.bgbackup` file format (version 1), little-endian:
///
///     "BGBACKUP"            8 bytes magic
///     UInt32 version        1
///     UInt32 manifestLength
///     manifest              UTF-8 JSON (`BackupManifest`, ISO 8601 dates)
///     payload               raw DEFLATE (RFC 1951, Apple's COMPRESSION_ZLIB) of the SQL script or the SQLite file
///
/// The payload can be inflated outside the app too, e.g. `python3 -c "import zlib,sys; …zlib.decompress(d, -15)"`.
public enum BackupArchive {
    public static let magic = Data("BGBACKUP".utf8)
    public static let version: UInt32 = 1
    public static let fileExtension = "bgbackup"

    public enum ArchiveError: LocalizedError {
        case notABackup
        case unsupportedVersion(UInt32)
        case corrupt

        public var errorDescription: String? {
            switch self {
            case .notABackup: "The file is not a BunnyGrid backup."
            case .unsupportedVersion(let v): "The backup was made by a newer BunnyGrid (format \(v))."
            case .corrupt: "The backup file is damaged and cannot be read."
            }
        }
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public static func encode(manifest: BackupManifest, payload: Data) throws -> Data {
        let json = try encoder.encode(manifest)
        var out = magic
        out.append(le32: version)
        out.append(le32: UInt32(json.count))
        out.append(json)
        out.append(try compress(payload))
        return out
    }

    /// The manifest and where the compressed payload starts.
    public static func header(_ data: Data) throws -> (manifest: BackupManifest, payloadOffset: Int) {
        let bytes = [UInt8](data.prefix(16))
        guard bytes.count == 16, Data(bytes[0..<8]) == magic else { throw ArchiveError.notABackup }
        func u32(_ i: Int) -> UInt32 { UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 3]) << 24 }
        let fileVersion = u32(8)
        guard fileVersion <= version else { throw ArchiveError.unsupportedVersion(fileVersion) }
        let length = Int(u32(12))
        let start = data.startIndex + 16
        guard data.count >= 16 + length else { throw ArchiveError.corrupt }
        let manifest = try decoder.decode(BackupManifest.self, from: data[start..<(start + length)])
        return (manifest, 16 + length)
    }

    public static func decode(_ data: Data) throws -> (manifest: BackupManifest, payload: Data) {
        let (manifest, offset) = try header(data)
        let payload = try decompress(Data(data.dropFirst(offset)))
        return (manifest, payload)
    }

    /// Reads just the manifest from a file, without loading the payload.
    public static func readManifest(at url: URL) throws -> BackupManifest {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let head = try handle.read(upToCount: 16) ?? Data()
        guard head.count == 16, head.prefix(8) == magic else { throw ArchiveError.notABackup }
        let bytes = [UInt8](head)
        let length = Int(UInt32(bytes[12]) | UInt32(bytes[13]) << 8 | UInt32(bytes[14]) << 16 | UInt32(bytes[15]) << 24)
        let json = try handle.read(upToCount: length) ?? Data()
        return try header(head + json).manifest
    }

    static func compress(_ data: Data) throws -> Data {
        guard !data.isEmpty else { return Data() }
        return try (data as NSData).compressed(using: .zlib) as Data
    }

    static func decompress(_ data: Data) throws -> Data {
        guard !data.isEmpty else { return Data() }
        do {
            return try (data as NSData).decompressed(using: .zlib) as Data
        } catch {
            throw ArchiveError.corrupt
        }
    }
}

/// A backup file on disk.
public struct BackupEntry: Identifiable, Hashable, Sendable {
    public var manifest: BackupManifest
    public var fileURL: URL
    /// Size of the compressed file.
    public var fileSize: Int

    public var id: UUID { manifest.id }
    public var name: String { fileURL.deletingPathExtension().lastPathComponent }
}

/// Backups live in the data directory, one folder per connection, database and schema (Navicat's per-database
/// Backup folder): `backups/<connection id>/<database>/<schema or _>/<yyyyMMddHHmmss>.bgbackup`.
public struct BackupStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    static func safeComponent(_ name: String?) -> String {
        guard let name, !name.isEmpty else { return "_" }
        let cleaned = name.map { "/:\\".contains($0) ? "_" : $0 }
        let result = String(cleaned)
        return result == "." || result == ".." ? "_" + result : result
    }

    public func folder(connectionID: UUID, database: String, schema: String?) -> URL {
        directory.appending(path: connectionID.uuidString, directoryHint: .isDirectory)
            .appending(path: Self.safeComponent(database), directoryHint: .isDirectory)
            .appending(path: Self.safeComponent(schema), directoryHint: .isDirectory)
    }

    /// The backups of one database (and schema), newest first.
    public func list(connectionID: UUID, database: String, schema: String?) -> [BackupEntry] {
        entries(in: folder(connectionID: connectionID, database: database, schema: schema))
    }

    /// Every backup of a connection, newest first.
    public func list(connectionID: UUID) -> [BackupEntry] {
        let root = directory.appending(path: connectionID.uuidString, directoryHint: .isDirectory)
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        let files = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == BackupArchive.fileExtension }
        return Self.sorted(files.compactMap(Self.entry))
    }

    private func entries(in folder: URL) -> [BackupEntry] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return Self.sorted(files.filter { $0.pathExtension == BackupArchive.fileExtension }.compactMap(Self.entry))
    }

    private static func sorted(_ entries: [BackupEntry]) -> [BackupEntry] {
        entries.sorted { $0.manifest.createdAt > $1.manifest.createdAt }
    }

    static func entry(_ url: URL) -> BackupEntry? {
        guard let manifest = try? BackupArchive.readManifest(at: url) else { return nil }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return BackupEntry(manifest: manifest, fileURL: url, fileSize: size)
    }

    /// Writes a new backup file and returns it.
    @discardableResult
    public func write(_ manifest: BackupManifest, payload: Data) throws -> BackupEntry {
        let folder = folder(connectionID: manifest.connectionID, database: manifest.database, schema: manifest.schema)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var url = folder.appending(path: "\(manifest.defaultName).\(BackupArchive.fileExtension)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appending(path: "\(manifest.defaultName)-\(n).\(BackupArchive.fileExtension)")
            n += 1
        }
        let data = try BackupArchive.encode(manifest: manifest, payload: payload)
        try data.write(to: url, options: .atomic)
        return BackupEntry(manifest: manifest, fileURL: url, fileSize: data.count)
    }

    public func payload(of entry: BackupEntry) throws -> Data {
        try BackupArchive.decode(Data(contentsOf: entry.fileURL)).payload
    }

    public func delete(_ entry: BackupEntry) throws {
        try FileManager.default.removeItem(at: entry.fileURL)
    }

    /// Changes the comment (rewrites the file's header).
    public func setComment(_ comment: String, of entry: BackupEntry) throws -> BackupEntry {
        let data = try Data(contentsOf: entry.fileURL)
        let (manifest, offset) = try BackupArchive.header(data)
        var updated = manifest
        updated.comment = comment
        let json = try BackupArchive.encoder.encode(updated)
        var out = BackupArchive.magic
        out.append(le32: BackupArchive.version)
        out.append(le32: UInt32(json.count))
        out.append(json)
        out.append(data.dropFirst(offset))
        try out.write(to: entry.fileURL, options: .atomic)
        return BackupEntry(manifest: updated, fileURL: entry.fileURL, fileSize: out.count)
    }
}
