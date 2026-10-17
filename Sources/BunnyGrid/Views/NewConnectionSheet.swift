import AppKit
import BunnyGridCore
import SwiftUI

// MARK: - Catalog

/// Engine families of the Connection Filter, with the tile colors of Navicat's picker.
enum ConnectionFamily: String, CaseIterable, Identifiable {
    case mysql, postgresql, sqlserver, oracle, sqlite, mariadb, mongodb, redis, snowflake

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .mysql: "MySQL"
        case .postgresql: "PostgreSQL"
        case .sqlserver: "SQL Server"
        case .oracle: "Oracle"
        case .sqlite: "SQLite"
        case .mariadb: "MariaDB"
        case .mongodb: "MongoDB"
        case .redis: "Redis"
        case .snowflake: "Snowflake"
        }
    }

    /// Top and bottom of the tile gradient.
    var colors: (Color, Color) {
        switch self {
        case .mysql: (Color(red: 0.36, green: 0.84, blue: 0.42), Color(red: 0.17, green: 0.68, blue: 0.27))
        case .postgresql: (Color(red: 0.36, green: 0.62, blue: 1.0), Color(red: 0.16, green: 0.43, blue: 0.93))
        case .sqlserver: (Color(red: 1.0, green: 0.75, blue: 0.16), Color(red: 0.96, green: 0.58, blue: 0.0))
        case .oracle: (Color(red: 1.0, green: 0.27, blue: 0.31), Color(red: 0.87, green: 0.06, blue: 0.14))
        case .sqlite: (Color(red: 0.42, green: 0.88, blue: 0.84), Color(red: 0.18, green: 0.72, blue: 0.70))
        case .mariadb: (Color(red: 0.82, green: 0.65, blue: 0.48), Color(red: 0.66, green: 0.49, blue: 0.33))
        case .mongodb: (Color(red: 0.84, green: 0.43, blue: 0.13), Color(red: 0.66, green: 0.30, blue: 0.04))
        case .redis: (Color(red: 1.0, green: 0.55, blue: 0.50), Color(red: 0.93, green: 0.38, blue: 0.34))
        case .snowflake: (Color(red: 0.32, green: 0.80, blue: 0.98), Color(red: 0.10, green: 0.62, blue: 0.88))
        }
    }

    /// Monogram drawn on the engine's own tile (no vendor logos).
    var monogram: String {
        switch self {
        case .mysql: "My"
        case .postgresql: "Pg"
        case .sqlserver: "MS"
        case .oracle: "Or"
        case .sqlite: "Sq"
        case .mariadb: "Ma"
        case .mongodb: "Mo"
        case .redis: "Rd"
        case .snowflake: "Sf"
        }
    }
}

/// Cloud and distribution vendors of the Vendor Filter.
enum ConnectionVendor: String, CaseIterable, Identifiable {
    case aws, fujitsu, google, microsoft, oracle, alibaba, highgo, huawei, kingbase, oceanbase, pingcap, tencent

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .aws: "AWS"
        case .fujitsu: "Fujitsu"
        case .google: "Google Cloud"
        case .microsoft: "Microsoft"
        case .oracle: "Oracle"
        case .alibaba: "Alibaba Cloud"
        case .highgo: "HighGo"
        case .huawei: "Huawei"
        case .kingbase: "Kingbase"
        case .oceanbase: "OceanBase"
        case .pingcap: "PingCAP"
        case .tencent: "Tencent Cloud"
        }
    }

    /// Short name shown on the vendor's tiles.
    var mark: String {
        switch self {
        case .aws: "aws"
        case .fujitsu: "Fj"
        case .google: "GC"
        case .microsoft: "Az"
        case .oracle: "OCI"
        case .alibaba: "Ali"
        case .highgo: "HG"
        case .huawei: "HW"
        case .kingbase: "K"
        case .oceanbase: "OB"
        case .pingcap: "Ti"
        case .tencent: "TC"
        }
    }

    /// Example endpoint shown in the Host field for this vendor's services.
    var hostHint: String {
        switch self {
        case .aws: "mydb.abc123xyz.us-east-1.rds.amazonaws.com"
        case .google: "Public IP of the Cloud SQL instance"
        case .microsoft: "myserver.postgres.database.azure.com"
        case .oracle: "Endpoint of the cloud instance"
        case .alibaba: "rm-xxxxxxxx.mysql.rds.aliyuncs.com"
        case .huawei: "Endpoint from the Huawei Cloud console"
        case .tencent: "Endpoint from the TencentDB console"
        case .pingcap: "gateway01.region.prod.aws.tidbcloud.com"
        default: "Server address"
        }
    }

    var sidebarColor: Color {
        switch self {
        case .aws: Color(red: 0.98, green: 0.60, blue: 0.0)
        case .fujitsu, .oracle, .huawei, .kingbase: Color(red: 0.90, green: 0.12, blue: 0.18)
        case .google: Color(red: 0.26, green: 0.52, blue: 0.96)
        case .microsoft: Color(red: 0.0, green: 0.47, blue: 0.84)
        case .alibaba: Color(red: 1.0, green: 0.42, blue: 0.0)
        case .highgo: Color(red: 0.55, green: 0.58, blue: 0.62)
        case .oceanbase: Color(red: 0.04, green: 0.42, blue: 0.96)
        case .pingcap: Color(red: 0.20, green: 0.40, blue: 0.95)
        case .tencent: Color(red: 0.0, green: 0.64, blue: 1.0)
        }
    }
}

/// One choice in the New Connection picker.
struct ConnectionType: Identifiable, Hashable {
    let id: String
    let name: String
    let family: ConnectionFamily?
    let vendor: ConnectionVendor?
    /// The driver that speaks this service's wire protocol; nil when not supported yet.
    let driver: DatabaseKind?
    var port: Int?
    var tls: TLSMode = .prefer
    /// Tile color when it isn't the family's (OceanBase blue, TiDB red, Redshift purple…).
    var tint: (Color, Color)?
    /// Group in the list view for entries without a vendor (MongoDB Atlas, Redis Enterprise Cloud).
    var listGroup: String?

    static func == (a: ConnectionType, b: ConnectionType) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    var isSupported: Bool { driver != nil }
    var isEngine: Bool { vendor == nil && listGroup == nil }

    var colors: (Color, Color) {
        tint ?? family?.colors ?? (Color.gray, Color.gray.opacity(0.7))
    }
}

enum ConnectionCatalog {
    private static let purple: (Color, Color) = (Color(red: 0.62, green: 0.42, blue: 1.0), Color(red: 0.45, green: 0.25, blue: 0.90))
    private static let red: (Color, Color) = (Color(red: 0.95, green: 0.20, blue: 0.24), Color(red: 0.78, green: 0.05, blue: 0.12))
    private static let blue: (Color, Color) = (Color(red: 0.16, green: 0.52, blue: 1.0), Color(red: 0.02, green: 0.36, blue: 0.90))
    private static let amber: (Color, Color) = (Color(red: 1.0, green: 0.72, blue: 0.30), Color(red: 0.95, green: 0.55, blue: 0.10))

    private static func engine(_ family: ConnectionFamily, _ driver: DatabaseKind?) -> ConnectionType {
        ConnectionType(id: family.rawValue, name: family.displayName, family: family, vendor: nil, driver: driver)
    }

    private static func cloud(_ id: String, _ name: String, _ family: ConnectionFamily, _ vendor: ConnectionVendor?,
                              port: Int? = nil, tint: (Color, Color)? = nil, driver: DatabaseKind?? = nil, listGroup: String? = nil) -> ConnectionType {
        let defaultDriver: DatabaseKind? = switch family {
        case .mysql: .mysql
        case .postgresql: .postgresql
        case .mariadb: .mariadb
        case .sqlite: .sqlite
        case .mongodb: .mongodb
        default: nil
        }
        return ConnectionType(id: id, name: name, family: family, vendor: vendor, driver: driver ?? defaultDriver,
                              port: port, tls: .require, tint: tint, listGroup: listGroup)
    }

    static let engines: [ConnectionType] = [
        engine(.mysql, .mysql), engine(.postgresql, .postgresql), engine(.sqlserver, nil), engine(.oracle, nil),
        engine(.sqlite, .sqlite), engine(.mariadb, .mariadb), engine(.mongodb, .mongodb), engine(.redis, nil), engine(.snowflake, nil),
    ]

    /// Same order as Navicat's grid.
    static let cloudServices: [ConnectionType] = [
        cloud("aws-rds-mysql", "Amazon RDS for MySQL", .mysql, .aws),
        cloud("aws-rds-postgresql", "Amazon RDS for PostgreSQL", .postgresql, .aws),
        cloud("aws-rds-sqlserver", "Amazon RDS for SQL Server", .sqlserver, .aws),
        cloud("aws-rds-oracle", "Amazon RDS for Oracle", .oracle, .aws),
        cloud("aws-rds-mariadb", "Amazon RDS for MariaDB", .mariadb, .aws),
        cloud("aws-aurora-mysql", "Amazon Aurora for MySQL", .mysql, .aws),
        cloud("aws-aurora-postgresql", "Amazon Aurora for PostgreSQL", .postgresql, .aws),
        cloud("aws-redshift", "Amazon Redshift", .postgresql, .aws, port: 5439, tint: purple),
        cloud("aws-documentdb", "Amazon DocumentDB", .mongodb, .aws),
        cloud("aws-elasticache", "Amazon ElastiCache for Redis", .redis, .aws),
        cloud("fujitsu-postgres", "Fujitsu Enterprise Postgres", .postgresql, .fujitsu, tint: red),
        cloud("gcp-mysql", "Google Cloud SQL for MySQL", .mysql, .google),
        cloud("gcp-postgresql", "Google Cloud SQL for PostgreSQL", .postgresql, .google),
        cloud("gcp-sqlserver", "Google Cloud SQL for SQL Server", .sqlserver, .google),
        cloud("gcp-memorystore", "Google Memorystore (Redis)", .redis, .google),
        cloud("azure-sql", "Microsoft Azure SQL Database", .sqlserver, .microsoft),
        cloud("azure-mysql", "Microsoft Azure Database for MySQL", .mysql, .microsoft),
        cloud("azure-postgresql", "Microsoft Azure Database for PostgreSQL", .postgresql, .microsoft),
        cloud("azure-mariadb", "Microsoft Azure Database for MariaDB", .mariadb, .microsoft),
        cloud("azure-cosmos-mongo", "Microsoft Azure Cosmos DB for MongoDB", .mongodb, .microsoft),
        cloud("azure-redis", "Microsoft Azure Cache for Redis", .redis, .microsoft),
        cloud("ms-garnet", "Microsoft Garnet", .redis, .microsoft, tint: (Color(red: 0.75, green: 0.10, blue: 0.14), Color(red: 0.55, green: 0.04, blue: 0.08))),
        cloud("mongodb-atlas", "MongoDB Atlas", .mongodb, nil, listGroup: "MongoDB Atlas"),
        cloud("oracle-cloud", "Oracle Database Cloud Services", .oracle, .oracle),
        cloud("oracle-mysql-cloud", "Oracle MySQL Cloud Service", .mysql, .oracle),
        cloud("redis-enterprise", "Redis Enterprise Cloud", .redis, nil, listGroup: "Redis Enterprise Cloud"),
        cloud("ali-rds-mysql", "Alibaba Cloud ApsaraDB RDS for MySQL", .mysql, .alibaba),
        cloud("ali-rds-postgresql", "Alibaba Cloud ApsaraDB RDS for PostgreSQL", .postgresql, .alibaba),
        cloud("ali-rds-sqlserver", "Alibaba Cloud ApsaraDB RDS for SQL Server", .sqlserver, .alibaba),
        cloud("ali-mongodb", "Alibaba Cloud ApsaraDB for MongoDB", .mongodb, .alibaba),
        cloud("ali-redis", "Alibaba Cloud ApsaraDB for Redis", .redis, .alibaba),
        cloud("ali-oceanbase", "Alibaba Cloud ApsaraDB for OceanBase (MySQL Mode)", .mysql, .alibaba, port: 2881, tint: blue),
        cloud("ali-polardb-mysql", "Alibaba Cloud PolarDB for MySQL", .mysql, .alibaba),
        cloud("ali-polardb-postgresql", "Alibaba Cloud PolarDB for PostgreSQL", .postgresql, .alibaba),
        cloud("ali-polardb-x", "Alibaba Cloud PolarDB for Xscale", .mysql, .alibaba),
        cloud("ivorysql", "IvorySQL", .postgresql, .highgo, tint: amber),
        cloud("huawei-mysql", "Huawei Cloud RDS for MySQL", .mysql, .huawei),
        cloud("huawei-postgresql", "Huawei Cloud RDS for PostgreSQL", .postgresql, .huawei),
        cloud("huawei-sqlserver", "Huawei Cloud RDS for SQL Server", .sqlserver, .huawei),
        cloud("huawei-dds", "Huawei Cloud Document Database Service", .mongodb, .huawei),
        cloud("huawei-dcs", "Huawei Cloud Distributed Cache Service for Redis", .redis, .huawei),
        cloud("kingbasees", "KingbaseES", .postgresql, .kingbase, port: 54321, tint: red),
        cloud("oceanbase-ce", "OceanBase Community Edition", .mysql, .oceanbase, port: 2881, tint: blue),
        cloud("oceanbase-ee", "OceanBase Enterprise Edition (MySQL Mode)", .mysql, .oceanbase, port: 2881, tint: blue),
        cloud("tidb", "TiDB", .mysql, .pingcap, port: 4000, tint: red),
        cloud("tencent-mysql", "Tencent Cloud TencentDB for MySQL", .mysql, .tencent),
        cloud("tencent-postgresql", "Tencent Cloud TencentDB for PostgreSQL", .postgresql, .tencent),
        cloud("tencent-sqlserver", "Tencent Cloud TencentDB for SQL Server", .sqlserver, .tencent),
        cloud("tencent-mariadb", "Tencent Cloud TencentDB for MariaDB", .mariadb, .tencent),
        cloud("tencent-mongodb", "Tencent Cloud TencentDB for MongoDB", .mongodb, .tencent),
        cloud("tencent-redis", "Tencent Cloud TencentDB for Redis", .redis, .tencent),
    ]

    static let all: [ConnectionType] = engines + cloudServices

    static func type(id: String) -> ConnectionType? { all.first { $0.id == id } }

    /// Vendor groups for the list view, in Navicat's order.
    static var listGroups: [(name: String, sidebarColor: Color, mark: String, types: [ConnectionType])] {
        var groups: [(String, Color, String, [ConnectionType])] = []
        for type in cloudServices {
            let name = type.vendor?.displayName ?? type.listGroup ?? type.name
            if let index = groups.firstIndex(where: { $0.0 == name }) {
                groups[index].3.append(type)
            } else {
                groups.append((name, type.vendor?.sidebarColor ?? type.colors.1, type.vendor?.mark ?? (type.family?.monogram ?? "?"), [type]))
            }
        }
        return groups.map { (name: $0.0, sidebarColor: $0.1, mark: $0.2, types: $0.3) }
    }
}

// MARK: - Tile

/// Glossy tile for a connection type: the engine's color with our own white mark
/// (engine monogram, or the vendor's short name under a cloud for hosted services).
struct ConnectionTypeIcon: View {
    let type: ConnectionType
    var size: CGFloat = 50

    var body: some View {
        let (top, bottom) = type.colors
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.2, style: .continuous)
                .fill(LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom))
            RoundedRectangle(cornerRadius: size * 0.2, style: .continuous)
                .fill(LinearGradient(colors: [.white.opacity(0.28), .clear], startPoint: .top, endPoint: .center))
            RoundedRectangle(cornerRadius: size * 0.2, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: max(0.5, size * 0.015))
            if let vendor = type.vendor {
                VStack(spacing: size * 0.02) {
                    CloudMark()
                        .fill(.white.opacity(0.92))
                        .frame(width: size * 0.5, height: size * 0.28)
                    Text(vendor.mark)
                        .font(.system(size: size * (vendor.mark.count > 2 ? 0.24 : 0.28), weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                }
                .shadow(color: .black.opacity(0.15), radius: 0.5, y: 0.5)
            } else if type.listGroup != nil {
                VStack(spacing: size * 0.02) {
                    CloudMark()
                        .fill(.white.opacity(0.92))
                        .frame(width: size * 0.5, height: size * 0.28)
                    Text(type.family?.monogram ?? "")
                        .font(.system(size: size * 0.28, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                }
            } else {
                Text(type.family?.monogram ?? "")
                    .font(.system(size: size * 0.42, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.18), radius: 0.5, y: 0.8)
            }
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.22), radius: size * 0.03, y: size * 0.02)
    }
}

/// A simple cloud silhouette (three lobes on a flat base).
struct CloudMark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width, h = rect.height
        path.addEllipse(in: CGRect(x: rect.minX + w * 0.04, y: rect.minY + h * 0.38, width: w * 0.36, height: h * 0.62))
        path.addEllipse(in: CGRect(x: rect.minX + w * 0.22, y: rect.minY, width: w * 0.48, height: h * 0.86))
        path.addEllipse(in: CGRect(x: rect.minX + w * 0.56, y: rect.minY + h * 0.28, width: w * 0.40, height: h * 0.72))
        path.addRoundedRect(in: CGRect(x: rect.minX + w * 0.2, y: rect.minY + h * 0.6, width: w * 0.62, height: h * 0.4), cornerSize: CGSize(width: h * 0.2, height: h * 0.2))
        return path
    }
}

// MARK: - Sheet

/// Navicat's "New Connection" picker: filters on the left, connection types on the right,
/// then the connection form for the chosen type.
struct NewConnectionSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var search = ""
    @State private var familyFilter: Set<ConnectionFamily> = []
    @State private var vendorFilter: Set<ConnectionVendor> = []
    @AppStorage("newConnectionListMode") private var listMode = true
    @State private var selection: ConnectionType?
    @State private var expandedGroups: Set<String> = []
    @State private var details: (draft: ConnectionDraft, type: ConnectionType?)?
    @State private var showingURI = false
    @State private var uriText = ""
    @State private var uriError: String?

    private var recents: [ConnectionType] {
        (UserDefaults.standard.stringArray(forKey: "recentConnectionTypes") ?? []).compactMap(ConnectionCatalog.type(id:))
    }

    private var isFiltering: Bool { !search.isEmpty || !familyFilter.isEmpty || !vendorFilter.isEmpty }

    private func matches(_ type: ConnectionType) -> Bool {
        if !familyFilter.isEmpty, !(type.family.map(familyFilter.contains) ?? false) { return false }
        if !vendorFilter.isEmpty, !(type.vendor.map(vendorFilter.contains) ?? false) { return false }
        if !search.isEmpty, !type.name.localizedCaseInsensitiveContains(search) { return false }
        return true
    }

    var body: some View {
        Group {
            if let details {
                ConnectionEditorView(draft: details.draft, type: details.type) {
                    withAnimation(.easeInOut(duration: 0.2)) { self.details = nil }
                }
            } else {
                picker
            }
        }
        .animation(.easeInOut(duration: 0.2), value: details == nil)
        #if DEBUG
        .onAppear {
            let args = CommandLine.arguments
            if let index = args.firstIndex(of: "--new-connection-type"), args.indices.contains(index + 1),
               let type = ConnectionCatalog.type(id: args[index + 1]) {
                selection = type
                next()
            }
        }
        #endif
    }

    private var picker: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 222)
            Divider()
            VStack(spacing: 0) {
                Text("New Connection")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(height: 38)
                HStack {
                    Text("Select a connection type:").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    modeButton("square.grid.2x2", isOn: !listMode) { listMode = false }
                    modeButton("list.bullet", isOn: listMode) { listMode = true }
                    HStack(spacing: 5) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search", text: $search).textFieldStyle(.plain)
                    }
                    .font(.system(size: 13))
                    .padding(.horizontal, 9)
                    .frame(width: 200, height: 26)
                    .glassBackground(in: Capsule())
                    .padding(.leading, 8)
                }
                .padding(.horizontal, 30)
                .padding(.bottom, 8)

                if listMode { list } else { grid }

                Divider()
                footer
            }
        }
        .frame(width: 900, height: 700)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Text("Connection Filter").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                    .padding(.bottom, 2)
                ForEach(ConnectionFamily.allCases) { family in
                    filterRow(isOn: familyFilter.contains(family), title: family.displayName) {
                        ConnectionTypeIcon(type: ConnectionCatalog.engines.first { $0.family == family }!, size: 16)
                    } toggle: {
                        if familyFilter.contains(family) { familyFilter.remove(family) } else { familyFilter.insert(family) }
                    }
                }
                Text("Vendor Filter").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                    .padding(.top, 34)
                    .padding(.bottom, 2)
                ForEach(ConnectionVendor.allCases) { vendor in
                    filterRow(isOn: vendorFilter.contains(vendor), title: vendor.displayName) {
                        VendorMark(vendor: vendor, size: 16)
                    } toggle: {
                        if vendorFilter.contains(vendor) { vendorFilter.remove(vendor) } else { vendorFilter.insert(vendor) }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 44)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(VisualEffectBackground(material: .sidebar))
    }

    private func filterRow<Icon: View>(isOn: Bool, title: String, @ViewBuilder icon: () -> Icon, toggle: @escaping () -> Void) -> some View {
        Button(action: toggle) {
            HStack(spacing: 7) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 15))
                    .foregroundStyle(isOn ? Color.accentColor : Color.secondary.opacity(0.6))
                icon()
                Text(title).font(.system(size: 13))
                Spacer(minLength: 0)
            }
            .frame(height: 21)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func modeButton(_ symbol: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(symbol == "list.bullet" ? "List" : "Icons")
    }

    // MARK: Grid

    private let columns = [GridItem(.adaptive(minimum: 112, maximum: 124), spacing: 8, alignment: .top)]

    private var grid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if isFiltering {
                    tiles(ConnectionCatalog.all.filter(matches))
                    if !ConnectionCatalog.all.contains(where: matches) {
                        Text("No connection types match.").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 40)
                    }
                } else {
                    if !recents.isEmpty {
                        sectionTitle("Recents")
                        tiles(recents)
                    }
                    sectionTitle("All")
                    tiles(ConnectionCatalog.engines)
                    Divider().padding(.vertical, 12)
                    tiles(ConnectionCatalog.cloudServices)
                }
            }
            .padding(.horizontal, 30)
            .padding(.bottom, 20)
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 6)
    }

    private func tiles(_ types: [ConnectionType]) -> some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
            ForEach(types) { type in
                TypeTile(type: type, isSelected: selection == type)
                    .onTapGesture(count: 2) {
                        selection = type
                        next()
                    }
                    .simultaneousGesture(TapGesture().onEnded { selection = type })
            }
        }
    }

    // MARK: List

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                if isFiltering {
                    ForEach(ConnectionCatalog.all.filter(matches)) { listRow($0, indent: 0) }
                } else {
                    if !recents.isEmpty {
                        sectionTitle("Recents").padding(.bottom, 4)
                        ForEach(recents) { listRow($0, indent: 0) }
                        Spacer().frame(height: 14)
                    }
                    sectionTitle("All").padding(.bottom, 4)
                    ForEach(ConnectionCatalog.engines) { listRow($0, indent: 0) }
                    ForEach(ConnectionCatalog.listGroups, id: \.name) { group in
                        let isExpanded = expandedGroups.contains(group.name)
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                if isExpanded { expandedGroups.remove(group.name) } else { expandedGroups.insert(group.name) }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9, weight: .bold))
                                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 10)
                                if let vendor = group.types.first?.vendor {
                                    VendorMark(vendor: vendor, size: 16)
                                } else if let first = group.types.first {
                                    ConnectionTypeIcon(type: first, size: 16)
                                }
                                Text(group.name).font(.system(size: 13))
                                Spacer()
                            }
                            .frame(height: 24)
                            .padding(.leading, -4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if isExpanded {
                            ForEach(group.types) { listRow($0, indent: 22) }
                        }
                    }
                }
            }
            .padding(.horizontal, 30)
            .padding(.bottom, 20)
        }
    }

    private func listRow(_ type: ConnectionType, indent: CGFloat) -> some View {
        let isSelected = selection == type
        return HStack(spacing: 7) {
            ConnectionTypeIcon(type: type, size: 17)
            Text(type.name).font(.system(size: 13))
            if !type.isSupported {
                Text("Soon").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
            }
            Spacer()
        }
        .foregroundStyle(isSelected ? .white : .primary)
        .opacity(type.isSupported || isSelected ? 1 : 0.55)
        .padding(.leading, 8 + indent)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 5).fill(isSelected ? Color.accentColor : .clear))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            selection = type
            next()
        }
        .simultaneousGesture(TapGesture().onEnded { selection = type })
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Button("New Connection with URI") { showingURI = true }
                .popover(isPresented: $showingURI, arrowEdge: .top) { uriPopover }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Next") { next() }
                .keyboardShortcut(.defaultAction)
                .disabled(selection?.isSupported != true)
                .help(selection.map { $0.isSupported ? "Set up \($0.name)" : "\($0.name) isn't supported yet" } ?? "Choose a connection type")
        }
        .padding(.horizontal, 20)
        .frame(height: 50)
    }

    private var uriPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("New Connection with URI").font(.headline)
            TextField("postgresql://user:password@host:5432/database", text: $uriText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .frame(width: 420)
                .onSubmit(openURI)
            Text("Supports postgresql://, mysql://, mariadb:// and sqlite:///path. Add ?sslmode=require for SSL.")
                .font(.caption).foregroundStyle(.secondary)
            if let uriError {
                Label(uriError, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Continue", action: openURI).keyboardShortcut(.defaultAction).disabled(uriText.isEmpty)
            }
        }
        .padding()
    }

    private func openURI() {
        do {
            let parsed = try ConnectionURI.parse(uriText)
            showingURI = false
            uriError = nil
            let type = ConnectionCatalog.engines.first { $0.driver == parsed.config.kind }
            withAnimation(.easeInOut(duration: 0.2)) {
                details = (ConnectionDraft(config: parsed.config, password: parsed.password ?? "", isNew: true), type)
            }
        } catch {
            uriError = error.localizedDescription
        }
    }

    private func next() {
        guard let type = selection, let driver = type.driver else { return }
        var recent = UserDefaults.standard.stringArray(forKey: "recentConnectionTypes") ?? []
        recent.removeAll { $0 == type.id }
        recent.insert(type.id, at: 0)
        UserDefaults.standard.set(Array(recent.prefix(5)), forKey: "recentConnectionTypes")

        var config = ConnectionConfig(kind: driver, port: type.port ?? driver.defaultPort, tls: type.isEngine ? .prefer : type.tls)
        // Hosted services never live on localhost; leave the host for the user's endpoint.
        if type.vendor != nil || type.listGroup != nil { config.host = "" }
        if type.id == "mongodb-atlas" { config.mongo = MongoOptions(srv: true); config.tls = .verifyFull }
        if case .group(let group) = app.navSelection { config.group = group }
        withAnimation(.easeInOut(duration: 0.2)) {
            details = (ConnectionDraft(config: config, password: "", isNew: true), type)
        }
    }
}

/// One tile of the grid: icon, name, and a "Soon" badge for types without a driver yet.
private struct TypeTile: View {
    let type: ConnectionType
    let isSelected: Bool
    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 7) {
            ConnectionTypeIcon(type: type, size: 50)
                .overlay(alignment: .topTrailing) {
                    if !type.isSupported {
                        Text("Soon")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4).padding(.vertical, 1.5)
                            .background(Capsule().fill(Color.black.opacity(0.55)))
                            .offset(x: 10, y: -5)
                    }
                }
            Text(type.name)
                .font(.system(size: 12))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .foregroundStyle(isSelected ? .white : .primary)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(isSelected ? Color.accentColor : .clear))
        }
        .frame(width: 112)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10).fill(isSelected ? Color.primary.opacity(0.10) : (isHovering ? Color.primary.opacity(0.05) : .clear)))
        .opacity(type.isSupported || isSelected ? 1 : 0.5)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .help(type.isSupported ? type.name : "\(type.name) — coming soon")
    }
}

/// Small mark for a vendor in the filter list: their color with a short white name.
struct VendorMark: View {
    let vendor: ConnectionVendor
    var size: CGFloat = 16

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
            .fill(LinearGradient(colors: [vendor.sidebarColor.opacity(0.85), vendor.sidebarColor], startPoint: .top, endPoint: .bottom))
            .overlay(
                Text(vendor.mark)
                    .font(.system(size: size * (vendor.mark.count > 2 ? 0.36 : 0.46), weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.5)
            )
            .frame(width: size, height: size)
    }
}
