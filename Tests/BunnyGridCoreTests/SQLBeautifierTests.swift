import Testing
@testable import BunnyGridCore

@Suite struct SQLBeautifierTests {
    @Test func putsClausesOnTheirOwnLines() {
        let sql = "select c.name, count(o.id) as n from customers c join orders o on o.customer_id = c.id where c.city = 'Lisboa' and o.total > 10 group by c.name order by n desc limit 5;"
        #expect(SQLBeautifier.format(sql) == """
            SELECT
              c.name,
              COUNT(o.id) AS n
            FROM
              customers c
            JOIN orders o ON o.customer_id = c.id
            WHERE
              c.city = 'Lisboa'
              AND o.total > 10
            GROUP BY
              c.name
            ORDER BY
              n DESC
            LIMIT 5;
            """)
    }

    @Test func leavesStringsAndCommentsAlone() {
        let formatted = SQLBeautifier.format("select 'from where' as x -- keep me\nfrom t")
        #expect(formatted.contains("'from where'"))
        #expect(formatted.contains("-- keep me"))
        #expect(formatted.hasPrefix("SELECT"))
    }

    @Test func indentsSubqueries() {
        let formatted = SQLBeautifier.format("select * from (select id from t where a = 1) s")
        #expect(formatted.contains("(\n    SELECT"))
        #expect(formatted.contains("FROM"))
    }

    @Test func separatesStatements() {
        #expect(SQLBeautifier.format("select 1; select 2;") == "SELECT\n  1;\n\nSELECT\n  2;")
    }
}
