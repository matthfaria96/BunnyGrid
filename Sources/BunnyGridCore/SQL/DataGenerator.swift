import Foundation

/// Deterministic random numbers (SplitMix64) so previews and tests are reproducible.
public struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// How the Data Generation wizard fills one column, like Navicat's generators.
public enum ValueGenerator: String, CaseIterable, Codable, Sendable, Identifiable {
    case skip = "Skip (use default)"
    case null = "NULL"
    case integer = "Integer"
    case decimal = "Decimal"
    case boolean = "Boolean"
    case firstName = "First Name"
    case lastName = "Last Name"
    case fullName = "Full Name"
    case email = "Email"
    case phone = "Phone"
    case city = "City"
    case country = "Country"
    case street = "Street Address"
    case company = "Company"
    case word = "Word"
    case sentence = "Sentence"
    case uuid = "UUID"
    case date = "Date"
    case dateTime = "Date & Time"

    public var id: String { rawValue }

    private static let firstNames = ["Ana", "Bruno", "Carla", "Diego", "Elisa", "Felipe", "Gabriela", "Hugo", "Isabela", "João",
                                     "Karina", "Lucas", "Mariana", "Nicolas", "Olivia", "Pedro", "Renata", "Samuel", "Tatiana", "Vitor"]
    private static let lastNames = ["Silva", "Santos", "Oliveira", "Souza", "Lima", "Pereira", "Costa", "Ferreira", "Almeida", "Ribeiro",
                                    "Carvalho", "Gomes", "Martins", "Rocha", "Barbosa", "Araújo", "Melo", "Cardoso", "Teixeira", "Moreira"]
    private static let cities = ["São Paulo", "Rio de Janeiro", "Lisboa", "Porto", "Belo Horizonte", "Curitiba", "Recife", "Madrid",
                                 "Buenos Aires", "Montevideo", "London", "Berlin", "Paris", "Toronto", "New York"]
    private static let countries = ["Brazil", "Portugal", "Argentina", "Uruguay", "Spain", "United Kingdom", "Germany", "France",
                                    "Canada", "United States", "Mexico", "Chile"]
    private static let streets = ["Rua das Flores", "Avenida Paulista", "Rua Augusta", "Avenida Atlântica", "Rua da Prata",
                                  "Main Street", "Oak Avenue", "Rua XV de Novembro", "Avenida Brasil"]
    private static let companies = ["Acme", "Globex", "Initech", "Umbrella", "Stark", "Wayne", "Hooli", "Vandelay", "Soylent", "Tyrell"]
    private static let words = ["lorem", "ipsum", "dolor", "sit", "amet", "consectetur", "adipiscing", "elit", "sed", "do",
                                "eiusmod", "tempor", "incididunt", "labore", "dolore", "magna", "aliqua"]
    private static let domains = ["example.com", "mail.test", "demo.org", "sample.net"]

    /// A value for one row. `type` (e.g. `numeric(5,2)`, `int2`, `varchar(40)`) keeps values within the column's limits.
    public func value(row: Int, type: String? = nil, using rng: inout SeededGenerator) -> CellValue {
        let generated = rawValue(row: row, type: type?.lowercased() ?? "", using: &rng)
        // Text longer than varchar(n)/char(n) would be rejected; trim it.
        if case .text(let text) = generated, let limit = Self.lengthLimit(type), text.count > limit {
            return .text(String(text.prefix(limit)))
        }
        return generated
    }

    private func rawValue(row: Int, type: String, using rng: inout SeededGenerator) -> CellValue {
        func pick(_ list: [String]) -> String { list[Int.random(in: 0..<list.count, using: &rng)] }
        switch self {
        case .skip, .null:
            return .null
        case .integer:
            let upper: Int64 = type.contains("int2") || type.contains("smallint") ? 32_767
                : type.contains("tinyint") ? 127
                : 10_000
            return .integer(Int64.random(in: 1...upper, using: &rng))
        case .decimal:
            let (precision, scale) = Self.precisionScale(type) ?? (8, 2)
            let wholeDigits = max(precision - scale, 0)
            let maxWhole = min(wholeDigits == 0 ? 0 : Int(pow(10, Double(wholeDigits))) - 1, 1_000)
            let whole = Int.random(in: 0...maxWhole, using: &rng)
            guard scale > 0 else { return .text(String(whole)) }
            let fractionDigits = min(scale, 6)
            let fraction = Int.random(in: 0..<Int(pow(10, Double(fractionDigits))), using: &rng)
            return .text("\(whole).\(String(format: "%0\(fractionDigits)d", fraction))")
        case .boolean:
            return .bool(Bool.random(using: &rng))
        case .firstName:
            return .text(pick(Self.firstNames))
        case .lastName:
            return .text(pick(Self.lastNames))
        case .fullName:
            return .text("\(pick(Self.firstNames)) \(pick(Self.lastNames))")
        case .email:
            let name = pick(Self.firstNames).folding(options: .diacriticInsensitive, locale: nil).lowercased()
            let last = pick(Self.lastNames).folding(options: .diacriticInsensitive, locale: nil).lowercased()
            return .text("\(name).\(last)\(row + 1)@\(pick(Self.domains))")
        case .phone:
            return .text(String(format: "+55 11 9%04d-%04d", Int.random(in: 0...9999, using: &rng), Int.random(in: 0...9999, using: &rng)))
        case .city:
            return .text(pick(Self.cities))
        case .country:
            return .text(pick(Self.countries))
        case .street:
            return .text("\(pick(Self.streets)), \(Int.random(in: 1...2000, using: &rng))")
        case .company:
            return .text("\(pick(Self.companies)) \(["Ltda", "S.A.", "Inc", "Group"][Int.random(in: 0..<4, using: &rng)])")
        case .word:
            return .text(pick(Self.words))
        case .sentence:
            let count = Int.random(in: 4...10, using: &rng)
            let sentence = (0..<count).map { _ in pick(Self.words) }.joined(separator: " ")
            return .text(sentence.prefix(1).uppercased() + sentence.dropFirst() + ".")
        case .uuid:
            var bytes = (0..<16).map { _ in UInt8.random(in: 0...255, using: &rng) }
            bytes[6] = (bytes[6] & 0x0F) | 0x40
            bytes[8] = (bytes[8] & 0x3F) | 0x80
            return .text(UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                                     bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15])).uuidString.lowercased())
        case .date, .dateTime:
            // Within the last five years, from a fixed reference so seeded output is stable.
            let reference = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01
            let date = reference.addingTimeInterval(-Double.random(in: 0...(5 * 365 * 86_400), using: &rng))
            let style = Date.ISO8601FormatStyle(timeZone: .gmt)
            return .text(self == .date
                ? style.year().month().day().format(date)
                : style.year().month().day().dateTimeSeparator(.space).time(includingFractionalSeconds: false).format(date))
        }
    }

    /// (precision, scale) from `numeric(5,2)` / `decimal(10,2)`.
    static func precisionScale(_ type: String) -> (Int, Int)? {
        guard let open = type.firstIndex(of: "("), let close = type.firstIndex(of: ")"), open < close else { return nil }
        let parts = type[type.index(after: open)..<close].split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard let precision = parts.first else { return nil }
        return (precision, parts.count > 1 ? parts[1] : 0)
    }

    /// n from `varchar(n)` / `char(n)` / `character varying(n)`.
    static func lengthLimit(_ type: String?) -> Int? {
        guard let type = type?.lowercased(), type.contains("char"), let (length, _) = precisionScale(type) else { return nil }
        return length
    }

    /// Picks a generator from the column's name and type, skipping auto-generated keys.
    public static func suggested(for column: TableColumn) -> ValueGenerator {
        let name = column.name.lowercased()
        let type = column.dataType.lowercased()
        let defaultValue = column.defaultValue?.lowercased() ?? ""
        if defaultValue.contains("nextval") || defaultValue.contains("auto_increment") || type.contains("serial") { return .skip }
        if column.isPrimaryKey && (type == "integer" || type.hasPrefix("int")) { return .skip }
        if !defaultValue.isEmpty && (name.contains("updated") || name.contains("created") || name.hasPrefix("last_")) { return .skip }

        if name.contains("email") { return .email }
        if name.contains("phone") || name.contains("mobile") || name.contains("tel") { return .phone }
        if name == "first_name" || name == "firstname" { return .firstName }
        if name == "last_name" || name == "lastname" || name == "surname" { return .lastName }
        if name.contains("name") && !name.contains("_id") { return name.contains("company") ? .company : .fullName }
        if name.contains("city") { return .city }
        if name.contains("country") { return .country }
        if name.contains("address") || name.contains("street") { return .street }
        if name.contains("company") { return .company }
        if name.contains("uuid") || type.contains("uuid") { return .uuid }

        if type.contains("bool") || type == "tinyint(1)" { return .boolean }
        if type.contains("timestamp") || type.contains("datetime") { return .dateTime }
        if type.hasPrefix("date") { return .date }
        if type.contains("numeric") || type.contains("decimal") || type.contains("real") || type.contains("float") || type.contains("double") { return .decimal }
        if type.contains("int") { return .integer }
        if type.contains("text") || type.contains("char") || type.contains("clob") {
            return name.contains("note") || name.contains("description") || name.contains("comment") ? .sentence : .word
        }
        return column.nullable ? .null : .word
    }

    /// Rows of generated values for the columns that aren't skipped, as INSERT changes.
    public static func rows(count: Int, columns: [(name: String, generator: ValueGenerator)], types: [String: String] = [:], seed: UInt64) -> [RowChange] {
        var rng = SeededGenerator(seed: seed)
        let active = columns.filter { $0.generator != .skip }
        return (0..<count).map { row in
            .insert(values: active.map { ColumnValue($0.name, $0.generator.value(row: row, type: types[$0.name], using: &rng)) })
        }
    }
}
