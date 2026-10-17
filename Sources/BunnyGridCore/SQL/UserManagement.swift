import Foundation

/// A login or role on the server, as the User manager lists it.
public struct DatabaseUser: Hashable, Identifiable, Sendable {
    public var name: String
    /// MySQL's host part ("%" or "localhost"); nil on PostgreSQL.
    public var host: String?
    /// Short flags for the list: "Superuser", "Can login", "Create DB", …
    public var attributes: [String]

    public init(name: String, host: String? = nil, attributes: [String] = []) {
        self.name = name
        self.host = host
        self.attributes = attributes
    }

    public var id: String { host.map { "\(name)@\($0)" } ?? name }
}

/// What the New User form fills in.
public struct UserDraft: Sendable {
    public var name: String
    public var password: String
    public var host: String
    public var canLogin: Bool
    public var superuser: Bool
    public var createDatabases: Bool

    public init(name: String = "", password: String = "", host: String = "%", canLogin: Bool = true,
                superuser: Bool = false, createDatabases: Bool = false) {
        self.name = name
        self.password = password
        self.host = host
        self.canLogin = canLogin
        self.superuser = superuser
        self.createDatabases = createDatabases
    }
}

/// Server users and roles (Navicat's "User" button). SQLite has none.
extension SQLDialect {
    public var supportsUsers: Bool { kind != .sqlite }

    public var listUsersSQL: String? {
        switch kind {
        case .postgresql:
            "SELECT rolname, rolsuper, rolcanlogin, rolcreatedb, rolcreaterole FROM pg_roles WHERE rolname !~ '^pg_' ORDER BY rolname"
        case .mysql, .mariadb:
            "SELECT User, Host, Super_priv, Create_priv FROM mysql.user ORDER BY User, Host"
        case .sqlserver:
            """
            SELECT p.name, p.type_desc, IS_SRVROLEMEMBER('sysadmin', p.name), IS_SRVROLEMEMBER('dbcreator', p.name), p.is_disabled
              FROM sys.server_principals p
             WHERE p.type IN ('S', 'U', 'G', 'E', 'X') AND p.name NOT LIKE '##%'
             ORDER BY p.name
            """
        case .sqlite: nil
        }
    }

    public func users(from result: QueryResult) -> [DatabaseUser] {
        func yes(_ value: CellValue?) -> Bool {
            switch value {
            case .bool(let b): b
            case .integer(let n): n != 0
            case .text(let t): ["t", "true", "y", "yes", "1"].contains(t.lowercased())
            default: false
            }
        }
        return result.rows.compactMap { row -> DatabaseUser? in
            guard let name = row.first?.displayString else { return nil }
            switch kind {
            case .postgresql:
                var flags: [String] = []
                if yes(row[safe: 1]) { flags.append("Superuser") }
                flags.append(yes(row[safe: 2]) ? "Can login" : "Role")
                if yes(row[safe: 3]) { flags.append("Create DB") }
                if yes(row[safe: 4]) { flags.append("Create role") }
                return DatabaseUser(name: name, attributes: flags)
            case .sqlserver:
                var flags: [String] = []
                if let type = row[safe: 1]?.displayString {
                    flags.append(type == "SQL_LOGIN" ? "SQL login" : type.capitalized.replacingOccurrences(of: "_", with: " "))
                }
                if yes(row[safe: 2]) { flags.append("sysadmin") }
                if yes(row[safe: 3]) { flags.append("dbcreator") }
                if yes(row[safe: 4]) { flags.append("Disabled") }
                return DatabaseUser(name: name, attributes: flags)
            default:
                var flags: [String] = []
                if yes(row[safe: 2]) { flags.append("Super") }
                if yes(row[safe: 3]) { flags.append("Create") }
                return DatabaseUser(name: name, host: row[safe: 1]?.displayString, attributes: flags)
            }
        }
    }

    func account(_ name: String, host: String?) -> String {
        switch kind {
        case .mysql, .mariadb: "\(quoteLiteral(name))@\(quoteLiteral(host ?? "%"))"
        default: quoteIdentifier(name)
        }
    }

    public func createUser(_ draft: UserDraft) throws -> [String] {
        let name = draft.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw TableDesignError.invalid("The user needs a name.") }
        switch kind {
        case .postgresql:
            var options = [draft.canLogin ? "LOGIN" : "NOLOGIN"]
            if draft.superuser { options.append("SUPERUSER") }
            if draft.createDatabases { options.append("CREATEDB") }
            if !draft.password.isEmpty { options.append("PASSWORD \(quoteLiteral(draft.password))") }
            return ["CREATE ROLE \(quoteIdentifier(name)) \(options.joined(separator: " "))"]
        case .mysql, .mariadb:
            var statements = ["CREATE USER \(account(name, host: draft.host)) IDENTIFIED BY \(quoteLiteral(draft.password))"]
            if draft.superuser { statements.append("GRANT ALL PRIVILEGES ON *.* TO \(account(name, host: draft.host)) WITH GRANT OPTION") }
            else if draft.createDatabases { statements.append("GRANT CREATE ON *.* TO \(account(name, host: draft.host))") }
            return statements
        case .sqlserver:
            var statements = ["CREATE LOGIN \(quoteIdentifier(name)) WITH PASSWORD = \(quoteLiteral(draft.password))"]
            if draft.superuser { statements.append("ALTER SERVER ROLE [sysadmin] ADD MEMBER \(quoteIdentifier(name))") }
            if draft.createDatabases { statements.append("ALTER SERVER ROLE [dbcreator] ADD MEMBER \(quoteIdentifier(name))") }
            if !draft.canLogin { statements.append("ALTER LOGIN \(quoteIdentifier(name)) DISABLE") }
            return statements
        case .sqlite:
            throw DatabaseError.unsupported("Users")
        }
    }

    public func dropUser(_ user: DatabaseUser) -> String {
        switch kind {
        case .postgresql: "DROP ROLE \(quoteIdentifier(user.name))"
        case .sqlserver: "DROP LOGIN \(quoteIdentifier(user.name))"
        default: "DROP USER \(account(user.name, host: user.host))"
        }
    }

    public func setPassword(_ user: DatabaseUser, to password: String) -> String {
        switch kind {
        case .postgresql: "ALTER ROLE \(quoteIdentifier(user.name)) PASSWORD \(quoteLiteral(password))"
        case .sqlserver: "ALTER LOGIN \(quoteIdentifier(user.name)) WITH PASSWORD = \(quoteLiteral(password))"
        default: "ALTER USER \(account(user.name, host: user.host)) IDENTIFIED BY \(quoteLiteral(password))"
        }
    }

    /// The privileges shown for a selected user.
    public func grantsSQL(_ user: DatabaseUser) -> String? {
        switch kind {
        case .postgresql:
            """
            SELECT table_schema || '.' || table_name AS object, string_agg(privilege_type, ', ' ORDER BY privilege_type) AS privileges
              FROM information_schema.role_table_grants WHERE grantee = \(quoteLiteral(user.name))
             GROUP BY table_schema, table_name ORDER BY 1
            """
        case .mysql, .mariadb: "SHOW GRANTS FOR \(account(user.name, host: user.host))"
        case .sqlserver:
            """
            SELECT 'SERVER ROLE' AS object, r.name AS privileges FROM sys.server_role_members m
              JOIN sys.server_principals r ON r.principal_id = m.role_principal_id
              JOIN sys.server_principals u ON u.principal_id = m.member_principal_id WHERE u.name = \(quoteLiteral(user.name))
            UNION ALL
            SELECT 'SERVER', p.state_desc + ' ' + p.permission_name FROM sys.server_permissions p
              JOIN sys.server_principals u ON u.principal_id = p.grantee_principal_id WHERE u.name = \(quoteLiteral(user.name))
            ORDER BY 1, 2
            """
        case .sqlite: nil
        }
    }

    /// Navicat's "Others" menu: catalog queries for the object types without their own folder.
    public var otherObjectQueries: [(title: String, sql: String)] {
        switch kind {
        case .postgresql:
            [("Sequences", "SELECT sequence_schema, sequence_name, data_type, start_value, increment FROM information_schema.sequences ORDER BY 1, 2"),
             ("Types", "SELECT n.nspname AS schema, t.typname AS name, CASE t.typtype WHEN 'e' THEN 'enum' WHEN 'c' THEN 'composite' WHEN 'd' THEN 'domain' WHEN 'r' THEN 'range' ELSE t.typtype::text END AS kind FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace WHERE n.nspname NOT IN ('pg_catalog', 'information_schema') AND t.typtype IN ('e', 'c', 'd', 'r') AND (t.typtype <> 'c' OR EXISTS (SELECT 1 FROM pg_class c WHERE c.oid = t.typrelid AND c.relkind = 'c')) ORDER BY 1, 2"),
             ("Triggers", "SELECT event_object_schema AS schema, event_object_table AS table_name, trigger_name, action_timing, string_agg(event_manipulation, ', ') AS events FROM information_schema.triggers GROUP BY 1, 2, 3, 4 ORDER BY 1, 2, 3"),
             ("Indexes", "SELECT schemaname AS schema, tablename AS table_name, indexname, indexdef FROM pg_indexes WHERE schemaname NOT IN ('pg_catalog', 'information_schema') ORDER BY 1, 2, 3"),
             ("Extensions", "SELECT extname AS name, extversion AS version FROM pg_extension ORDER BY 1"),
             ("Schemas", "SELECT schema_name, schema_owner FROM information_schema.schemata WHERE schema_name NOT LIKE 'pg\\_%' AND schema_name <> 'information_schema' ORDER BY 1")]
        case .mysql, .mariadb:
            [("Triggers", "SELECT TRIGGER_NAME, EVENT_OBJECT_TABLE, ACTION_TIMING, EVENT_MANIPULATION FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA = DATABASE() ORDER BY 1"),
             ("Events", "SELECT EVENT_NAME, STATUS, EVENT_TYPE, EXECUTE_AT, INTERVAL_VALUE, INTERVAL_FIELD FROM information_schema.EVENTS WHERE EVENT_SCHEMA = DATABASE() ORDER BY 1"),
             ("Indexes", "SELECT TABLE_NAME, INDEX_NAME, NON_UNIQUE, GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX) AS columns FROM information_schema.STATISTICS WHERE TABLE_SCHEMA = DATABASE() GROUP BY 1, 2, 3 ORDER BY 1, 2")]
        case .sqlserver:
            [("Procedures", "SELECT SCHEMA_NAME(schema_id) AS [schema], name, create_date, modify_date FROM sys.procedures WHERE is_ms_shipped = 0 ORDER BY 1, 2"),
             ("Triggers", "SELECT OBJECT_SCHEMA_NAME(parent_id) AS [schema], OBJECT_NAME(parent_id) AS table_name, name, is_instead_of_trigger, is_disabled FROM sys.triggers WHERE parent_class = 1 ORDER BY 1, 2, 3"),
             ("Sequences", "SELECT SCHEMA_NAME(schema_id) AS [schema], name, start_value, increment, current_value FROM sys.sequences ORDER BY 1, 2"),
             ("Synonyms", "SELECT SCHEMA_NAME(schema_id) AS [schema], name, base_object_name FROM sys.synonyms ORDER BY 1, 2"),
             ("Types", "SELECT SCHEMA_NAME(schema_id) AS [schema], name, TYPE_NAME(system_type_id) AS base_type, max_length, is_nullable FROM sys.types WHERE is_user_defined = 1 ORDER BY 1, 2"),
             ("Indexes", "SELECT OBJECT_SCHEMA_NAME(i.object_id) AS [schema], OBJECT_NAME(i.object_id) AS table_name, i.name, i.type_desc, i.is_unique FROM sys.indexes i JOIN sys.objects o ON o.object_id = i.object_id WHERE o.is_ms_shipped = 0 AND i.name IS NOT NULL ORDER BY 1, 2, 3"),
             ("Schemas", "SELECT s.name, p.name AS owner FROM sys.schemas s JOIN sys.database_principals p ON p.principal_id = s.principal_id ORDER BY 1")]
        case .sqlite:
            [("Indexes", "SELECT name, tbl_name, sql FROM sqlite_master WHERE type = 'index' ORDER BY tbl_name, name"),
             ("Triggers", "SELECT name, tbl_name, sql FROM sqlite_master WHERE type = 'trigger' ORDER BY tbl_name, name")]
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
