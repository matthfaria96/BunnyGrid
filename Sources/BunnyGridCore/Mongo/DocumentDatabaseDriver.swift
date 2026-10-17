import Foundation

/// A find over one collection: the collection viewer's filter / sort / projection bar and paging.
public struct DocumentQuery: Hashable, Sendable {
    public var filter: BSONDocument
    public var sort: BSONDocument
    public var projection: BSONDocument
    public var skip: Int
    public var limit: Int?

    public init(filter: BSONDocument = BSONDocument(), sort: BSONDocument = BSONDocument(), projection: BSONDocument = BSONDocument(),
                skip: Int = 0, limit: Int? = nil) {
        self.filter = filter
        self.sort = sort
        self.projection = projection
        self.skip = skip
        self.limit = limit
    }
}

public struct DocumentUpdateResult: Hashable, Sendable {
    public var matched: Int
    public var modified: Int
    public var upsertedID: BSON?

    public init(matched: Int, modified: Int, upsertedID: BSON? = nil) {
        self.matched = matched
        self.modified = modified
        self.upsertedID = upsertedID
    }
}

/// A collection or view from `listCollections`.
public struct CollectionInfo: Hashable, Sendable {
    public enum Kind: String, Sendable { case collection, view, timeseries }
    public var name: String
    public var kind: Kind
    public var options: BSONDocument

    public init(name: String, kind: Kind, options: BSONDocument = BSONDocument()) {
        self.name = name
        self.kind = kind
        self.options = options
    }
}

/// Document operations for engines whose data isn't tables (MongoDB). Drivers that implement this also conform
/// to `DatabaseDriver`, which serves the navigator and a flattened grid; the collection viewer and the shell use these.
/// Every call names the database: one connection serves them all.
public protocol DocumentDatabaseDriver: DatabaseDriver {
    /// Runs a database command (`{ ping: 1 }`, `{ collStats: "c" }`…) and returns the reply; throws on `ok: 0`.
    func runCommand(_ command: BSONDocument, database: String) async throws -> BSONDocument
    func listCollections(database: String) async throws -> [CollectionInfo]
    func find(_ query: DocumentQuery, database: String, collection: String) async throws -> [BSONDocument]
    func count(filter: BSONDocument, database: String, collection: String) async throws -> Int
    /// Runs a pipeline, reading at most `limit` documents.
    func aggregate(_ pipeline: [BSONDocument], database: String, collection: String, limit: Int?) async throws -> [BSONDocument]
    /// Inserts documents (adding `_id` where missing) and returns their ids.
    @discardableResult
    func insert(_ documents: [BSONDocument], database: String, collection: String) async throws -> [BSON]
    func update(filter: BSONDocument, update: BSON, many: Bool, upsert: Bool, database: String, collection: String) async throws -> DocumentUpdateResult
    func delete(filter: BSONDocument, many: Bool, database: String, collection: String) async throws -> Int
    /// The `explain` reply (`queryPlanner.winningPlan`…) for a find / aggregate / count command.
    func explain(_ command: BSONDocument, database: String) async throws -> BSONDocument
}

extension DocumentDatabaseDriver {
    public func listIndexDocuments(database: String, collection: String) async throws -> [BSONDocument] {
        let reply = try await runCommand(["listIndexes": .string(collection)], database: database)
        return Self.firstBatch(reply)
    }

    @discardableResult
    public func createIndex(keys: BSONDocument, options: BSONDocument = BSONDocument(), database: String, collection: String) async throws -> String {
        var index = options
        let name = options["name"]?.stringValue ?? keys.elements.map { "\($0.key)_\(BSONFormat.display($0.value))" }.joined(separator: "_")
        index["key"] = .document(keys)
        index["name"] = .string(name)
        _ = try await runCommand(["createIndexes": .string(collection), "indexes": .array([.document(index)])], database: database)
        return name
    }

    public func dropIndex(_ name: String, database: String, collection: String) async throws {
        _ = try await runCommand(["dropIndexes": .string(collection), "index": .string(name)], database: database)
    }

    /// Storage statistics from `$collStats` (count, size, storageSize, totalIndexSize, nindexes…).
    public func collectionStats(database: String, collection: String) async throws -> BSONDocument {
        let documents = try await aggregate([["$collStats": .document(["storageStats": .document([:])])]],
                                            database: database, collection: collection, limit: 1)
        return documents.first?["storageStats"]?.documentValue ?? BSONDocument()
    }

    static func firstBatch(_ reply: BSONDocument) -> [BSONDocument] {
        guard case .document(let cursor)? = reply["cursor"], case .array(let batch)? = cursor["firstBatch"] else { return [] }
        return batch.compactMap(\.documentValue)
    }
}

/// Marks for the extra navigator objects a document store lists next to its collections and views.
/// MongoDB has no schemas, so `DatabaseObject.schema` carries the mark.
public enum DocumentCatalog {
    /// GridFS bucket `fs` (collections `fs.files` and `fs.chunks`).
    public static let gridFSSchema = "$gridfs"
    /// Prefix of an index object's schema; the rest is its collection.
    public static let indexSchemaPrefix = "$index:"

    public enum Item: Equatable, Sendable {
        case collection(String)
        case view(String)
        case gridFSBucket(String)
        case index(collection: String, name: String)
    }

    public static func classify(_ object: DatabaseObject) -> Item {
        if object.schema == gridFSSchema { return .gridFSBucket(object.name) }
        if let schema = object.schema, schema.hasPrefix(indexSchemaPrefix) {
            return .index(collection: String(schema.dropFirst(indexSchemaPrefix.count)), name: object.name)
        }
        return object.kind == .view ? .view(object.name) : .collection(object.name)
    }

    /// The collection a navigator object opens (a bucket opens its `.files` collection, an index its collection).
    public static func collectionName(_ object: DatabaseObject) -> String {
        switch classify(object) {
        case .collection(let name), .view(let name): name
        case .gridFSBucket(let bucket): "\(bucket).files"
        case .index(let collection, _): collection
        }
    }

    /// Plain collections and views (no buckets or indexes), for lists that expect tables.
    public static func isBrowsable(_ object: DatabaseObject) -> Bool {
        switch classify(object) {
        case .collection, .view: true
        default: false
        }
    }

    /// GridFS buckets: every `X.files` collection that has an `X.chunks` beside it.
    public static func gridFSBuckets(in collections: [String]) -> [String] {
        let names = Set(collections)
        return collections.compactMap { name in
            guard name.hasSuffix(".files") else { return nil }
            let bucket = String(name.dropLast(".files".count))
            return names.contains("\(bucket).chunks") ? bucket : nil
        }.sorted()
    }
}
