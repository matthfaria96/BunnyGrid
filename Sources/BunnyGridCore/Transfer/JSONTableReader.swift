import Foundation

/// Rows read from a data file for the Import Wizard: column names in first-seen order and typed values.
public struct ImportedTable: Sendable, Equatable {
    public var columns: [String]
    public var rows: [[CellValue]]

    public init(columns: [String], rows: [[CellValue]]) {
        self.columns = columns
        self.rows = rows
    }
}

/// Reads JSON for import: an array of objects (`[{"id": 1}, …]`), an object holding one such array
/// (`{"rows": [...]}`, as many APIs return), or JSON Lines (one object per line).
/// Nested objects and arrays become their JSON text; a key missing from a row is NULL.
public enum JSONTableReader {
    public enum ReadError: LocalizedError, Equatable {
        case notTabular
        case invalid(String)

        public var errorDescription: String? {
            switch self {
            case .notTabular: "The JSON must be an array of objects, an object with such an array, or one object per line."
            case .invalid(let message): "The file is not valid JSON: \(message)"
            }
        }
    }

    public static func read(_ data: Data) throws -> ImportedTable {
        var data = data
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { data = data.dropFirst(3) }
        let objects: [[String: Any]]
        do {
            let root = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            guard let found = records(in: root) else { throw ReadError.notTabular }
            objects = found
        } catch let error as ReadError {
            throw error
        } catch {
            // Not one JSON document: try JSON Lines.
            let lines = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard lines.count > 1 else { throw ReadError.invalid(error.localizedDescription) }
            objects = try lines.map { line in
                guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                    throw ReadError.invalid(error.localizedDescription)
                }
                return object
            }
        }
        return table(from: objects, keyOrder: keyOrder(in: data))
    }

    private static func records(in root: Any) -> [[String: Any]]? {
        if let array = root as? [Any] {
            let objects = array.compactMap { $0 as? [String: Any] }
            return objects.count == array.count ? objects : nil
        }
        if let object = root as? [String: Any] {
            let arrays = object.values.compactMap { $0 as? [Any] }.filter { !$0.isEmpty && $0.allSatisfy { $0 is [String: Any] } }
            if arrays.count == 1 { return arrays[0] as? [[String: Any]] }
            // A single record.
            return object.values.contains { $0 is [Any] || $0 is [String: Any] } ? nil : [object]
        }
        return nil
    }

    private static func table(from objects: [[String: Any]], keyOrder: [String]) -> ImportedTable {
        // JSONSerialization loses key order, so columns follow their first appearance in the file text.
        var present = Set<String>()
        for object in objects { present.formUnion(object.keys) }
        var columns = keyOrder.filter { present.remove($0) != nil }
        columns += present.sorted()
        let rows = objects.map { object in columns.map { object[$0].map(cellValue) ?? .null } }
        return ImportedTable(columns: columns, rows: rows)
    }

    static func cellValue(_ any: Any) -> CellValue {
        switch any {
        case is NSNull:
            return .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            if CFNumberIsFloatType(number) {
                let d = number.doubleValue
                return .double(d)
            }
            if let exact = Int64(exactly: number) { return .integer(exact) }
            return .text(number.stringValue)
        case let string as String:
            return .text(string)
        default:
            let data = try? JSONSerialization.data(withJSONObject: any, options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
            return .text(data.map { String(decoding: $0, as: UTF8.self) } ?? String(describing: any))
        }
    }

    /// Object keys in the order they first appear in the text (a light scan: a string followed by `:`).
    static func keyOrder(in data: Data) -> [String] {
        let bytes = [UInt8](data)
        var keys: [String] = []
        var seen = Set<String>()
        var i = 0
        while i < bytes.count {
            guard bytes[i] == UInt8(ascii: "\"") else { i += 1; continue }
            var j = i + 1
            var raw: [UInt8] = []
            while j < bytes.count && bytes[j] != UInt8(ascii: "\"") {
                if bytes[j] == UInt8(ascii: "\\"), j + 1 < bytes.count { raw.append(bytes[j]); j += 1 }
                raw.append(bytes[j])
                j += 1
            }
            var k = j + 1
            while k < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[k]) { k += 1 }
            if k < bytes.count, bytes[k] == UInt8(ascii: ":") {
                let quoted = "\"" + String(decoding: raw, as: UTF8.self) + "\""
                if let key = (try? JSONSerialization.jsonObject(with: Data(quoted.utf8), options: .fragmentsAllowed)) as? String,
                   seen.insert(key).inserted {
                    keys.append(key)
                }
            }
            i = j + 1
        }
        return keys
    }
}
