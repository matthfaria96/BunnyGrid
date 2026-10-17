import Foundation
import NIOCore
import Testing
@testable import BunnyGridCore

/// TDS encoding and decoding against byte fixtures written from [MS-TDS] (and checked against SQL Server 2022 replies).
struct TDSProtocolTests {
    private func buffer(_ bytes: [UInt8]) -> ByteBuffer { ByteBuffer(bytes: bytes) }
    private func utf16(_ s: String) -> [UInt8] { TDSLogin7.utf16(s) }

    @Test func splitsMessagesIntoPacketsWithEndOfMessageOnTheLast() {
        let payload = ByteBuffer(bytes: [UInt8](repeating: 0xAB, count: 10))
        var out = TDSPacket.encode(type: 0x01, payload: payload, packetSize: 14)
        // 6 payload bytes per packet: 6 + 4.
        #expect(out.readBytes(length: 8) == [0x01, 0x00, 0x00, 0x0E, 0x00, 0x00, 0x01, 0x00])
        #expect(out.readBytes(length: 6) == [UInt8](repeating: 0xAB, count: 6))
        #expect(out.readBytes(length: 8) == [0x01, 0x01, 0x00, 0x0C, 0x00, 0x00, 0x02, 0x00])
        #expect(out.readableBytes == 4)
        #expect(Array(TDSPacket.attention.readableBytesView) == [0x06, 0x01, 0x00, 0x08, 0x00, 0x00, 0x01, 0x00])
    }

    @Test func preloginRoundTrip() throws {
        let request = TDSPrelogin.encode(encryption: .on)
        let bytes = Array(request.readableBytesView)
        // Five options of 5 bytes plus the terminator, then VERSION data at offset 26.
        #expect(bytes[0] == 0x00 && bytes[1] == 0x00 && bytes[2] == 26 && bytes[4] == 6)
        #expect(bytes[25] == 0xFF)
        #expect(bytes[26 + 6] == 0x01) // ENCRYPTION = ON
        // A server reply: VERSION 16.0.4135, ENCRYPTION = ON.
        let reply: [UInt8] = [0x00, 0x00, 0x0B, 0x00, 0x06, 0x01, 0x00, 0x11, 0x00, 0x01, 0xFF,
                              0x10, 0x00, 0x10, 0x27, 0x00, 0x00, 0x01]
        let decoded = try TDSPrelogin.decode(buffer(reply))
        #expect(decoded.encryption == .on)
        #expect(decoded.version == "16.0.4135")
    }

    @Test func login7LayoutAndPasswordScrambling() {
        // [MS-TDS] 2.2.6.4: "a" (0x61 0x00) becomes 0xB3 0xA5.
        #expect(TDSLogin7.obfuscate("a") == [0xB3, 0xA5])
        let login = TDSLogin7(hostName: "mac", userName: "sa", password: "x", appName: "BG", serverName: "db", database: "master")
        var bytes = login.encode()
        let length = bytes.getInteger(at: 0, endianness: .little, as: UInt32.self)
        #expect(length == UInt32(bytes.readableBytes))
        #expect(bytes.getInteger(at: 4, endianness: .little, as: UInt32.self) == 0x7400_0004)
        // HostName starts right after the 94-byte fixed part.
        #expect(bytes.getInteger(at: 36, endianness: .little, as: UInt16.self) == 94)
        #expect(bytes.getInteger(at: 38, endianness: .little, as: UInt16.self) == 3)
        bytes.moveReaderIndex(to: 94)
        #expect(bytes.readBytes(length: 6) == utf16("mac"))
    }

    @Test func rpcCallsSpExecuteSQLWithTypedParameters() {
        var rpc = TDSRequest.executeSQL("SELECT @p1", parameters: [.bigint(7)], collation: TDSCollation.latin1General, transaction: 0)
        #expect(rpc.readInteger(endianness: .little, as: UInt32.self) == 22)
        rpc.moveReaderIndex(forwardBy: 18)
        #expect(rpc.readBytes(length: 6) == [0xFF, 0xFF, 0x0A, 0x00, 0x00, 0x00])
        let rest = Array(rpc.readableBytesView)
        // The last parameter: name "@p1", status 0, INTN(8) and the value.
        #expect(Array(rest.suffix(19)) == [0x03] + utf16("@p1") + [0x00, 0x26, 0x08, 0x08, 0x07, 0, 0, 0, 0, 0, 0, 0])
        #expect(TDSRequest.Value.varbinary(Data()).declaration == "varbinary(max)")
    }

    /// COLMETADATA, two ROWs (one NBCROW with a NULL) and DONE, as SQL Server sends
    /// `SELECT id, name FROM t` for an int and an nvarchar(10) column.
    @Test func decodesColumnsRowsAndDone() throws {
        var bytes: [UInt8] = [0x81, 0x02, 0x00]
        bytes += [0, 0, 0, 0, 0x09, 0x00, 0x38, 0x02] + utf16("id")
        bytes += [0, 0, 0, 0, 0x09, 0x00, 0xE7, 0x14, 0x00] + TDSCollation.latin1General + [0x04] + utf16("name")
        bytes += [0xD1, 0x2A, 0, 0, 0, 0x04, 0x00] + utf16("ab")
        bytes += [0xD2, 0x02, 0x07, 0, 0, 0]
        bytes += [0xFD, 0x10, 0x00, 0xC1, 0x00, 0x02, 0, 0, 0, 0, 0, 0, 0]
        var b = buffer(bytes)
        guard case .columnMetadata(let columns) = try TDSTokenParser.next(&b, columns: []) else { Issue.record("no metadata"); return }
        #expect(columns.map(\.name) == ["id", "name"])
        #expect(columns.map(\.type.typeName) == ["int", "nvarchar(10)"])
        #expect(try TDSTokenParser.next(&b, columns: columns) == .row([.integer(42), .text("ab")]))
        #expect(try TDSTokenParser.next(&b, columns: columns) == .row([.integer(7), .null]))
        guard case .done(let done) = try TDSTokenParser.next(&b, columns: columns) else { Issue.record("no done"); return }
        #expect(done.hasCount && done.rowCount == 2 && !done.hasMore)
        #expect(b.readableBytes == 0)
    }

    @Test func incompleteTokensAskForMoreBytes() {
        var b = buffer([0xFD, 0x10, 0x00])
        #expect(throws: TDSError.incomplete) { try TDSTokenParser.next(&b, columns: []) }
    }

    @Test func decodesErrorsAndEnvChanges() throws {
        let text = utf16("Invalid object name 'x'.")
        var body: [UInt8] = [0xD0, 0x00, 0x00, 0x00, 0x01, 0x10] // 208, state 1, class 16
        body += [UInt8(text.count / 2), 0x00] + text + [0x00, 0x00, 0x01, 0x00, 0x00, 0x00]
        var b = buffer([0xAA, UInt8(body.count), 0x00] + body)
        guard case .error(let message) = try TDSTokenParser.next(&b, columns: []) else { Issue.record("no error"); return }
        #expect(message.number == 208 && message.severity == 16 && message.text == "Invalid object name 'x'.")

        let db = utf16("shop")
        let env: [UInt8] = [0x01, 0x04] + db + [0x00]
        var e = buffer([0xE3, UInt8(env.count), 0x00] + env)
        #expect(try TDSTokenParser.next(&e, columns: []) == .envChange(.database("shop")))
        let tran: [UInt8] = [0x08, 0x08, 1, 2, 3, 4, 5, 6, 7, 8, 0x00]
        var t = buffer([0xE3, UInt8(tran.count), 0x00] + tran)
        #expect(try TDSTokenParser.next(&t, columns: []) == .envChange(.beginTransaction(0x0807_0605_0403_0201)))
    }

    // MARK: Values

    private func value(_ type: [UInt8], _ data: [UInt8]) throws -> CellValue {
        var t = buffer(type)
        let info = try TDSTypeInfo.read(&t)
        var d = buffer(data)
        return try TDSValue.read(&d, info)
    }

    @Test func decodesNumbers() throws {
        #expect(try value([0x26, 0x01], [0x01, 0xFF]) == .integer(255)) // tinyint
        #expect(try value([0x26, 0x02], [0x02, 0xFE, 0xFF]) == .integer(-2))
        #expect(try value([0x7F], [0x00, 0, 0, 0, 0, 0, 0, 0x80]) == .integer(Int64.min))
        #expect(try value([0x68, 0x01], [0x01, 0x01]) == .bool(true))
        #expect(try value([0x6D, 0x04], [0x04] + withUnsafeBytes(of: Float(3.14).bitPattern.littleEndian, Array.init)) == .double(3.14))
        // decimal(10,2) -123.45: sign 0, magnitude 12345.
        #expect(try value([0x6A, 0x05, 0x0A, 0x02], [0x05, 0x00, 0x39, 0x30, 0x00, 0x00]) == .text("-123.45"))
        #expect(try value([0x6A, 0x05, 0x05, 0x03], [0x05, 0x01, 0x05, 0x00, 0x00, 0x00]) == .text("0.005"))
        // money 12.34 = 123400 / 10000 (high then low half).
        #expect(try value([0x6E, 0x08], [0x08, 0, 0, 0, 0, 0x08, 0xE2, 0x01, 0x00]) == .text("12.3400"))
        #expect(try value([0x26, 0x04], [0x00]) == .null)
    }

    @Test func decodesDatesAndTimes() throws {
        // date 2026-10-17: 739905 days since 0001-01-01.
        #expect(try value([0x28], [0x03, 0x41, 0x4A, 0x0B]) == .text("2026-10-17"))
        // datetime 2000-01-01 12:00:00.500: 36524 days since 1900, 12h * 300 + 150 ticks.
        let ticks = UInt32(12 * 3600 * 300 + 150)
        #expect(try value([0x6F, 0x08], [0x08] + withUnsafeBytes(of: Int32(36524).littleEndian, Array.init)
                          + withUnsafeBytes(of: ticks.littleEndian, Array.init)) == .text("2000-01-01 12:00:00.500"))
        // smalldatetime 1900-01-02 00:01.
        #expect(try value([0x6F, 0x04], [0x04, 0x01, 0x00, 0x01, 0x00]) == .text("1900-01-02 00:01:00"))
        // time(3) 09:30:00.123 = 34200123 ms.
        let ms = withUnsafeBytes(of: UInt32(34_200_123).littleEndian, Array.init)
        #expect(try value([0x29, 0x03], [0x04] + ms) == .text("09:30:00.123"))
        // datetime2(0) 0001-01-01 00:00:01.
        #expect(try value([0x2A, 0x00], [0x06, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00]) == .text("0001-01-01 00:00:01"))
        // datetimeoffset(0) 2026-10-17 03:00 UTC at -03:00 → 2026-10-17 00:00:00 -03:00.
        let seconds = withUnsafeBytes(of: UInt32(3 * 3600).littleEndian, Array.init)
        #expect(try value([0x2B, 0x00], [0x08] + seconds.prefix(3) + [0x41, 0x4A, 0x0B] + withUnsafeBytes(of: Int16(-180).littleEndian, Array.init))
                == .text("2026-10-17 00:00:00 -03:00"))
    }

    @Test func decodesStringsGuidsAndBinaries() throws {
        #expect(try value([0xA7, 0x0A, 0x00] + TDSCollation.latin1General, [0x03, 0x00, 0x63, 0x61, 0xE9]) == .text("caé"))
        #expect(try value([0xA7, 0x0A, 0x00] + TDSCollation.latin1General, [0xFF, 0xFF]) == .null)
        // nvarchar(max) as PLP in two chunks.
        let plp: [UInt8] = [0x04, 0, 0, 0, 0, 0, 0, 0, 0x02, 0, 0, 0, 0x6F, 0x00, 0x02, 0, 0, 0, 0x6B, 0x00, 0, 0, 0, 0]
        #expect(try value([0xE7, 0xFF, 0xFF] + TDSCollation.latin1General, plp) == .text("ok"))
        #expect(try value([0xE7, 0xFF, 0xFF] + TDSCollation.latin1General, [UInt8](repeating: 0xFF, count: 8)) == .null)
        let guid: [UInt8] = [0x33, 0x22, 0x11, 0x00, 0x55, 0x44, 0x77, 0x66, 0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]
        #expect(try value([0x24, 0x10], [0x10] + guid) == .text("00112233-4455-6677-8899-AABBCCDDEEFF"))
        #expect(try value([0xA5, 0x04, 0x00], [0x02, 0x00, 0xCA, 0xFE]) == .blob(Data([0xCA, 0xFE])))
        // sql_variant holding an int.
        #expect(try value([0x62, 0x10, 0x1F, 0x00, 0x00], [0x06, 0, 0, 0, 0x38, 0x00, 0x05, 0, 0, 0]) == .integer(5))
    }

    @Test func utf8CollationsDecodeAsUTF8() {
        let utf8Collation: [UInt8] = [0x09, 0x04, 0xD0, 0x04, 0x00]
        #expect(TDSCollation.decode(Array("ação".utf8), collation: utf8Collation) == "ação")
        #expect(TDSCollation.encoding(for: [0x11, 0x04, 0xD0, 0x00, 0x00]) == TDSCollation.windowsEncoding(932))
    }
}

struct SQLServerDialectTests {
    let d = SQLDialect(kind: .sqlserver)

    @Test func quotingPagingAndLiterals() {
        #expect(d.quoteIdentifier("a]b") == "[a]]b]")
        #expect(d.quoteLiteral("it's") == "N'it''s'")
        #expect(d.literal(CellValue.bool(true)) == "1")
        #expect(d.literal(CellValue.blob(Data([0xAB]))) == "0xab")
        #expect(d.selectPage(table: "t", schema: "dbo", offset: 20, limit: 10)
                == "SELECT * FROM [dbo].[t] ORDER BY (SELECT NULL) OFFSET 20 ROWS FETCH NEXT 10 ROWS ONLY")
        #expect(d.beginTransaction == "BEGIN TRANSACTION")
        #expect(d.explain("SELECT 1;") == "SET SHOWPLAN_XML ON;\nSELECT 1")
        #expect(d.placeholder(2) == "@p2")
    }

    @Test func boundStatementsInlineNulls() {
        let change = RowChange.update(key: [ColumnValue("id", .integer(1))],
                                      values: [ColumnValue("photo", .null), ColumnValue("name", .text("x"))])
        let bound = d.boundStatement(for: change, table: "t", schema: "dbo")
        #expect(bound.sql == "UPDATE [dbo].[t] SET [photo] = NULL, [name] = @p1 WHERE [id] = @p2")
        #expect(bound.parameters.count == 2)
    }

    @Test func designerStatements() throws {
        let original = [TableColumn(name: "id", dataType: "int", nullable: false, isPrimaryKey: true, ordinal: 1),
                        TableColumn(name: "n", dataType: "nvarchar(10)", nullable: true, defaultValue: "(N'a')", ordinal: 2)]
        var renamed = ColumnDesign(original[1])
        renamed.name = "label"
        renamed.type = "nvarchar(20)"
        renamed.defaultValue = ""
        let statements = try d.alterTable(name: "t", schema: "dbo", original: original,
                                          design: [ColumnDesign(original[0]), renamed, ColumnDesign(name: "qty", type: "int")])
        #expect(statements[0] == "EXEC sp_rename N'[dbo].[t].[n]', N'label', 'COLUMN'")
        #expect(statements[1] == "ALTER TABLE [dbo].[t] ALTER COLUMN [label] nvarchar(20) NULL")
        #expect(statements[2].contains("DROP CONSTRAINT") && statements[2].contains("sys.default_constraints"))
        #expect(statements[3] == "ALTER TABLE [dbo].[t] ADD [qty] int")
        #expect(d.renameObject(DatabaseObject(schema: "dbo", name: "t", kind: .table), to: "u") == "EXEC sp_rename N'[dbo].[t]', N'u'")
        let key = TableForeignKey(name: "fk", columns: ["a"], referencedTable: "p", referencedColumns: ["id"], onDelete: "RESTRICT", onUpdate: "CASCADE")
        #expect(try d.foreignKeyClause(key, schema: "dbo") == "CONSTRAINT [fk] FOREIGN KEY ([a]) REFERENCES [dbo].[p] ([id]) ON UPDATE CASCADE")
    }

    @Test func typesClassifyAndTranslate() {
        #expect(ColumnTypeCategory.classify("bit", kind: .sqlserver) == .boolean)
        #expect(ColumnTypeCategory.classify("datetime2(7)", kind: .sqlserver) == .dateTime)
        #expect(ColumnTypeCategory.classify("timestamp", kind: .sqlserver) == .binary)
        #expect(ColumnTypeCategory.classify("uniqueidentifier", kind: .sqlserver) == .uuid)
        #expect(ERModel.translateType("timestamptz", from: .postgresql, to: .sqlserver, isKey: false) == "datetimeoffset")
        #expect(ERModel.translateType("text", from: .postgresql, to: .sqlserver, isKey: true) == "nvarchar(450)")
        #expect(ERModel.translateType("bit", from: .sqlserver, to: .postgresql, isKey: false) == "boolean")
        #expect(ERModel.translateType("nvarchar(max)", from: .sqlserver, to: .mysql, isKey: false) == "text")
        #expect(SQLServerDriver.typeDeclaration("nvarchar", maxLength: 100, precision: 0, scale: 0) == "nvarchar(50)")
        #expect(SQLServerDriver.typeDeclaration("varbinary", maxLength: -1, precision: 0, scale: 0) == "varbinary(max)")
    }

    @Test func splitterUnderstandsGoAndBrackets() {
        let script = "SELECT [a;b] FROM t\nGO\nCREATE PROCEDURE p AS\nBEGIN\n  BEGIN TRAN;\n  SELECT 1;\n  COMMIT;\nEND\ngo 2\nSELECT 2"
        #expect(SQLSplitter.split(script) == [
            "SELECT [a;b] FROM t",
            "CREATE PROCEDURE p AS\nBEGIN\n  BEGIN TRAN;\n  SELECT 1;\n  COMMIT;\nEND",
            "SELECT 2",
        ])
        #expect(SQLSplitter.split("SELECT 1 AS gone;\nGOTO x") == ["SELECT 1 AS gone", "GOTO x"])
    }

    @Test func parsesShowplanXML() throws {
        let xml = """
            <?xml version="1.0" encoding="utf-16"?><ShowPlanXML xmlns="http://schemas.microsoft.com/sqlserver/2004/07/showplan"><BatchSequence><Batch><Statements>
            <StmtSimple StatementText="SELECT * FROM t WHERE id = 1" StatementSubTreeCost="0.0032831" StatementEstRows="1"><QueryPlan>
            <RelOp NodeId="0" PhysicalOp="Clustered Index Seek" LogicalOp="Clustered Index Seek" EstimateRows="1" EstimatedTotalSubtreeCost="0.0032831">
            <IndexScan><Object Database="[db]" Schema="[dbo]" Table="[t]" Index="[PK_t]" /></IndexScan></RelOp></QueryPlan></StmtSimple>
            </Statements></Batch></BatchSequence></ShowPlanXML>
            """
        let result = QueryResult(statement: "", columns: ["plan"], rows: [[.text(xml)]])
        let roots = try #require(QueryPlan.parse(result, kind: .sqlserver))
        #expect(roots.count == 1 && roots[0].title == "SELECT * FROM t WHERE id = 1")
        #expect(roots[0].children.first?.title == "Clustered Index Seek on [dbo].[t] using [PK_t]")
        #expect(roots[0].children.first?.details.contains(.init("rows", "1")) == true)
    }

    @Test func uriAndKind() throws {
        let parsed = try ConnectionURI.parse("sqlserver://sa:pw@db.example.com:1444/shop?encrypt=true")
        #expect(parsed.config.kind == .sqlserver && parsed.config.port == 1444 && parsed.config.tls == .require)
        #expect(DatabaseKind.sqlserver.defaultPort == 1433 && DatabaseKind.sqlserver.defaultSchema == "dbo")
        #expect(DriverFactory.make(config: ConnectionConfig(kind: .sqlserver), password: nil) is SQLServerDriver)
    }
}
