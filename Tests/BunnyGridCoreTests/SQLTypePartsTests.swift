import BunnyGridCore
import Testing

struct SQLTypePartsTests {
    @Test func splitsSizeAndScale() {
        #expect(SQLTypeParts("numeric(10,2)") == SQLTypeParts(base: "numeric", size: "10", scale: "2"))
        #expect(SQLTypeParts("varchar(255)") == SQLTypeParts(base: "varchar", size: "255"))
        #expect(SQLTypeParts("TEXT") == SQLTypeParts(base: "TEXT"))
        #expect(SQLTypeParts("int(11) unsigned") == SQLTypeParts(base: "int unsigned", size: "11"))
    }

    @Test func keepsNonNumericArguments() {
        #expect(SQLTypeParts("enum('a','b')") == SQLTypeParts(base: "enum('a','b')"))
    }

    @Test func roundTrips() {
        for type in ["numeric(10,2)", "varchar(255)", "TEXT", "int(11) unsigned", "enum('a','b')"] {
            #expect(SQLTypeParts(type).type == type)
        }
        var parts = SQLTypeParts("varchar(255)")
        parts.size = ""
        #expect(parts.type == "varchar")
        parts = SQLTypeParts("numeric")
        parts.size = "5"
        parts.scale = "2"
        #expect(parts.type == "numeric(5,2)")
    }
}
