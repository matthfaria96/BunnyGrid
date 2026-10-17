import Foundation
import Testing
@testable import BunnyGridCore

@Suite("BSON codec")
struct BSONCodecTests {
    @Test func roundTripsEveryType() throws {
        let id = ObjectId("65a1b2c3d4e5f60718293a4b")!
        let document: BSONDocument = [
            "_id": .objectId(id),
            "d": .double(1.5),
            "s": .string("héllo"),
            "doc": .document(["a": .int32(1)]),
            "arr": .array([.int32(1), .string("x"), .null]),
            "bin": .binary(BSONBinary(subtype: 0, data: Data([1, 2, 3]))),
            "uuid": .binary(BSONBinary(uuid: UUID(uuidString: "123E4567-E89B-12D3-A456-426614174000")!)),
            "undef": .undefined,
            "t": .bool(true),
            "date": .date(1_700_000_000_123),
            "null": .null,
            "re": .regex(BSONRegex(pattern: "^a.*", options: "xi")),
            "js": .javascript("function(){}"),
            "i32": .int32(-7),
            "ts": .timestamp(BSONTimestamp(timestamp: 1_700_000_000, increment: 3)),
            "i64": .int64(9_000_000_000),
            "dec": .decimal128(BSONDecimal128("12.345")!),
            "min": .minKey,
            "max": .maxKey,
        ]
        let bytes = BSONEncoder.encode(document)
        #expect(try BSONDecoder.decode(bytes) == document)
        // Regex options are kept sorted, as BSON requires.
        #expect(document["re"] == .regex(BSONRegex(pattern: "^a.*", options: "ix")))
    }

    @Test func encodesKnownBytes() {
        // {"hello": "world"} from the BSON spec.
        let bytes = BSONEncoder.encode(["hello": .string("world")])
        #expect(bytes == [0x16, 0, 0, 0, 0x02, 0x68, 0x65, 0x6C, 0x6C, 0x6F, 0, 0x06, 0, 0, 0, 0x77, 0x6F, 0x72, 0x6C, 0x64, 0, 0])
    }

    @Test func rejectsTruncatedData() {
        let bytes = Array(BSONEncoder.encode(["a": .int32(1)]).dropLast())
        #expect(throws: BSONError.self) { try BSONDecoder.decode(bytes) }
    }

    @Test func objectIdHexAndDate() {
        let id = ObjectId("65a1b2c3d4e5f60718293a4b")!
        #expect(id.hexString == "65a1b2c3d4e5f60718293a4b")
        #expect(id.date == Date(timeIntervalSince1970: 0x65A1B2C3))
        #expect(ObjectId("xyz") == nil)
        #expect(ObjectId() != ObjectId())
    }

    @Test(arguments: [("1.5", "1.5"), ("-0.001", "-0.001"), ("100", "100"), ("1E+3", "1E+3"), ("0", "0"),
                      ("123456789012345678901234567890.1234", "123456789012345678901234567890.1234"), ("Infinity", "Infinity"), ("NaN", "NaN"),
                      ("1.000000000E-10", "1.000000000E-10")])
    func decimal128Text(input: String, expected: String) throws {
        let value = try #require(BSONDecimal128(input))
        #expect(value.description == expected)
    }

    @Test func decimal128KnownBits() {
        // 1 is coefficient 1, exponent 0 → high 0x3040000000000000, low 1.
        #expect(BSONDecimal128("1") == BSONDecimal128(high: 0x3040_0000_0000_0000, low: 1))
        #expect(BSONDecimal128("0.1") == BSONDecimal128(high: 0x303E_0000_0000_0000, low: 1))
    }

    @Test func dottedPathLookup() {
        let document: BSONDocument = ["a": .document(["b": .array([.int32(5), .document(["c": .string("x")])])])]
        #expect(document.value(atPath: "a.b.1.c") == .string("x"))
        #expect(document.value(atPath: "a.missing") == nil)
    }
}

@Suite("Mongo shell parser")
struct MongoShellParserTests {
    @Test func json5Values() throws {
        let value = try MongoShellParser.parseValue("""
        { name: 'Ann', "age": 30, score: 9.5, tags: ['a', "b",], nested: { ok: true, none: null }, big: 9000000000, // comment
          neg: -2, /* block */ hex: 0x1F }
        """)
        let expected: BSONDocument = [
            "name": .string("Ann"), "age": .int32(30), "score": .double(9.5), "tags": .array([.string("a"), .string("b")]),
            "nested": .document(["ok": .bool(true), "none": .null]), "big": .int64(9_000_000_000), "neg": .int32(-2), "hex": .int32(31),
        ]
        #expect(value == .document(expected))
    }

    @Test func shellConstructors() throws {
        let value = try MongoShellParser.parseDocument("""
        { _id: ObjectId("65a1b2c3d4e5f60718293a4b"), at: ISODate("2024-05-01T12:00:00Z"), d2: new Date("2024-05-01"),
          n: NumberLong(5), s: NumberLong("9007199254740993"), i: NumberInt(7), m: NumberDecimal("1.10"),
          ts: Timestamp(10, 2), b: BinData(0, "AQID"), u: UUID("123e4567-e89b-12d3-a456-426614174000"),
          lo: MinKey, hi: MaxKey(), re: /^ab\\/c/i, re2: RegExp("x+", "m") }
        """)
        #expect(value["_id"] == .objectId(ObjectId("65a1b2c3d4e5f60718293a4b")!))
        #expect(value["at"] == .date(1_714_564_800_000))
        #expect(value["d2"] == .date(1_714_521_600_000))
        #expect(value["n"] == .int64(5))
        #expect(value["s"] == .int64(9_007_199_254_740_993))
        #expect(value["i"] == .int32(7))
        #expect(value["m"] == .decimal128(BSONDecimal128("1.10")!))
        #expect(value["ts"] == .timestamp(BSONTimestamp(timestamp: 10, increment: 2)))
        #expect(value["b"] == .binary(BSONBinary(subtype: 0, data: Data([1, 2, 3]))))
        #expect(value["u"] == .binary(BSONBinary(uuid: UUID(uuidString: "123e4567-e89b-12d3-a456-426614174000")!)))
        #expect(value["lo"] == .minKey)
        #expect(value["hi"] == .maxKey)
        #expect(value["re"] == .regex(BSONRegex(pattern: "^ab/c", options: "i")))
        #expect(value["re2"] == .regex(BSONRegex(pattern: "x+", options: "m")))
    }

    @Test func extendedJSONWrappers() throws {
        let value = try MongoShellParser.parseDocument("""
        {"_id": {"$oid": "65a1b2c3d4e5f60718293a4b"}, "d": {"$date": "2024-05-01T12:00:00.000Z"}, "l": {"$numberLong": "12"},
         "dec": {"$numberDecimal": "2.5"}, "q": {"$gte": 3}}
        """)
        #expect(value["_id"] == .objectId(ObjectId("65a1b2c3d4e5f60718293a4b")!))
        #expect(value["d"] == .date(1_714_564_800_000))
        #expect(value["l"] == .int64(12))
        #expect(value["dec"] == .decimal128(BSONDecimal128("2.5")!))
        #expect(value["q"] == .document(["$gte": .int32(3)]))
    }

    @Test func shellFormatRoundTrips() throws {
        let document: BSONDocument = ["_id": .objectId(ObjectId()), "when": .date(1_700_000_000_123), "n": .int64(3), "d": .double(2),
                                      "dec": .decimal128(BSONDecimal128("0.30")!), "s": .string("quote \" and \\ backslash\n"),
                                      "list": .array([.int32(1), .document(["x": .regex(BSONRegex(pattern: "a/b", options: "i"))])])]
        #expect(try MongoShellParser.parseDocument(BSONFormat.shell(document)) == document)
        #expect(try MongoShellParser.parseDocument(BSONFormat.shell(document, layout: .compact)) == document)
        // Relaxed Extended JSON writes small Int64 values as plain numbers, which read back as Int32 (as with mongoexport).
        var relaxed = document
        relaxed["n"] = .int32(3)
        #expect(try MongoShellParser.parseDocument(BSONFormat.extendedJSON(document)) == relaxed)
    }

    @Test func findChain() throws {
        let statements = try MongoShellParser.parseScript("db.users.find({ age: { $gt: 30 } }, { name: 1 })\n  .sort({ name: -1 })\n  .limit(10)")
        #expect(statements.count == 1)
        let s = statements[0]
        #expect(s.target == .collection("users"))
        #expect(s.method == "find")
        #expect(s.calls[0].arguments == [.document(["age": .document(["$gt": .int32(30)])]), .document(["name": .int32(1)])])
        #expect(s.chained("sort")?.arguments == [.document(["name": .int32(-1)])])
        #expect(s.chained("limit")?.arguments == [.int32(10)])
    }

    @Test func scriptsWithSeveralStatements() throws {
        let statements = try MongoShellParser.parseScript("""
        use shop
        show collections;
        db.fs.files.countDocuments({})
        db.getCollection("weird name").insertOne({ a: 1 }); db["other"].deleteMany({})
        db.getSiblingDB("admin").runCommand({ ping: 1 })
        db.orders.aggregate([{ $match: { status: "A" } }, { $group: { _id: "$cust", total: { $sum: "$amount" } } }])
        """)
        #expect(statements.map(\.target) == [.use("shop"), .show("collections"), .collection("fs.files"), .collection("weird name"),
                                             .collection("other"), .database, .collection("orders")])
        #expect(statements[5].database == "admin")
        #expect(statements[5].method == "runCommand")
        #expect(statements[6].calls[0].arguments.first?.arrayValue?.count == 2)
        #expect(statements[3].text == "db.getCollection(\"weird name\").insertOne({ a: 1 })")
    }

    @Test func reportsErrors() {
        #expect(throws: MongoShellError.self) { try MongoShellParser.parseScript("db.users.find({ a: })") }
        #expect(throws: MongoShellError.self) { try MongoShellParser.parseScript("SELECT 1") }
        #expect(throws: MongoShellError.self) { try MongoShellParser.parseValue("ObjectId(\"nothex\")") }
        #expect(throws: MongoShellError.self) { try MongoShellParser.parseScript("db.users.find() extra") }
    }

    @Test func connectionStrings() throws {
        let parsed = try ConnectionURI.parse("mongodb://ann:p%40ss@h1:27018,h2/shop?authSource=admin&replicaSet=rs0&tls=true")
        #expect(parsed.config.kind == .mongodb)
        #expect(parsed.config.host == "h1")
        #expect(parsed.config.port == 27018)
        #expect(parsed.password == "p@ss")
        #expect(parsed.config.database == "shop")
        #expect(parsed.config.tls == .verifyFull)
        #expect(parsed.config.mongo == MongoOptions(authSource: "admin", replicaSet: "rs0", extraHosts: ["h2:27017"]))
        let srv = try ConnectionURI.parse("mongodb+srv://bob@cluster0.example.net/")
        #expect(srv.config.mongo?.srv == true)
        #expect(srv.config.tls == .verifyFull)
        #expect(ConnectionURI.string(for: srv.config).hasPrefix("mongodb+srv://bob@cluster0.example.net/"))
        let round = try ConnectionURI.parse(ConnectionURI.string(for: parsed.config, password: "p@ss"))
        #expect(round.config.mongo == parsed.config.mongo)
        #expect(round.password == "p@ss")
    }

    @Test func scramSHA256RFC7677Vector() throws {
        // RFC 7677 §3 test vector.
        var scram = MongoSCRAM(mechanism: .sha256, username: "user", password: "pencil", clientNonce: "rOprNGfwEbeRWgbNEkqO")
        #expect(scram.clientFirst() == "n,,n=user,r=rOprNGfwEbeRWgbNEkqO")
        let final = try scram.clientFinal(serverFirst: "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096")
        #expect(final == "c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=")
        try scram.verify(serverFinal: "v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=")
    }

    @Test func scramSHA1MongoVector() throws {
        // From the MongoDB auth spec: user "user", password "pencil".
        var scram = MongoSCRAM(mechanism: .sha1, username: "user", password: "pencil", clientNonce: "fyko+d2lbbFgONRv9qkxdawL")
        _ = scram.clientFirst()
        let final = try scram.clientFinal(serverFirst: "r=fyko+d2lbbFgONRv9qkxdawLHo+Vgk7qvUOKUwuWLIWg4l/9SraGMHEE,s=rQ9ZY3MntBeuP3E1TDVC4w==,i=10000")
        #expect(final == "c=biws,r=fyko+d2lbbFgONRv9qkxdawLHo+Vgk7qvUOKUwuWLIWg4l/9SraGMHEE,p=MC2T8BvbmWRckDw8oWl5IVghwCY=")
        try scram.verify(serverFinal: "v=UMWeI25JD1yNYZRMpZ4VHvhZ9e0=")
    }
}

@Suite("Document flattening")
struct DocumentFlatteningTests {
    @Test func unionOfTopLevelKeys() {
        let id1 = ObjectId(), id2 = ObjectId()
        let flat = DocumentFlattener.flatten([
            ["name": .string("Ann"), "_id": .objectId(id1), "age": .int32(30)],
            ["_id": .objectId(id2), "address": .document(["city": .string("Rio")]), "tags": .array([.string("a")]), "age": .double(31.5)],
            ["_id": .objectId(ObjectId()), "age": .int32(5)],
        ])
        #expect(flat.columns == ["_id", "name", "age", "address", "tags"])
        #expect(flat.rows[0] == [.text(id1.hexString), .text("Ann"), .integer(30), .null, .null])
        #expect(flat.rows[1][3] == .text("{ \"city\": \"Rio\" }"))
        #expect(flat.rows[1][4] == .text("[\"a\"]"))
        #expect(flat.columnTypes["age"] == "Int32")
        #expect(flat.columnTypes["_id"] == "ObjectId")
    }

    @Test func editsKeepTheFieldType() {
        #expect(DocumentFlattener.value(from: .text("42"), original: .int32(1)) == .int32(42))
        #expect(DocumentFlattener.value(from: .text("42"), original: .int64(1)) == .int64(42))
        #expect(DocumentFlattener.value(from: .text("42"), original: .string("x")) == .string("42"))
        #expect(DocumentFlattener.value(from: .text("{ a: 1 }"), original: .document([:])) == .document(["a": .int32(1)]))
        #expect(DocumentFlattener.value(from: .text("2024-05-01T12:00:00Z"), original: .date(0)) == .date(1_714_564_800_000))
        #expect(DocumentFlattener.value(from: .text("hello"), original: nil) == .string("hello"))
        #expect(DocumentFlattener.value(from: .null, original: .int32(1)) == .null)
    }

    @Test func navigatorCatalog() {
        #expect(DocumentCatalog.gridFSBuckets(in: ["fs.files", "fs.chunks", "photos.files", "users"]) == ["fs"])
        let bucket = DatabaseObject(schema: DocumentCatalog.gridFSSchema, name: "fs", kind: .table)
        #expect(DocumentCatalog.collectionName(bucket) == "fs.files")
        let index = DatabaseObject(schema: DocumentCatalog.indexSchemaPrefix + "users", name: "email_1", kind: .table)
        #expect(DocumentCatalog.classify(index) == .index(collection: "users", name: "email_1"))
        #expect(!DocumentCatalog.isBrowsable(index))
    }

    @Test func explainPlanTree() throws {
        let explain = try MongoShellParser.parseDocument("""
        { queryPlanner: { namespace: "shop.users", winningPlan: { stage: "FETCH", inputStage: { stage: "IXSCAN", keyPattern: { age: 1 }, indexName: "age_1" } } },
          executionStats: { nReturned: 3, executionTimeMillis: 0, totalKeysExamined: 3, totalDocsExamined: 3 } }
        """)
        let plan = MongoExplain.plan(explain)
        #expect(plan.count == 1)
        #expect(plan[0].title == "FETCH")
        #expect(plan[0].children.first?.title == "IXSCAN")
        #expect(plan[0].children.first?.details.contains(.init("indexName", "age_1")) == true)
        #expect(plan[0].details.contains(.init("nReturned", "3")))
    }

    @Test func transferFormats() throws {
        let documents: [BSONDocument] = [["_id": .objectId(ObjectId("65a1b2c3d4e5f60718293a4b")!), "n": .int32(1), "s": .string("a,b")],
                                         ["_id": .objectId(ObjectId("65a1b2c3d4e5f60718293a4c")!), "n": .int32(2), "nested": .document(["x": .bool(true)])]]
        #expect(try DocumentTransfer.read(DocumentTransfer.export(documents, as: .json)) == documents)
        #expect(try DocumentTransfer.read(DocumentTransfer.export(documents, as: .jsonLines), format: .jsonLines) == documents)
        let csv = DocumentTransfer.export(documents, as: .csv)
        #expect(csv.hasPrefix("_id,n,s,nested"))
        let back = try DocumentTransfer.read(csv, format: .csv)
        #expect(back[0]["s"] == .string("a,b"))
        #expect(back[1]["nested"] == .document(["x": .bool(true)]))
        #expect(back[1]["_id"] == documents[1]["_id"])
    }
}
