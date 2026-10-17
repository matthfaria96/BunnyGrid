import Foundation
import Testing
@testable import BunnyGridCore

@Suite struct QueryBuilderTests {
    /// customers c LEFT JOIN orders o, a couple of conditions, grouping, ordering and a page.
    private var sample: BuilderQuery {
        var q = BuilderQuery()
        let c = q.addTable(name: "customers", alias: "c")
        let o = q.addTable(name: "orders", alias: "o")
        q.joins = [BuilderJoin(kind: .left, leftTable: c, leftColumn: "id", rightTable: o, rightColumn: "customer_id")]
        q.columns = [BuilderColumn(tableID: c, column: "name"), BuilderColumn(tableID: o, column: "total", aggregate: .sum, alias: "spent")]
        q.whereClause = BuilderGroup(items: [
            .predicate(BuilderPredicate(left: .column(tableID: c, name: "country"), op: .isIn, values: [.text("BR"), .text("PT")])),
            .group(BuilderGroup(conjunction: .or, items: [
                .predicate(BuilderPredicate(left: .column(tableID: o, name: "status"), op: .isNull, values: [])),
                .predicate(BuilderPredicate(left: .column(tableID: o, name: "total"), op: .between, values: [.number("10"), .number("99.5")])),
            ])),
        ])
        q.groupBy = [.column(tableID: c, name: "name")]
        q.having = BuilderGroup(items: [.predicate(BuilderPredicate(left: .aggregate(.sum, tableID: o, column: "total"), op: .greater, values: [.number("100")]))])
        q.orderBy = [BuilderOrder(.column(tableID: c, name: "name"), descending: true)]
        q.limit = 20
        q.offset = 40
        return q
    }

    @Test func generatesSQLite() {
        #expect(QueryBuilderSQL(kind: .sqlite).sql(sample) == """
            SELECT
              c.name,
              SUM(o.total) AS spent
            FROM
              customers AS c
              LEFT JOIN orders AS o ON c.id = o.customer_id
            WHERE
              c.country IN ('BR', 'PT') AND (o.status IS NULL OR o.total BETWEEN 10 AND 99.5)
            GROUP BY
              c.name
            HAVING
              SUM(o.total) > 100
            ORDER BY
              c.name DESC
            LIMIT 20 OFFSET 40
            """)
    }

    @Test func pagingPerDialect() {
        var q = BuilderQuery()
        q.addTable(name: "Order Items")
        q.limit = 5
        #expect(QueryBuilderSQL(kind: .sqlserver).sql(q) == "SELECT TOP 5\n  *\nFROM\n  [Order Items]")
        #expect(QueryBuilderSQL(kind: .mysql).sql(q) == "SELECT\n  *\nFROM\n  `Order Items`\nLIMIT 5")
        #expect(QueryBuilderSQL(kind: .postgresql).sql(q).contains("\"Order Items\""))
        q.offset = 10
        #expect(QueryBuilderSQL(kind: .sqlserver).sql(q).hasSuffix("ORDER BY\n  (SELECT NULL)\nOFFSET 10 ROWS\nFETCH NEXT 5 ROWS ONLY"))
        #expect(QueryBuilderSQL(kind: .mariadb).sql(q).hasSuffix("LIMIT 5 OFFSET 10"))
        q.limit = nil
        #expect(QueryBuilderSQL(kind: .postgresql).sql(q).hasSuffix("\nOFFSET 10"))
        #expect(QueryBuilderSQL(kind: .sqlite).sql(q).hasSuffix("LIMIT -1 OFFSET 10"))
        #expect(QueryBuilderSQL(kind: .mysql).sql(q).hasSuffix("LIMIT 18446744073709551615 OFFSET 10"))
    }

    @Test func quotingAndLiterals() {
        var q = BuilderQuery()
        let t = q.addTable(name: "Users", schema: "public")
        q.columns = [BuilderColumn(tableID: t, column: "order")]
        q.whereClause = BuilderGroup(items: [.predicate(BuilderPredicate(left: .column(tableID: t, name: "name"), op: .like, values: [.text("O'B%")]))])
        #expect(QueryBuilderSQL(kind: .postgresql).sql(q) == "SELECT\n  \"order\"\nFROM\n  public.\"Users\"\nWHERE\n  name LIKE 'O''B%'")
        #expect(QueryBuilderSQL(kind: .sqlserver).sql(q).hasSuffix("name LIKE N'O''B%'"))
        #expect(QueryBuilderSQL(kind: .mysql).sql(q).contains("`order`"))
    }

    @Test func roundTripsEveryDialect() throws {
        for kind in [DatabaseKind.sqlite, .postgresql, .mysql, .mariadb, .sqlserver] {
            let sql = QueryBuilderSQL(kind: kind).sql(sample)
            let parsed = try QueryBuilderParser.parse(sql)
            #expect(parsed == sample, "\(kind)")
            #expect(QueryBuilderSQL(kind: kind).sql(parsed) == sql)
        }
    }

    @Test func parsesHandWrittenSelects() throws {
        let q = try QueryBuilderParser.parse("""
            select distinct `o`.`id`, c.name as "Customer", count(*) n -- comment
            from orders o join customers c on o.customer_id = c.id
            where o.total != 0 and not (c.name like 'A%' or c.id = :id)
            order by 2, o.id desc limit 10, 5;
            """)
        #expect(q.distinct)
        #expect(q.tables.map(\.reference) == ["o", "c"])
        #expect(q.joins == [BuilderJoin(kind: .inner, leftTable: 1, leftColumn: "customer_id", rightTable: 2, rightColumn: "id")])
        #expect(q.columns == [BuilderColumn(tableID: 1, column: "id"), BuilderColumn(tableID: 2, column: "name", alias: "Customer"),
                              BuilderColumn(tableID: nil, column: "*", aggregate: .count, alias: "n")])
        #expect(q.whereClause.items.count == 2)
        guard case .group(let negated) = q.whereClause.items[1] else { Issue.record("expected a group"); return }
        #expect(negated.negated && negated.conjunction == .or)
        #expect(negated.items.last == .predicate(BuilderPredicate(left: .column(tableID: 2, name: "id"), values: [.parameter(":id")])))
        #expect(q.orderBy == [BuilderOrder(.number("2")), BuilderOrder(.column(tableID: 1, name: "id"), descending: true)])
        #expect(q.limit == 5 && q.offset == 10)

        let top = try QueryBuilderParser.parse("SELECT TOP (3) * FROM [dbo].[t] ORDER BY [x]")
        #expect(top.limit == 3 && top.tables.first?.schema == "dbo" && top.columns.isEmpty)
        let fetch = try QueryBuilderParser.parse("SELECT a FROM t ORDER BY (SELECT NULL) OFFSET 4 ROWS FETCH NEXT 2 ROWS ONLY")
        #expect(fetch.orderBy.isEmpty && fetch.offset == 4 && fetch.limit == 2)
        // A single table resolves unqualified columns to it.
        #expect(fetch.columns == [BuilderColumn(tableID: 1, column: "a")])
        // A right-side ON written backwards keeps the join's kind.
        let right = try QueryBuilderParser.parse("SELECT * FROM a RIGHT JOIN b ON b.x = a.y")
        #expect(right.joins == [BuilderJoin(kind: .right, leftTable: 1, leftColumn: "y", rightTable: 2, rightColumn: "x")])
    }

    @Test func rejectsWhatTheBuilderCannotShow() {
        for sql in ["SELECT a + 1 FROM t", "SELECT * FROM (SELECT 1) x", "SELECT * FROM t UNION SELECT * FROM u", "WITH x AS (SELECT 1) SELECT * FROM x",
                    "SELECT * FROM t WHERE a IN (SELECT b FROM u)", "UPDATE t SET a = 1", "SELECT upper(a) FROM t", "SELECT 1; SELECT 2",
                    "SELECT * FROM a JOIN b USING (id)", "SELECT * FROM t WHERE x.a = 1"] {
            #expect(throws: QueryBuilderParseError.self, "\(sql)") { try QueryBuilderParser.parse(sql) }
        }
        #expect(!QueryBuilderParser.canParse("DELETE FROM t"))
    }

    @Test func foreignKeyJoinsAndTableRemoval() {
        var q = BuilderQuery()
        let c = q.addTable(name: "customers")
        let o = q.addTable(name: "orders")
        let key = TableForeignKey(name: "fk", columns: ["customer_id"], referencedTable: "customers", referencedColumns: ["id"])
        #expect(q.addForeignKeyJoins(for: o, keys: [o: [key]]) == 1)
        #expect(q.joins == [BuilderJoin(leftTable: c, leftColumn: "id", rightTable: o, rightColumn: "customer_id")])
        #expect(q.addForeignKeyJoins(for: o, keys: [o: [key]]) == 0)
        let again = q.addTable(name: "orders")
        #expect(q.table(again)?.alias == "orders2")
        q.setSelected(true, table: o, column: "total")
        q.whereClause.items = [.predicate(BuilderPredicate(left: .column(tableID: o, name: "total"), op: .isNotNull, values: []))]
        q.removeTable(o)
        #expect(q.joins.isEmpty && q.columns.isEmpty && q.whereClause.isEmpty && q.tables.count == 2)
        #expect(BuilderOperand.value("42") == .number("42") && BuilderOperand.value(":p") == .parameter(":p") && BuilderOperand.value("abc") == .text("abc"))
    }
}
