import Testing
@testable import BunnyGridCore

@Suite struct SQLSplitterTests {
    @Test func splitsOnSemicolons() {
        #expect(SQLSplitter.split("SELECT 1; SELECT 2;") == ["SELECT 1", "SELECT 2"])
    }

    @Test func ignoresSemicolonsInLiteralsAndIdentifiers() {
        let script = #"INSERT INTO t VALUES ('a;b', "c;d", `e;f`); SELECT 'it''s;'"#
        #expect(SQLSplitter.split(script) == [
            #"INSERT INTO t VALUES ('a;b', "c;d", `e;f`)"#,
            "SELECT 'it''s;'",
        ])
    }

    @Test func ignoresSemicolonsInComments() {
        let script = """
            -- first; comment
            SELECT 1; /* block; comment */ SELECT 2
            """
        #expect(SQLSplitter.split(script) == ["-- first; comment\nSELECT 1", "/* block; comment */ SELECT 2"])
    }

    @Test func dropsCommentOnlyStatements() {
        #expect(SQLSplitter.split("SELECT 1; -- trailing") == ["SELECT 1"])
    }

    @Test func keepsDollarQuotedBodiesTogether() {
        let script = """
            CREATE FUNCTION f() RETURNS int AS $body$ BEGIN RETURN 1; END; $body$ LANGUAGE plpgsql;
            SELECT f()
            """
        let statements = SQLSplitter.split(script)
        #expect(statements.count == 2)
        #expect(statements[0].hasSuffix("LANGUAGE plpgsql"))
    }

    @Test func positionalParametersAreNotDollarQuotes() {
        #expect(SQLSplitter.split("SELECT $1; SELECT $2") == ["SELECT $1", "SELECT $2"])
    }
}

@Suite struct SQLDialectTests {
    @Test func quotesIdentifiersPerEngine() {
        #expect(SQLDialect(kind: .postgresql).quoteIdentifier(#"we"ird"#) == #""we""ird""#)
        #expect(SQLDialect(kind: .mysql).quoteIdentifier("we`ird") == "`we``ird`")
    }

    @Test func escapesLiterals() {
        #expect(SQLDialect(kind: .postgresql).quoteLiteral("it's") == "'it''s'")
        #expect(SQLDialect(kind: .mysql).quoteLiteral(#"a\b"#) == #"'a\\b'"#)
    }

    @Test func buildsPageQuery() {
        let sql = SQLDialect(kind: .postgresql).selectPage(
            table: "users", schema: "public", offset: 100, limit: 50,
            orderBy: [OrderBy(column: "id", direction: .descending)], filter: "age > 18"
        )
        #expect(sql == #"SELECT * FROM "public"."users" WHERE age > 18 ORDER BY "id" DESC LIMIT 50 OFFSET 100"#)
    }
}

@Suite struct TriggerSplitTests {
    @Test func keepsTriggerBodiesTogether() {
        let script = """
            CREATE TRIGGER t AFTER UPDATE ON books BEGIN UPDATE books SET n = CASE WHEN n > 1 THEN 0 ELSE n END; SELECT 1; END;
            SELECT 2;
            """
        let parts = SQLSplitter.split(script)
        #expect(parts.count == 2)
        #expect(parts[0].hasSuffix("END"))
        #expect(parts[1] == "SELECT 2")
    }

    @Test func plainStatementsStillSplit() {
        #expect(SQLSplitter.split("select 'begin;'; select 2; -- end;\nselect 3") == ["select 'begin;'", "select 2", "-- end;\nselect 3"])
    }
}
