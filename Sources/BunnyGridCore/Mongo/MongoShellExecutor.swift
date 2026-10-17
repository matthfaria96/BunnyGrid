import Foundation

/// What a shell statement produced.
public struct MongoShellOutput: Sendable {
    public enum Content: Sendable {
        case documents([BSONDocument], truncated: Bool)
        case value(BSON)
        case message(String)
        /// An `explain` reply.
        case plan(BSONDocument)
    }

    public var statement: String
    public var content: Content
    /// `use <db>`: the database later statements run in.
    public var switchedDatabase: String?
    public var duration: Duration = .zero

    /// The output as grid rows: documents flattened, a value as one `result` cell, a message as one `message` cell.
    public var queryResult: QueryResult {
        var result: QueryResult
        switch content {
        case .documents(let documents, let truncated):
            let flat = DocumentFlattener.flatten(documents)
            result = QueryResult(statement: statement, columns: flat.columns.isEmpty ? ["result"] : flat.columns, rows: flat.rows, isTruncated: truncated)
        case .value(let value):
            if case .document(let document) = value {
                let flat = DocumentFlattener.flatten([document])
                result = QueryResult(statement: statement, columns: flat.columns, rows: flat.rows)
            } else {
                result = QueryResult(statement: statement, columns: ["result"], rows: [[DocumentFlattener.cell(value)]])
            }
        case .message(let text):
            result = QueryResult(statement: statement, columns: [], rows: [])
            result.affectedRows = Int(text.split(separator: " ").first ?? "")
        case .plan(let explain):
            result = QueryResult(statement: statement, columns: ["explain"], rows: [[.text(BSONFormat.shell(explain))]])
        }
        result.duration = duration
        return result
    }

    /// All documents of the output (one for a value document), for the tree and JSON views.
    public var documents: [BSONDocument] {
        switch content {
        case .documents(let documents, _): documents
        case .value(.document(let document)): [document]
        case .plan(let document): [document]
        default: []
        }
    }
}

/// Runs parsed shell statements against a MongoDB driver: the collection methods mongosh users type most
/// (`find` with `sort` / `limit` / `skip` / `projection` / `count` / `explain`, `findOne`, `aggregate`, `countDocuments`,
/// `estimatedDocumentCount`, `distinct`, `insertOne` / `insertMany`, `updateOne` / `updateMany` / `replaceOne`,
/// `deleteOne` / `deleteMany`, `createIndex` / `dropIndex` / `getIndexes`, `drop`, `stats`, `renameCollection`) and the
/// database ones (`runCommand`, `adminCommand`, `createCollection`, `createView`, `getCollectionNames`, `dropDatabase`, `stats`),
/// plus `show dbs|collections` and `use`.
public struct MongoShellExecutor: Sendable {
    public let driver: MongoDriver
    public var database: String

    public init(driver: MongoDriver, database: String) {
        self.driver = driver
        self.database = database
    }

    /// Runs every statement of a script; `use` switches the database for the ones after it.
    public mutating func runScript(_ text: String, maxDocuments: Int) async throws -> [MongoShellOutput] {
        var outputs: [MongoShellOutput] = []
        for statement in try MongoShellParser.parseScript(text) {
            try Task.checkCancellation()
            let output = try await run(statement, maxDocuments: maxDocuments)
            if let db = output.switchedDatabase { database = db }
            outputs.append(output)
        }
        return outputs
    }

    public func run(_ statement: MongoShellStatement, maxDocuments: Int) async throws -> MongoShellOutput {
        let clock = ContinuousClock()
        let start = clock.now
        var output = try await dispatch(statement, maxDocuments: maxDocuments)
        output.duration = clock.now - start
        return output
    }

    private func dispatch(_ statement: MongoShellStatement, maxDocuments: Int) async throws -> MongoShellOutput {
        let db = statement.database ?? database
        func out(_ content: MongoShellOutput.Content) -> MongoShellOutput {
            MongoShellOutput(statement: statement.text, content: content)
        }
        switch statement.target {
        case .use(let name):
            var output = out(.message("switched to db \(name)"))
            output.switchedDatabase = name
            return output
        case .show(let what):
            switch what {
            case "dbs", "databases":
                let reply = try await driver.runCommand(["listDatabases": .int32(1), "authorizedDatabases": .bool(true)], database: "admin")
                return out(.documents(reply["databases"]?.arrayValue?.compactMap(\.documentValue) ?? [], truncated: false))
            case "collections", "tables":
                return out(.documents(try await driver.listCollections(database: db).map { ["name": .string($0.name), "type": .string($0.kind.rawValue)] }, truncated: false))
            case "users":
                let reply = try await driver.runCommand(["usersInfo": .int32(1)], database: db)
                return out(.documents(reply["users"]?.arrayValue?.compactMap(\.documentValue) ?? [], truncated: false))
            case "roles":
                let reply = try await driver.runCommand(["rolesInfo": .int32(1)], database: db)
                return out(.documents(reply["roles"]?.arrayValue?.compactMap(\.documentValue) ?? [], truncated: false))
            default:
                throw DatabaseError.unsupported("show \(what)")
            }
        case .database:
            return try await runDatabaseMethod(statement, database: db, out: out)
        case .collection(let collection):
            return try await runCollectionMethod(statement, collection: collection, database: db, maxDocuments: maxDocuments, out: out)
        }
    }

    private func document(_ args: [BSON], _ index: Int, _ what: String, required: Bool = false) throws -> BSONDocument {
        guard args.indices.contains(index) else {
            if required { throw DatabaseError.queryFailed("Missing \(what).") }
            return BSONDocument()
        }
        switch args[index] {
        case .document(let d): return d
        case .null, .undefined: return BSONDocument()
        default: throw DatabaseError.queryFailed("The \(what) must be a document.")
        }
    }

    private func runDatabaseMethod(_ statement: MongoShellStatement, database db: String,
                                   out: (MongoShellOutput.Content) -> MongoShellOutput) async throws -> MongoShellOutput {
        guard let call = statement.calls.first else { throw DatabaseError.queryFailed("Nothing to run.") }
        let args = call.arguments
        switch call.name {
        case "runCommand", "adminCommand":
            let target = call.name == "adminCommand" ? "admin" : db
            let command: BSONDocument = if case .string(let name)? = args.first { [name: .int32(1)] } else { try document(args, 0, "command", required: true) }
            return out(.value(.document(try await driver.runCommand(command, database: target))))
        case "createCollection":
            guard case .string(let name)? = args.first else { throw DatabaseError.queryFailed("createCollection needs a name.") }
            var command: BSONDocument = ["create": .string(name)]
            for element in try document(args, 1, "options") { command[element.key] = element.value }
            _ = try await driver.runCommand(command, database: db)
            return out(.message("Collection \(name) created."))
        case "createView":
            guard case .string(let name)? = args.first, args.count >= 3, case .string(let source) = args[1] else {
                throw DatabaseError.queryFailed("createView needs a name, a source collection and a pipeline.")
            }
            _ = try await driver.runCommand(["create": .string(name), "viewOn": .string(source), "pipeline": args[2]], database: db)
            return out(.message("View \(name) created."))
        case "getCollectionNames":
            return out(.value(.array(try await driver.listCollections(database: db).map { .string($0.name) })))
        case "dropDatabase":
            _ = try await driver.runCommand(["dropDatabase": .int32(1)], database: db)
            return out(.message("Database \(db) dropped."))
        case "stats":
            return out(.value(.document(try await driver.runCommand(["dbStats": .int32(1)], database: db))))
        case "getName":
            return out(.value(.string(db)))
        case "version":
            return out(.value(.string(try await driver.serverVersion())))
        case "aggregate":
            let pipeline = (args.first?.arrayValue ?? []).compactMap(\.documentValue)
            let result = try await driver.aggregateCapped(pipeline, database: db, collection: nil, limit: 1000)
            return out(.documents(result.documents, truncated: result.truncated))
        default:
            throw DatabaseError.unsupported("db.\(call.name)()")
        }
    }

    private func runCollectionMethod(_ statement: MongoShellStatement, collection: String, database db: String, maxDocuments: Int,
                                     out: (MongoShellOutput.Content) -> MongoShellOutput) async throws -> MongoShellOutput {
        guard let call = statement.calls.first else { throw DatabaseError.queryFailed("Nothing to run.") }
        let args = call.arguments
        let wantsExplain = statement.chained("explain") != nil
        switch call.name {
        case "find", "findOne":
            var query = DocumentQuery(filter: try document(args, 0, "filter"), projection: try document(args, 1, "projection"))
            if let sort = statement.chained("sort") { query.sort = try document(sort.arguments, 0, "sort") }
            if let projection = statement.chained("projection") { query.projection = try document(projection.arguments, 0, "projection") }
            if let skip = statement.chained("skip")?.arguments.first?.intValue { query.skip = skip }
            var limit = statement.chained("limit")?.arguments.first?.intValue
            if call.name == "findOne" { limit = 1 }
            if let n = limit, n != 0 { query.limit = abs(n) }
            if statement.chained("count") != nil || statement.chained("itcount") != nil {
                return out(.value(.int64(Int64(try await driver.count(filter: query.filter, database: db, collection: collection)))))
            }
            if wantsExplain {
                var command: BSONDocument = ["find": .string(collection), "filter": .document(query.filter)]
                if !query.sort.isEmpty { command["sort"] = .document(query.sort) }
                if !query.projection.isEmpty { command["projection"] = .document(query.projection) }
                if let limit = query.limit { command["limit"] = .int64(Int64(limit)) }
                if query.skip > 0 { command["skip"] = .int64(Int64(query.skip)) }
                return out(.plan(try await driver.explain(command, database: db)))
            }
            let cap = query.limit.map { min($0, maxDocuments) } ?? maxDocuments
            let requested = query.limit
            query.limit = cap
            let result = try await driver.findCapped(query, database: db, collection: collection)
            if call.name == "findOne" { return out(.value(result.documents.first.map(BSON.document) ?? .null)) }
            return out(.documents(result.documents, truncated: result.truncated && (requested == nil || requested! > cap)))
        case "aggregate":
            let pipeline = (args.first?.arrayValue ?? (args.allSatisfy { $0.documentValue != nil } ? args : [])).compactMap(\.documentValue)
            let options = args.count > 1 && args.first?.arrayValue != nil ? try document(args, 1, "options") : BSONDocument()
            if wantsExplain {
                return out(.plan(try await driver.explain(["aggregate": .string(collection), "pipeline": .array(pipeline.map(BSON.document)), "cursor": .document([:])], database: db)))
            }
            let result = try await driver.aggregateCapped(pipeline, database: db, collection: collection, limit: maxDocuments, options: options)
            return out(.documents(result.documents, truncated: result.truncated))
        case "countDocuments", "count":
            return out(.value(.int64(Int64(try await driver.count(filter: try document(args, 0, "filter"), database: db, collection: collection)))))
        case "estimatedDocumentCount":
            let reply = try await driver.runCommand(["count": .string(collection)], database: db)
            return out(.value(.int64(Int64(reply["n"]?.intValue ?? 0))))
        case "distinct":
            guard case .string(let key)? = args.first else { throw DatabaseError.queryFailed("distinct needs a field name.") }
            let reply = try await driver.runCommand(["distinct": .string(collection), "key": .string(key), "query": .document(try document(args, 1, "filter"))], database: db)
            return out(.value(reply["values"] ?? .array([])))
        case "insertOne", "insert" where args.first?.documentValue != nil:
            let ids = try await driver.insert([try document(args, 0, "document", required: true)], database: db, collection: collection)
            return out(.value(.document(["acknowledged": .bool(true), "insertedId": ids.first ?? .null])))
        case "insertMany", "insert":
            let documents = (args.first?.arrayValue ?? []).compactMap(\.documentValue)
            guard !documents.isEmpty else { throw DatabaseError.queryFailed("\(call.name) needs an array of documents.") }
            let ids = try await driver.insert(documents, database: db, collection: collection)
            return out(.value(.document(["acknowledged": .bool(true), "insertedCount": .int32(Int32(ids.count)), "insertedIds": .array(ids)])))
        case "updateOne", "updateMany", "replaceOne":
            let filter = try document(args, 0, "filter")
            guard args.count >= 2 else { throw DatabaseError.queryFailed("\(call.name) needs a filter and an update.") }
            let update = args[1]
            if call.name == "replaceOne", let doc = update.documentValue, doc.keys.contains(where: { $0.hasPrefix("$") }) {
                throw DatabaseError.queryFailed("replaceOne takes a replacement document without update operators.")
            }
            if call.name != "replaceOne", let doc = update.documentValue, !doc.keys.allSatisfy({ $0.hasPrefix("$") }) {
                throw DatabaseError.queryFailed("\(call.name) needs update operators such as { $set: { … } }.")
            }
            let upsert = try document(args, 2, "options")["upsert"]?.boolValue ?? false
            let result = try await driver.update(filter: filter, update: update, many: call.name == "updateMany", upsert: upsert, database: db, collection: collection)
            var reply: BSONDocument = ["acknowledged": .bool(true), "matchedCount": .int32(Int32(result.matched)), "modifiedCount": .int32(Int32(result.modified))]
            if let id = result.upsertedID { reply["upsertedId"] = id }
            return out(.value(.document(reply)))
        case "deleteOne", "deleteMany", "remove":
            let many = call.name != "deleteOne" && !(call.name == "remove" && args.count > 1 && args[1].boolValue == true)
            let n = try await driver.delete(filter: try document(args, 0, "filter"), many: many, database: db, collection: collection)
            return out(.value(.document(["acknowledged": .bool(true), "deletedCount": .int32(Int32(n))])))
        case "createIndex", "ensureIndex":
            let name = try await driver.createIndex(keys: try document(args, 0, "index keys", required: true), options: try document(args, 1, "options"),
                                                    database: db, collection: collection)
            return out(.value(.string(name)))
        case "dropIndex":
            let name: String
            switch args.first {
            case .string(let s)?: name = s
            case .document(let keys)?:
                let indexes = try await driver.listIndexDocuments(database: db, collection: collection)
                guard let match = indexes.first(where: { $0["key"]?.documentValue == keys })?["name"]?.stringValue else {
                    throw DatabaseError.queryFailed("No index with keys \(BSONFormat.shell(.document(keys), layout: .compact)).")
                }
                name = match
            default: throw DatabaseError.queryFailed("dropIndex needs an index name or its keys.")
            }
            try await driver.dropIndex(name, database: db, collection: collection)
            return out(.message("Index \(name) dropped."))
        case "dropIndexes":
            _ = try await driver.runCommand(["dropIndexes": .string(collection), "index": args.first ?? .string("*")], database: db)
            return out(.message("Indexes dropped."))
        case "getIndexes", "getIndices":
            return out(.documents(try await driver.listIndexDocuments(database: db, collection: collection), truncated: false))
        case "drop":
            _ = try await driver.runCommand(["drop": .string(collection)], database: db)
            return out(.value(.bool(true)))
        case "stats", "storageStats":
            return out(.value(.document(try await driver.collectionStats(database: db, collection: collection))))
        case "renameCollection":
            guard case .string(let newName)? = args.first else { throw DatabaseError.queryFailed("renameCollection needs the new name.") }
            _ = try await driver.runCommand(["renameCollection": .string("\(db).\(collection)"), "to": .string("\(db).\(newName)"),
                                             "dropTarget": .bool(args.count > 1 && args[1].boolValue == true)], database: "admin")
            return out(.message("Renamed to \(newName)."))
        default:
            throw DatabaseError.unsupported("db.\(collection).\(call.name)()")
        }
    }
}
