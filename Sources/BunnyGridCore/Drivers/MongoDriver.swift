import Foundation
import NIOSSL

/// MongoDB driver on BunnyGrid's own OP_MSG client (`Mongo/`): SCRAM-SHA-256/SHA-1, TLS from the SSL tab,
/// the SSH tunnel and socket files through `ConnectionEndpoint`, `mongodb+srv` seed lists from DNS, and
/// replica sets (connects to the primary). As a `DatabaseDriver`, collections are tables whose columns are
/// the union of top-level keys; "schema" arguments are the database name, as on MySQL.
/// `executeStatement` runs shell commands (`db.coll.find(…)`).
public actor MongoDriver: DocumentDatabaseDriver {
    public nonisolated let config: ConnectionConfig
    private let secrets: ConnectionSecrets
    private var connection: MongoConnection?
    private var endpoint: ConnectionEndpoint?
    /// Comment attached to the running command, so `cancelCurrentQuery` can find and kill it.
    private var runningTag: String?

    public init(config: ConnectionConfig, secrets: ConnectionSecrets) {
        self.config = config
        self.secrets = secrets
    }

    /// The database commands run in when none is named (the connection's database, or `test` like the shell).
    public nonisolated var defaultDatabase: String { config.database.isEmpty ? "test" : config.database }

    private var mongo: MongoOptions { config.mongo ?? MongoOptions() }

    // MARK: - Connecting

    public func connect() async throws {
        guard connection == nil else { return }
        do {
            try await openConnection()
        } catch let error as DatabaseError {
            throw error
        } catch let error as MongoServerError {
            throw DatabaseError.connectionFailed(error.localizedDescription)
        } catch {
            throw DatabaseError.connectionFailed(ConnectionErrorText.describe(error))
        }
    }

    private func openConnection() async throws {
        var options = mongo
        var useTLS = config.tls.isEnforced || (options.srv && config.tls != .disable)
        var seeds: [MongoConnectionString.Host]
        if options.srv {
            guard config.activeSSH == nil else { throw DatabaseError.unsupported("An SSH tunnel with an SRV (mongodb+srv) connection") }
            let resolved = try await MongoConnectionString.resolveSRV(config.host)
            seeds = resolved.hosts
            if options.authSource.isEmpty, let source = resolved.options["authsource"] { options.authSource = source }
            if options.replicaSet.isEmpty, let set = resolved.options["replicaset"] { options.replicaSet = set }
            useTLS = config.tls != .disable
        } else {
            seeds = [MongoConnectionString.Host(host: config.host, port: config.port)]
            seeds += options.extraHosts.compactMap { try? MongoConnectionString.parseHost($0) }
        }
        var tls: TLSConfiguration?
        if useTLS {
            var effective = config
            if effective.tls == .disable || effective.tls == .prefer { effective.tls = .verifyFull }
            tls = try ConnectionTLS.configuration(for: effective, keyPassphrase: secrets.sslKeyPassphrase)
        }
        let authSource = options.authSource.isEmpty ? (config.database.isEmpty ? "admin" : config.database) : options.authSource
        var helloExtras = BSONDocument()
        if options.authMechanism.uppercased() == "MONGODB-X509" {
            guard tls != nil || config.tls.isEnforced else { throw DatabaseError.connectionFailed("X.509 authentication needs SSL with a client certificate.") }
        } else if !config.username.isEmpty, options.authMechanism.isEmpty {
            helloExtras["saslSupportedMechs"] = .string("\(authSource).\(config.username)")
        }

        // One seed (or a tunnel / socket): go through the endpoint. Several: try each, prefer the primary.
        if seeds.count == 1 && !options.srv {
            let endpoint = try await ConnectionEndpoint.open(for: config, sshSecret: secrets.sshSecret)
            do {
                let connection = try await MongoConnection.open(address: endpoint.address, tls: endpoint.usesTLS ? tls : nil,
                                                                serverName: endpoint.tlsServerName, helloExtras: helloExtras)
                try await authenticate(connection, source: authSource, mechanism: options.authMechanism)
                self.connection = connection
                self.endpoint = endpoint
            } catch {
                await endpoint.close()
                throw error
            }
            return
        }
        var lastError: (any Error)?
        var fallback: MongoConnection?
        var tried = Set<MongoConnectionString.Host>()
        var queue = seeds
        while let seed = queue.first {
            queue.removeFirst()
            guard tried.insert(seed).inserted else { continue }
            do {
                let candidate = try await MongoConnection.open(address: .tcp(host: seed.host, port: seed.port), tls: tls,
                                                               serverName: ConnectionEndpoint.serverName(for: seed.host), helloExtras: helloExtras)
                if candidate.isWritablePrimary || candidate.isMongos {
                    try await authenticate(candidate, source: authSource, mechanism: options.authMechanism)
                    await fallback?.close()
                    connection = candidate
                    return
                }
                // A secondary names the primary: try it next.
                if let primary = candidate.hello["primary"]?.stringValue, let host = try? MongoConnectionString.parseHost(primary) {
                    queue.insert(host, at: 0)
                }
                if fallback == nil { fallback = candidate } else { await candidate.close() }
            } catch {
                lastError = error
            }
        }
        if let fallback {
            try await authenticate(fallback, source: authSource, mechanism: options.authMechanism)
            connection = fallback
            return
        }
        throw lastError ?? DatabaseError.connectionFailed("No MongoDB server could be reached.")
    }

    private func authenticate(_ connection: MongoConnection, source: String, mechanism: String) async throws {
        if mechanism.uppercased() == "MONGODB-X509" {
            // The client certificate from the SSL tab is the identity; the user name (its subject) is optional.
            var command: BSONDocument = ["authenticate": .int32(1), "mechanism": .string("MONGODB-X509")]
            if !config.username.isEmpty { command["user"] = .string(config.username) }
            do {
                _ = try await connection.run(command, database: "$external")
            } catch let error as MongoServerError {
                await connection.close()
                throw DatabaseError.connectionFailed("X.509 authentication failed: \(error.message)")
            }
            return
        }
        guard !config.username.isEmpty else { return }
        let offered = connection.hello["saslSupportedMechs"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let chosen: MongoSCRAM.Mechanism = switch mechanism.uppercased() {
        case "SCRAM-SHA-1": .sha1
        case "SCRAM-SHA-256": .sha256
        default: offered.isEmpty || offered.contains("SCRAM-SHA-256") ? .sha256 : .sha1
        }
        var scram = MongoSCRAM(mechanism: chosen, username: config.username, password: secrets.password ?? "")
        let first = Array(scram.clientFirst().utf8)
        do {
            var reply = try await connection.run([
                "saslStart": .int32(1), "mechanism": .string(chosen.rawValue),
                "payload": .binary(BSONBinary(data: Data(first))), "autoAuthorize": .int32(1),
                "options": .document(["skipEmptyExchange": .bool(true)]),
            ], database: source)
            guard case .binary(let serverFirst)? = reply["payload"], let conversation = reply["conversationId"] else {
                throw MongoSCRAM.SCRAMError.badServerMessage
            }
            let final = try scram.clientFinal(serverFirst: String(decoding: serverFirst.data, as: UTF8.self))
            reply = try await connection.run([
                "saslContinue": .int32(1), "conversationId": conversation, "payload": .binary(BSONBinary(data: Data(final.utf8))),
            ], database: source)
            guard case .binary(let serverFinal)? = reply["payload"] else { throw MongoSCRAM.SCRAMError.badServerMessage }
            try scram.verify(serverFinal: String(decoding: serverFinal.data, as: UTF8.self))
            if reply["done"]?.boolValue != true {
                _ = try await connection.run([
                    "saslContinue": .int32(1), "conversationId": conversation, "payload": .binary(BSONBinary(data: Data())),
                ], database: source)
            }
        } catch let error as MongoServerError {
            await connection.close()
            throw DatabaseError.connectionFailed("Authentication failed for \(config.username) on \(source): \(error.message)")
        } catch {
            await connection.close()
            throw error
        }
    }

    public func disconnect() async {
        await connection?.close()
        connection = nil
        await endpoint?.close()
        endpoint = nil
    }

    /// A replica set or a seed list (not a single server, tunnel or socket).
    private var hasSeveralHosts: Bool { mongo.srv || !mongo.extraHosts.isEmpty || !mongo.replicaSet.isEmpty }

    /// Drops the connection and connects again through the seed list, which prefers the current primary.
    private func rediscoverPrimary() async {
        await connection?.close()
        connection = nil
        await endpoint?.close()
        endpoint = nil
        try? await openConnection()
    }

    private func live() throws -> MongoConnection {
        guard let connection, connection.isActive else { throw DatabaseError.notConnected }
        return connection
    }

    // MARK: - Commands

    private static let taggedCommands: Set<String> = ["find", "aggregate", "count", "distinct", "insert", "update", "delete",
                                                      "findAndModify", "getMore", "explain", "createIndexes"]
    private static let readCommands: Set<String> = ["find", "aggregate", "count", "distinct", "getMore", "listCollections",
                                                    "listIndexes", "explain", "collStats", "dbStats"]

    public func runCommand(_ command: BSONDocument, database: String) async throws -> BSONDocument {
        let connection = try live()
        var command = command
        let name = command.elements.first?.key ?? ""
        if Self.taggedCommands.contains(name), command["comment"] == nil, connection.maxWireVersion >= 9 {
            let tag = "bunnygrid-\(UUID().uuidString)"
            command["comment"] = .string(tag)
            runningTag = tag
        }
        if Self.readCommands.contains(name), !connection.isWritablePrimary, !connection.isMongos {
            command["$readPreference"] = .document(["mode": .string("primaryPreferred")])
        }
        defer { runningTag = nil }
        do {
            do {
                return try await connection.run(command, database: database)
            } catch let error as MongoServerError where error.isNotPrimary && name != "getMore" && hasSeveralHosts {
                // An election moved the primary: find the new one and run the command there once.
                await rediscoverPrimary()
                return try await live().run(command, database: database)
            }
        } catch let error as MongoServerError {
            throw DatabaseError.queryFailed(error.isInterruption ? "The operation was cancelled (\(error.message))." : error.localizedDescription)
        }
    }

    /// Reads a cursor reply's batches, following `getMore` until `limit` documents (or the end), then closes the cursor.
    private func drain(_ reply: BSONDocument, database: String, limit: Int?) async throws -> (documents: [BSONDocument], truncated: Bool) {
        guard case .document(let cursor)? = reply["cursor"] else { return ([], false) }
        var documents = cursor["firstBatch"]?.arrayValue?.compactMap(\.documentValue) ?? []
        var cursorID = cursor["id"] ?? .int64(0)
        let namespace = cursor["ns"]?.stringValue ?? ""
        let collection = namespace.split(separator: ".", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
        while cursorID.intValue != 0, limit.map({ documents.count < $0 }) ?? true {
            try Task.checkCancellation()
            var getMore: BSONDocument = ["getMore": cursorID, "collection": .string(collection)]
            if let limit { getMore["batchSize"] = .int32(Int32(clamping: max(limit - documents.count, 1))) }
            let next = try await runCommand(getMore, database: database)
            guard case .document(let nextCursor)? = next["cursor"] else { break }
            documents += nextCursor["nextBatch"]?.arrayValue?.compactMap(\.documentValue) ?? []
            cursorID = nextCursor["id"] ?? .int64(0)
        }
        var truncated = false
        if let limit, documents.count > limit {
            documents.removeSubrange(limit...)
            truncated = true
        }
        if cursorID.intValue != 0 {
            truncated = true
            _ = try? await runCommand(["killCursors": .string(collection), "cursors": .array([cursorID])], database: database)
        }
        return (documents, truncated)
    }

    public func listCollections(database: String) async throws -> [CollectionInfo] {
        let reply = try await runCommand(["listCollections": .int32(1), "authorizedCollections": .bool(true)], database: database)
        let (documents, _) = try await drain(reply, database: database, limit: nil)
        return documents.compactMap { document in
            guard let name = document["name"]?.stringValue else { return nil }
            let kind = CollectionInfo.Kind(rawValue: document["type"]?.stringValue ?? "collection") ?? .collection
            return CollectionInfo(name: name, kind: kind, options: document["options"]?.documentValue ?? BSONDocument())
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func find(_ query: DocumentQuery, database: String, collection: String) async throws -> [BSONDocument] {
        try await findCapped(query, database: database, collection: collection).documents
    }

    public func findCapped(_ query: DocumentQuery, database: String, collection: String) async throws -> (documents: [BSONDocument], truncated: Bool) {
        var command: BSONDocument = ["find": .string(collection), "filter": .document(query.filter)]
        if !query.sort.isEmpty { command["sort"] = .document(query.sort) }
        if !query.projection.isEmpty { command["projection"] = .document(query.projection) }
        if query.skip > 0 { command["skip"] = .int64(Int64(query.skip)) }
        if let limit = query.limit {
            command["limit"] = .int64(Int64(limit))
            command["batchSize"] = .int32(Int32(clamping: max(limit, 1)))
        }
        let reply = try await runCommand(command, database: database)
        return try await drain(reply, database: database, limit: query.limit)
    }

    public func count(filter: BSONDocument, database: String, collection: String) async throws -> Int {
        // countDocuments: an aggregate, exact also on sharded clusters.
        let documents = try await aggregate([["$match": .document(filter)], ["$group": .document(["_id": .int32(1), "n": .document(["$sum": .int32(1)])])]],
                                            database: database, collection: collection, limit: 1)
        return documents.first?["n"]?.intValue ?? 0
    }

    public func aggregate(_ pipeline: [BSONDocument], database: String, collection: String, limit: Int?) async throws -> [BSONDocument] {
        try await aggregateCapped(pipeline, database: database, collection: collection, limit: limit).documents
    }

    public func aggregateCapped(_ pipeline: [BSONDocument], database: String, collection: String?, limit: Int?,
                                options: BSONDocument = BSONDocument()) async throws -> (documents: [BSONDocument], truncated: Bool) {
        var command: BSONDocument = ["aggregate": collection.map(BSON.string) ?? .int32(1), "pipeline": .array(pipeline.map(BSON.document))]
        var cursor = BSONDocument()
        if let limit { cursor["batchSize"] = .int32(Int32(clamping: max(limit, 1))) }
        command["cursor"] = .document(cursor)
        for element in options where element.key != "cursor" { command[element.key] = element.value }
        let reply = try await runCommand(command, database: database)
        return try await drain(reply, database: database, limit: limit)
    }

    @discardableResult
    public func insert(_ documents: [BSONDocument], database: String, collection: String) async throws -> [BSON] {
        if config.readOnly { throw DatabaseError.readOnly }
        var ids: [BSON] = []
        let prepared = documents.map { document -> BSON in
            var document = document
            if document["_id"] == nil {
                document.elements.insert(BSONElement("_id", .objectId(ObjectId())), at: 0)
            }
            ids.append(document["_id"]!)
            return .document(document)
        }
        // Batches stay well under the 48 MB message limit.
        var start = 0
        while start < prepared.count {
            let end = min(start + 1000, prepared.count)
            _ = try await runCommand(["insert": .string(collection), "documents": .array(Array(prepared[start..<end])), "ordered": .bool(true)],
                                     database: database)
            start = end
        }
        return ids
    }

    public func update(filter: BSONDocument, update: BSON, many: Bool, upsert: Bool, database: String, collection: String) async throws -> DocumentUpdateResult {
        if config.readOnly { throw DatabaseError.readOnly }
        let statement: BSONDocument = ["q": .document(filter), "u": update, "multi": .bool(many), "upsert": .bool(upsert)]
        let reply = try await runCommand(["update": .string(collection), "updates": .array([.document(statement)])], database: database)
        let upserted = reply["upserted"]?.arrayValue?.first?.documentValue?["_id"]
        return DocumentUpdateResult(matched: reply["n"]?.intValue ?? 0, modified: reply["nModified"]?.intValue ?? 0, upsertedID: upserted)
    }

    public func delete(filter: BSONDocument, many: Bool, database: String, collection: String) async throws -> Int {
        if config.readOnly { throw DatabaseError.readOnly }
        let statement: BSONDocument = ["q": .document(filter), "limit": .int32(many ? 0 : 1)]
        let reply = try await runCommand(["delete": .string(collection), "deletes": .array([.document(statement)])], database: database)
        return reply["n"]?.intValue ?? 0
    }

    public func explain(_ command: BSONDocument, database: String) async throws -> BSONDocument {
        try await runCommand(["explain": .document(command), "verbosity": .string("executionStats")], database: database)
    }

    /// Kills the running command (found by its comment) from a second connection with `killOp`.
    public func cancelCurrentQuery() async throws {
        guard connection != nil, let tag = runningTag else { return }
        let canceller = MongoDriver(config: config, secrets: secrets)
        try await canceller.connect()
        defer { Task { await canceller.disconnect() } }
        let ops = try await canceller.aggregateCapped([["$currentOp": .document(["allUsers": .bool(true)])],
                                                        ["$match": .document(["command.comment": .string(tag)])]],
                                                       database: "admin", collection: nil, limit: 10).documents
        for op in ops {
            if let id = op["opid"] { _ = try? await canceller.runCommand(["killOp": .int32(1), "op": id], database: "admin") }
        }
    }

    // MARK: - DatabaseDriver

    public func serverVersion() async throws -> String {
        let info = try await runCommand(["buildInfo": .int32(1)], database: "admin")
        return "MongoDB \(info["version"]?.stringValue ?? "")"
    }

    public func listDatabases() async throws -> [String] {
        do {
            let reply = try await runCommand(["listDatabases": .int32(1), "nameOnly": .bool(true), "authorizedDatabases": .bool(true)], database: "admin")
            let names = reply["databases"]?.arrayValue?.compactMap { $0.documentValue?["name"]?.stringValue } ?? []
            var result = names.sorted()
            if !config.database.isEmpty, !result.contains(config.database) { result.append(config.database) }
            return result
        } catch {
            // Users without listDatabases still see their own database.
            if !config.database.isEmpty { return [config.database] }
            throw error
        }
    }

    public func listSchemas() async throws -> [String] { [] }

    /// Collections and views, GridFS buckets (`DocumentCatalog.gridFSSchema`) and indexes (`DocumentCatalog.indexSchemaPrefix`).
    public func listObjects(schema: String?) async throws -> [DatabaseObject] {
        let database = schema ?? defaultDatabase
        // system.views, system.profile…: hidden, as Navicat does unless "Show system items" is on.
        let collections = try await listCollections(database: database).filter { !$0.name.hasPrefix("system.") }
        var objects = collections.map { DatabaseObject(schema: nil, name: $0.name, kind: $0.kind == .view ? .view : .table) }
        let plain = collections.filter { $0.kind != .view }.map(\.name)
        objects += DocumentCatalog.gridFSBuckets(in: plain).map { DatabaseObject(schema: DocumentCatalog.gridFSSchema, name: $0, kind: .table) }
        for name in plain.prefix(200) where !name.hasPrefix("system.") {
            let indexes = (try? await listIndexDocuments(database: database, collection: name)) ?? []
            objects += indexes.compactMap { $0["name"]?.stringValue }
                .map { DatabaseObject(schema: DocumentCatalog.indexSchemaPrefix + name, name: $0, kind: .table) }
        }
        return objects
    }

    /// Top-level fields of up to 200 sampled documents, `_id` as the key.
    public func listColumns(table: String, schema: String?) async throws -> [TableColumn] {
        let documents = try await find(DocumentQuery(limit: 200), database: schema ?? defaultDatabase, collection: table)
        let flattened = DocumentFlattener.flatten(documents)
        return flattened.columns.enumerated().map { index, name in
            TableColumn(name: name, dataType: flattened.columnTypes[name] ?? "Mixed", nullable: name != "_id", isPrimaryKey: name == "_id", ordinal: index + 1)
        }
    }

    public func listIndexes(table: String, schema: String?) async throws -> [TableIndex] {
        try await listIndexDocuments(database: schema ?? defaultDatabase, collection: table).map { document in
            let name = document["name"]?.stringValue ?? ""
            return TableIndex(name: name, columns: document["key"]?.documentValue?.keys ?? [],
                              unique: document["unique"]?.boolValue ?? (name == "_id_"), primary: name == "_id_")
        }
    }

    public func tableStatistics(schema: String?) async throws -> [String: TableStatistics] {
        let database = schema ?? defaultDatabase
        var result: [String: TableStatistics] = [:]
        for info in try await listCollections(database: database) where info.kind != .view {
            guard let stats = try? await collectionStats(database: database, collection: info.name) else { continue }
            var entry = TableStatistics(rows: stats["count"]?.intValue, sizeBytes: stats["size"]?.intValue)
            entry.engine = info.kind == .timeseries ? "time series" : nil
            entry.hasIndexes = (stats["nindexes"]?.intValue ?? 0) > 0
            entry.indexCount = stats["nindexes"]?.intValue
            entry.storageBytes = stats["storageSize"]?.intValue
            entry.averageObjectBytes = stats["avgObjSize"]?.intValue
            result[info.name] = entry
        }
        return result
    }

    /// The shell commands that recreate a collection: `createCollection` with its options, and its indexes.
    public func objectDDL(name: String, kind: DatabaseObjectKind, schema: String?) async throws -> String {
        let database = schema ?? defaultDatabase
        let info = try await listCollections(database: database).first { $0.name == name }
        let target = "db.getCollection(\(BSONFormat.quote(name)))"
        var lines: [String] = []
        if let info, info.kind == .view {
            var options = info.options
            let source = options["viewOn"]?.stringValue ?? ""
            let pipeline = options["pipeline"] ?? .array([])
            options["viewOn"] = nil
            options["pipeline"] = nil
            lines.append("db.createView(\(BSONFormat.quote(name)), \(BSONFormat.quote(source)), \(BSONFormat.shell(pipeline)))")
            return lines.joined(separator: "\n")
        }
        let options = info?.options ?? BSONDocument()
        lines.append(options.isEmpty ? "db.createCollection(\(BSONFormat.quote(name)))" : "db.createCollection(\(BSONFormat.quote(name)), \(BSONFormat.shell(options)))")
        for index in try await listIndexDocuments(database: database, collection: name) where index["name"]?.stringValue != "_id_" {
            var opts = index
            let key = opts["key"] ?? .document([:])
            opts["key"] = nil
            opts["v"] = nil
            lines.append("\(target).createIndex(\(BSONFormat.shell(key, layout: .compact)), \(BSONFormat.shell(opts, layout: .compact)))")
        }
        return lines.joined(separator: ";\n") + ";"
    }

    /// Runs one shell statement (`db.coll.find(…)`) and returns documents flattened into rows.
    public func executeStatement(_ sql: String) async throws -> QueryResult {
        try await executeStatement(sql, maxRows: nil)
    }

    public func executeStatement(_ sql: String, parameters: [SQLParameter]) async throws -> QueryResult {
        guard parameters.isEmpty else { throw DatabaseError.unsupported("Bound parameters") }
        return try await executeStatement(sql)
    }

    public func executeStatement(_ sql: String, maxRows: Int?) async throws -> QueryResult {
        guard let statement = try MongoShellParser.parseScript(sql).first else {
            return QueryResult(statement: sql, columns: [], rows: [])
        }
        let output = try await MongoShellExecutor(driver: self, database: defaultDatabase).run(statement, maxDocuments: maxRows ?? 1000)
        return output.queryResult
    }
}
