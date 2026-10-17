import Foundation
import Testing
@testable import BunnyGridCore

/// How MySQL / MariaDB column metadata from information_schema becomes designer input.
@Suite struct MySQLColumnMetadataTests {
    @Test func mysqlDefaultsBecomeSQLExpressions() {
        func mysql(_ raw: String?, _ type: String, extra: String = "") -> String? {
            MySQLDriver.defaultExpression(raw, extra: extra, dataType: type, kind: .mysql)
        }
        #expect(mysql(nil, "varchar") == nil)
        #expect(mysql("it's", "varchar") == "'it''s'")
        #expect(mysql("a\\b", "varchar") == "'a\\\\b'")
        #expect(mysql("", "varchar") == "''")
        #expect(mysql("NULL", "varchar") == "'NULL'", "MySQL reports a missing default as SQL NULL, so the text NULL is a literal")
        #expect(mysql("3", "int") == "3")
        #expect(mysql("0.00", "decimal") == "0.00")
        #expect(mysql("2024-01-01", "date") == "'2024-01-01'")
        #expect(mysql("b'101'", "bit") == "b'101'")
        #expect(mysql("CURRENT_TIMESTAMP", "datetime", extra: "DEFAULT_GENERATED") == "CURRENT_TIMESTAMP")
        #expect(mysql("rand()", "double", extra: "DEFAULT_GENERATED") == "(rand())")
    }

    @Test func mariadbDefaultsAreAlreadySQL() {
        func maria(_ raw: String?) -> String? { MySQLDriver.defaultExpression(raw, extra: "", dataType: "varchar", kind: .mariadb) }
        #expect(maria("NULL") == nil)
        #expect(maria("'it''s'") == "'it''s'")
        #expect(maria("current_timestamp()") == "current_timestamp()")
        #expect(maria(nil) == nil)
    }

    @Test func modifyColumnKeepsExtraAttributes() {
        #expect(MySQLDriver.preservedAttributes(extra: "auto_increment", comment: "") == "AUTO_INCREMENT")
        #expect(MySQLDriver.preservedAttributes(extra: "DEFAULT_GENERATED on update CURRENT_TIMESTAMP(3)", comment: "it's")
                == "ON UPDATE CURRENT_TIMESTAMP(3) COMMENT 'it''s'")
        #expect(MySQLDriver.preservedAttributes(extra: "on update current_timestamp()", comment: "") == "ON UPDATE current_timestamp()")
        #expect(MySQLDriver.preservedAttributes(extra: "VIRTUAL GENERATED", comment: "") == nil)
        #expect(MySQLDriver.preservedAttributes(extra: "", comment: "") == nil)

        let column = TableColumn(name: "id", dataType: "int", nullable: false, ordinal: 1, extra: "AUTO_INCREMENT")
        #expect(SQLDialect(kind: .mysql).columnDefinition(ColumnDesign(column)) == "`id` int NOT NULL AUTO_INCREMENT")
        #expect(SQLDialect(kind: .postgresql).columnDefinition(ColumnDesign(column)) == #""id" int NOT NULL"#)
    }
}
