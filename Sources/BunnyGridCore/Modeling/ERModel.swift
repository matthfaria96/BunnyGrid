import Foundation

/// A column as the ER diagram shows it.
public struct ERColumn: Hashable, Codable, Sendable {
    public var name: String
    public var dataType: String
    public var nullable: Bool
    public var isPrimaryKey: Bool
    public var isForeignKey: Bool
    public var defaultValue: String?

    public init(name: String, dataType: String, nullable: Bool, isPrimaryKey: Bool = false, isForeignKey: Bool = false, defaultValue: String? = nil) {
        self.name = name
        self.dataType = dataType
        self.nullable = nullable
        self.isPrimaryKey = isPrimaryKey
        self.isForeignKey = isForeignKey
        self.defaultValue = defaultValue
    }
}

/// A table card of the diagram.
public struct ERTable: Hashable, Identifiable, Codable, Sendable {
    public var schema: String?
    public var name: String
    public var columns: [ERColumn]

    public init(schema: String? = nil, name: String, columns: [ERColumn]) {
        self.schema = schema
        self.name = name
        self.columns = columns
    }

    /// "schema.name", or the name alone for engines without schemas. Keys positions and relationships.
    public var id: String { ERTable.id(schema: schema, name: name) }

    public static func id(schema: String?, name: String) -> String {
        guard let schema, !schema.isEmpty else { return name }
        return "\(schema).\(name)"
    }

    public var primaryKey: [String] { columns.filter(\.isPrimaryKey).map(\.name) }
}

/// A foreign key drawn as a line from the child (referencing) table to the parent (referenced) table.
public struct ERRelationship: Hashable, Identifiable, Sendable {
    public var name: String
    /// Child table id: the table that holds the foreign key ("many" end).
    public var fromTable: String
    public var fromColumns: [String]
    /// Parent table id ("one" end).
    public var toTable: String
    public var toColumns: [String]
    public var onDelete: String
    public var onUpdate: String
    /// Every key column of the child is nullable: a child row may have no parent (zero-or-one at the parent end).
    public var isOptional: Bool
    /// The key columns are also the child's primary key or a unique index: at most one child per parent.
    public var isOneToOne: Bool

    public init(name: String, fromTable: String, fromColumns: [String], toTable: String, toColumns: [String],
                onDelete: String = "NO ACTION", onUpdate: String = "NO ACTION", isOptional: Bool = false, isOneToOne: Bool = false) {
        self.name = name
        self.fromTable = fromTable
        self.fromColumns = fromColumns
        self.toTable = toTable
        self.toColumns = toColumns
        self.onDelete = onDelete
        self.onUpdate = onUpdate
        self.isOptional = isOptional
        self.isOneToOne = isOneToOne
    }

    public var id: String { "\(fromTable)(\(fromColumns.joined(separator: ",")))→\(toTable)(\(toColumns.joined(separator: ",")))" }

    public var isSelfReference: Bool { fromTable == toTable }
}

/// An entity-relationship model of one schema (or database): tables, columns and the foreign keys between them.
public struct ERModel: Hashable, Sendable {
    /// The engine the model was read from; forward engineering to another engine translates types.
    public var sourceKind: DatabaseKind
    public var tables: [ERTable]
    public var relationships: [ERRelationship]

    public init(sourceKind: DatabaseKind, tables: [ERTable], relationships: [ERRelationship]) {
        self.sourceKind = sourceKind
        self.tables = tables
        self.relationships = relationships
    }

    public func table(_ id: String) -> ERTable? { tables.first { $0.id == id } }

    /// Relationships that start or end at `tableID`.
    public func relationships(touching tableID: String) -> [ERRelationship] {
        relationships.filter { $0.fromTable == tableID || $0.toTable == tableID }
    }

    /// Tables linked to `tableID` by a foreign key in either direction (not including itself).
    public func neighbors(of tableID: String) -> Set<String> {
        var result = Set<String>()
        for relation in relationships(touching: tableID) {
            result.insert(relation.fromTable)
            result.insert(relation.toTable)
        }
        result.remove(tableID)
        return result
    }

    /// What reverse engineering reads for one table.
    public struct TableInput: Sendable {
        public var schema: String?
        public var name: String
        public var columns: [TableColumn]
        public var foreignKeys: [TableForeignKey]
        public var indexes: [TableIndex]

        public init(schema: String? = nil, name: String, columns: [TableColumn], foreignKeys: [TableForeignKey] = [], indexes: [TableIndex] = []) {
            self.schema = schema
            self.name = name
            self.columns = columns
            self.foreignKeys = foreignKeys
            self.indexes = indexes
        }
    }

    /// Builds the model from catalog data. Foreign keys to tables outside `inputs` still mark their columns,
    /// but draw no line. SQLite keys that omit the referenced columns point at the parent's primary key.
    public init(sourceKind: DatabaseKind, inputs: [TableInput]) {
        let sorted = inputs.sorted { ($0.schema ?? "", $0.name) < ($1.schema ?? "", $1.name) }
        let byID = Dictionary(sorted.map { (ERTable.id(schema: $0.schema, name: $0.name), $0) }, uniquingKeysWith: { first, _ in first })
        // Lookup ignoring case, since SQLite matches names case-insensitively.
        let lowercased = Dictionary(byID.map { ($0.key.lowercased(), $0.key) }, uniquingKeysWith: { first, _ in first })

        var tables: [ERTable] = []
        var relationships: [ERRelationship] = []
        for input in sorted {
            let id = ERTable.id(schema: input.schema, name: input.name)
            let fkColumns = Set(input.foreignKeys.flatMap(\.columns))
            let columns = input.columns.sorted { $0.ordinal < $1.ordinal }.map {
                ERColumn(name: $0.name, dataType: $0.dataType, nullable: $0.nullable, isPrimaryKey: $0.isPrimaryKey,
                         isForeignKey: fkColumns.contains($0.name), defaultValue: $0.defaultValue)
            }
            tables.append(ERTable(schema: input.schema, name: input.name, columns: columns))

            let primaryKey = Set(input.columns.filter(\.isPrimaryKey).map(\.name))
            let uniqueSets = input.indexes.filter { $0.unique || $0.primary }.map { Set($0.columns) }
            for key in input.foreignKeys where !key.columns.isEmpty {
                let parentID = ERTable.id(schema: key.referencedSchema ?? input.schema, name: key.referencedTable)
                guard let resolved = byID[parentID] != nil ? parentID : lowercased[parentID.lowercased()],
                      let parent = byID[resolved] else { continue }
                var referenced = key.referencedColumns
                if referenced.isEmpty || referenced.allSatisfy(\.isEmpty) {
                    referenced = parent.columns.filter(\.isPrimaryKey).sorted { $0.ordinal < $1.ordinal }.map(\.name)
                }
                let keySet = Set(key.columns)
                let nullable = key.columns.allSatisfy { name in input.columns.first { $0.name == name }?.nullable ?? true }
                relationships.append(ERRelationship(
                    name: key.name, fromTable: id, fromColumns: key.columns, toTable: resolved, toColumns: referenced,
                    onDelete: key.onDelete, onUpdate: key.onUpdate, isOptional: nullable,
                    isOneToOne: keySet == primaryKey || uniqueSets.contains(keySet)
                ))
            }
        }
        self.init(sourceKind: sourceKind, tables: tables, relationships: relationships)
    }

    /// Reverse engineering: reads the tables of `schema` with their columns, indexes and foreign keys.
    /// `schema` is what the driver expects (nil on SQLite, the database on MySQL); `displaySchema` qualifies
    /// table ids and generated SQL (the PostgreSQL schema, nil elsewhere).
    public static func reverseEngineer(driver: any DatabaseDriver, schema: String?, displaySchema: String? = nil) async throws -> ERModel {
        var inputs: [TableInput] = []
        for object in try await driver.listObjects(schema: schema) where object.kind == .table {
            try Task.checkCancellation()
            let columns = try await driver.listColumns(table: object.name, schema: schema)
            let keys = (try? await driver.listForeignKeys(table: object.name, schema: schema)) ?? []
            let indexes = (try? await driver.listIndexes(table: object.name, schema: schema)) ?? []
            // Keys that stay inside the schema keep the model's own (display) schema.
            let local = keys.map { key -> TableForeignKey in
                var key = key
                if key.referencedSchema == nil || key.referencedSchema == schema { key.referencedSchema = displaySchema }
                return key
            }
            inputs.append(TableInput(schema: displaySchema, name: object.name, columns: columns, foreignKeys: local, indexes: indexes))
        }
        return ERModel(sourceKind: driver.config.kind, inputs: inputs)
    }
}
