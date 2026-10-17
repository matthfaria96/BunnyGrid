import AppKit
import BunnyGridCore
import SwiftUI

/// The connection form, laid out like Navicat's: Connection Profiles on the left, the type in the title,
/// General / Advanced / SSL / SSH / Remarks tabs, the app → database diagram, and URI · Test · Cancel · Back · OK.
struct ConnectionEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var config: ConnectionConfig
    @State private var password: String
    /// SSH password or key passphrase, and SSL client key passphrase (Keychain only).
    @State private var sshSecret: String
    @State private var sslKeyPassphrase: String
    /// Bumped to re-read the remembered SSH host key after a test or Forget Host Key.
    @State private var hostKeyRevision = 0
    @State private var testState: TestState = .idle
    @State private var tab: Tab = .general
    @State private var showProfiles = true
    @State private var showingURI = false
    @State private var newFile = false
    /// Databases tab: the selected attached file (SQLite), the server's databases once listed, and listing state.
    @State private var selectedAttachment: AttachedDatabase.ID?
    @State private var serverDatabases: [String] = []
    @State private var isListingDatabases = false
    @State private var databasesError: String?
    private let isNew: Bool
    /// Set when coming from the New Connection picker: the chosen type, and how to go back to it.
    private let type: ConnectionType?
    private let onBack: (() -> Void)?

    enum TestState: Equatable {
        case idle
        case testing
        case success(String)
        case failure(String)
    }

    enum Tab: String, CaseIterable, Identifiable {
        case general = "General", advanced = "Advanced", databases = "Databases", ssl = "SSL", ssh = "SSH", http = "HTTP", remarks = "Remarks"
        var id: Self { self }
    }

    init(draft: ConnectionDraft, type: ConnectionType? = nil, onBack: (() -> Void)? = nil) {
        _config = State(initialValue: draft.config)
        _password = State(initialValue: draft.password)
        _sshSecret = State(initialValue: draft.sshSecret)
        _sslKeyPassphrase = State(initialValue: draft.sslKeyPassphrase)
        isNew = draft.isNew
        self.type = type
        self.onBack = onBack
    }

    private var typeName: String { type?.name ?? config.kind.displayName }
    /// Navicat: "New Connection (SQLite)", or "Name — Edit Connection (SQLite)".
    private var title: String {
        isNew || config.name.isEmpty ? "\(isNew ? "New" : "Edit") Connection (\(typeName))" : "\(config.name) — Edit Connection (\(typeName))"
    }
    /// No HTTP tab: Navicat's HTTP tunnel needs its own server-side tunnel script, which BunnyGrid doesn't have.
    private var tabs: [Tab] {
        config.kind.isFileBased ? [.general, .advanced, .databases, .remarks] : Tab.allCases.filter { $0 != .http }
    }

    var body: some View {
        HStack(spacing: 0) {
            if showProfiles {
                profiles
                    .frame(width: 200)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                Divider()
            }
            VStack(spacing: 0) {
                header
                Divider()
                ScrollView {
                    Group {
                        switch tab {
                        case .general: general
                        case .advanced: advanced
                        case .ssl: ssl
                        case .ssh: ssh
                        case .databases: databasesTab
                        case .http: httpTab
                        case .remarks: remarks
                        }
                    }
                    .padding(.horizontal, 40)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity)
                }
                Divider()
                footer
            }
            // Exactly the room left by the profiles sidebar: a wide row in any tab can no longer make the editor
            // wider than the sheet (which pushed the whole sheet, sidebar included, past its left edge).
            .frame(width: showProfiles ? 900 - 201 : 900)
            .clipped()
        }
        .frame(width: 900, height: 700)
        .animation(.easeInOut(duration: 0.2), value: showProfiles)
        #if DEBUG
        .onAppear {
            if let name = UserDefaults.standard.string(forKey: "connectionTab"),
               let match = Tab.allCases.first(where: { $0.rawValue.lowercased() == name.lowercased() }) {
                tab = match
            }
            if CommandLine.arguments.contains("--test-connection") { test() }
        }
        #endif
    }

    // MARK: Sidebar

    private var profiles: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Connection Profiles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "plus.circle")
                    .foregroundStyle(.tertiary)
                    .help("More connection profiles aren't supported yet")
            }
            .lineLimit(1)
            .padding(.top, 44)
            .padding(.horizontal, 14)
            HStack(spacing: 6) {
                Text("Main Profile").font(.system(size: 13))
                Text("(Active)").font(.system(size: 13)).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.1)))
            .padding(.horizontal, 10)
            Spacer()
        }
        // Never wider than the sidebar (it was overflowing and clipping "Connection Profiles" on the left).
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .background(VisualEffectBackground(material: .sidebar, blending: .behindWindow))
    }

    // MARK: Header and tabs

    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 7) {
                if let type {
                    ConnectionTypeIcon(type: type, size: 20)
                } else {
                    DatabaseBadge(kind: config.kind, size: 20)
                }
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            }
            HStack(spacing: 4) {
                ForEach(tabs) { item in
                    Button { tab = item } label: {
                        Text(item.rawValue)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(tab == item ? Color.white : Color.primary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 5).fill(tab == item ? Color.accentColor.opacity(0.55) : .clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    // MARK: General

    private var general: some View {
        VStack(spacing: 24) {
            ConnectionDiagram(kind: config.kind, type: type)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 10) {
                row("Connection Name") {
                    TextField("", text: $config.name, prompt: Text(type?.name ?? config.kind.displayName))
                        .accessibilityIdentifier("connection.name")
                }
                if config.kind.isFileBased { fileRows } else { serverRows }
            }
            .textFieldStyle(.roundedBorder)
            .frame(width: 440)
        }
    }

    @ViewBuilder
    private var fileRows: some View {
        row("Type") {
            Picker("", selection: $newFile) {
                Text("Existing Database File").tag(false)
                Text("New SQLite 3").tag(true)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        }
        row("Database File") {
            HStack(spacing: 4) {
                let prompt: String = newFile ? "Where to create the file" : "~/data/app.sqlite"
                TextField("", text: $config.filePath, prompt: Text(prompt))
                Button("…") {
                    if newFile { createFile() } else { chooseFile() }
                }
                .help(newFile ? "Choose where to create the database" : "Choose a database file")
            }
        }
    }

    @ViewBuilder
    private var serverRows: some View {
        row("Host") {
            TextField("", text: $config.host, prompt: Text(type?.vendor?.hostHint ?? "localhost"))
                .accessibilityIdentifier("connection.host")
                .disabled(usesSocket)
                .help(usesSocket ? "Ignored: the connection uses the socket file set in the Advanced tab." : "")
        }
        row("Port") {
            TextField("", value: $config.port, format: .number.grouping(.never)).frame(width: 90)
                .disabled(usesSocket && config.kind != .postgresql)
                .accessibilityIdentifier("connection.port")
        }
        if config.kind == .sqlserver {
            row("Authentication") {
                VStack(alignment: .leading, spacing: 4) {
                    Picker("", selection: Binding(get: { config.windowsAuthentication ?? false }, set: { config.windowsAuthentication = $0 ? true : nil })) {
                        Text("SQL Server Authentication").tag(false)
                        Text("Windows Authentication (NTLM)").tag(true)
                    }
                    .labelsHidden().frame(width: 240)
                    Text(config.windowsAuthentication == true
                         ? "User Name as DOMAIN\\user with its Windows password (NTLMv2; Kerberos isn't used)."
                         : "Microsoft Entra sign-in isn't supported yet.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        if config.kind.isDocumentStore { MongoConnectionRows(config: $config) }
        if config.kind == .redis { RedisSentinelRows(config: $config) }
        row("User Name") { TextField("", text: $config.username, prompt: config.kind == .sqlserver ? Text("sa") : nil).accessibilityIdentifier("connection.user") }
        row("Password") { SecureField("", text: $password).accessibilityIdentifier("connection.password") }
        row(config.kind.connectsPerDatabase ? "Initial Database" : "Default Database") {
            TextField("", text: $config.database, prompt: Text(config.kind.serverDatabase ?? (config.kind == .redis ? "0 (database index)" : "Optional")))
                .accessibilityIdentifier("connection.database")
        }
    }

    // MARK: Advanced

    private var advanced: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 12) {
            row("Settings Location") {
                Text(AppModel.dataDirectory.appending(path: "connections.json").path)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
            }
            row("") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Auto connect", isOn: Binding(get: { config.autoConnect ?? false }, set: { config.autoConnect = $0 }))
                    Toggle("Read-only connection", isOn: $config.readOnly)
                        .help("Blocks INSERT, UPDATE, DELETE and DDL from BunnyGrid.")
                }
            }
            if !config.kind.isFileBased && config.kind != .sqlserver {
                row("") {
                    Toggle("Use socket file", isOn: Binding(
                        get: { config.socketPath != nil },
                        set: { config.socketPath = $0 ? (config.socketPath ?? defaultSocketPath) : nil }
                    ))
                }
                if config.socketPath != nil {
                    row("Socket File") {
                        VStack(alignment: .leading, spacing: 4) {
                            fileField(Binding(get: { config.socketPath ?? "" }, set: { config.socketPath = $0 }), prompt: defaultSocketPath, directories: config.kind == .postgresql)
                            Text(config.kind == .postgresql
                                 ? "The socket's directory (e.g. /tmp) or the .s.PGSQL file. Host is ignored; Port picks the file. SSL doesn't apply."
                                 : "The server's socket file (e.g. /tmp/mysql.sock). Host and Port are ignored; SSL doesn't apply.")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            row("Initial Queries") {
                VStack(alignment: .leading, spacing: 4) {
                    TextEditor(text: Binding(get: { config.initialQueries ?? "" }, set: { config.initialQueries = $0.isEmpty ? nil : $0 }))
                        .font(.system(size: 12, design: .monospaced))
                        .frame(height: 120)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .textBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor)))
                    Text("Run on every new connection, e.g. SET search_path TO app, public;")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 520)
    }

    // MARK: SSL

    private var ssl: some View {
        let files = Binding(get: { config.ssl ?? SSLFiles() }, set: { config.ssl = $0.isEmpty ? nil : $0 })
        return Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 12) {
            row("") {
                Toggle("Use SSL", isOn: Binding(get: { config.tls != .disable }, set: { config.tls = $0 ? .require : .disable }))
            }
            row("SSL Mode") {
                Picker("", selection: $config.tls) {
                    Text("Prefer (try SSL, fall back to plain)").tag(TLSMode.prefer)
                    Text("Require (encrypt, don't check the certificate)").tag(TLSMode.require)
                    Text("Verify CA (check the certificate chain)").tag(TLSMode.verifyCA)
                    Text("Verify Full (chain and host name)").tag(TLSMode.verifyFull)
                    Text("Disabled").tag(TLSMode.disable)
                }
                .labelsHidden()
                .frame(width: 330)
            }
            Group {
                row("Client Key") { fileField(files.clientKeyPath, prompt: "client-key.pem") }
                row("Client Key Passphrase") {
                    SecureField("", text: $sslKeyPassphrase, prompt: Text("Only for an encrypted key"))
                }
                row("Client Certificate") { fileField(files.clientCertificatePath, prompt: "client-cert.pem") }
                row(config.kind == .postgresql ? "Root Certificate" : "CA Certificate") {
                    fileField(files.caCertificatePath, prompt: "System trusted certificates")
                }
            }
            .disabled(config.tls == .disable)
            row("") {
                Text(sslHint)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 400, alignment: .leading)
            }
        }
        .frame(width: 560)
    }

    private var sslHint: String {
        var lines = ["Cloud services usually require SSL. Verify CA and Verify Full check the server certificate against the CA certificate above, or against the system's trusted certificates when it is empty. Through an SSH tunnel the host name checked is still the Host in General."]
        lines.append("Client certificate and key (PEM) are for servers that log users in by certificate. The key's passphrase is kept in the Keychain.")
        if usesSocket { lines.append("This connection uses a socket file (Advanced tab), so SSL is not used.") }
        return lines.joined(separator: "\n\n")
    }

    // MARK: SSH

    private var sshBinding: Binding<SSHTunnelConfig> {
        Binding(get: { config.ssh ?? SSHTunnelConfig() }, set: { config.ssh = $0 })
    }

    private var ssh: some View {
        let tunnel = sshBinding
        return Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 12) {
            row("") {
                Toggle("Use SSH tunnel", isOn: tunnel.enabled)
            }
            Group {
                row("Host") { TextField("", text: tunnel.host, prompt: Text("bastion.example.com")) }
                row("Port") {
                    TextField("", value: tunnel.port, format: .number.grouping(.never)).frame(width: 90)
                }
                row("User Name") { TextField("", text: tunnel.username) }
                row("Authentication Method") {
                    Picker("", selection: tunnel.authMethod) {
                        ForEach(SSHAuthMethod.allCases) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                }
                if tunnel.wrappedValue.authMethod == .password {
                    row("Password") { SecureField("", text: $sshSecret) }
                } else {
                    row("Private Key") { fileField(tunnel.privateKeyPath, prompt: "~/.ssh/id_ed25519", startIn: "~/.ssh") }
                    row("Passphrase") { SecureField("", text: $sshSecret, prompt: Text("Only for an encrypted key")) }
                }
                row("Host Key") { hostKeyRow(tunnel.wrappedValue) }
            }
            .disabled(!tunnel.wrappedValue.enabled)
            row("") {
                Text(sshHint)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 400, alignment: .leading)
            }
        }
        .frame(width: 560)
    }

    private var sshHint: String {
        var text = "BunnyGrid forwards a local port through the SSH server to Host and Port in General, as the SSH server sees them (often localhost). Keys: ed25519 or ECDSA (OpenSSH or PEM); RSA keys only work where the server still accepts ssh-rsa signatures. Passwords and passphrases are kept in the Keychain."
        if usesSocket { text += "\n\nA socket file (Advanced tab) can't be used through the tunnel." }
        return text
    }

    @ViewBuilder
    private func hostKeyRow(_ tunnel: SSHTunnelConfig) -> some View {
        let _ = hostKeyRevision
        if let key = KnownHostsStore().key(forHost: tunnel.host.trimmingCharacters(in: .whitespaces), port: tunnel.port), !tunnel.host.isEmpty {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(key.typeName) \(key.fingerprint)")
                        .font(.system(size: 11.5, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("Trusted since \(key.firstSeen.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button("Forget Host Key") {
                    KnownHostsStore().forget(host: tunnel.host.trimmingCharacters(in: .whitespaces), port: tunnel.port)
                    hostKeyRevision += 1
                }
                .help("Trust whatever key the server presents next time, e.g. after it was reinstalled.")
            }
            .frame(width: 400, alignment: .leading)
        } else {
            Text("Not seen yet. The key the server presents on the first connection is remembered; a different key later blocks the connection.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 400, alignment: .leading)
        }
    }

    // MARK: Files

    private var usesSocket: Bool { config.activeSocketPath != nil }

    private var defaultSocketPath: String {
        config.kind == .postgresql ? "/tmp" : config.kind == .redis ? "/tmp/redis.sock" : "/tmp/mysql.sock"
    }

    /// A path field with a "…" button that opens a file panel.
    private func fileField(_ path: Binding<String>, prompt: String, directories: Bool = false, startIn: String? = nil) -> some View {
        HStack(spacing: 4) {
            TextField("", text: path, prompt: Text(prompt))
            Button("…") {
                let panel = NSOpenPanel()
                panel.canChooseFiles = true
                panel.canChooseDirectories = directories
                panel.showsHiddenFiles = true
                let current = (path.wrappedValue as NSString).expandingTildeInPath
                if !current.isEmpty {
                    panel.directoryURL = URL(fileURLWithPath: current).deletingLastPathComponent()
                } else if let startIn {
                    panel.directoryURL = URL(fileURLWithPath: (startIn as NSString).expandingTildeInPath)
                }
                if panel.runModal() == .OK, let url = panel.url { path.wrappedValue = url.path }
            }
        }
    }

    // MARK: Databases

    /// SQLite: the files ATTACHed beside main. Servers: which databases the navigator lists.
    private var databasesTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !config.kind.isFileBased {
                HStack {
                    Toggle("Show all databases", isOn: Binding(
                        get: { (config.visibleDatabases ?? []).isEmpty },
                        set: { all in config.visibleDatabases = all ? nil : (serverDatabases.isEmpty ? [config.database].filter { !$0.isEmpty } : serverDatabases) }
                    ))
                    .toggleStyle(.checkbox)
                    Spacer()
                    if isListingDatabases { ProgressView().controlSize(.small) }
                    Button("List Databases") { listServerDatabases() }
                        .disabled(isListingDatabases)
                        .help("Connect with these settings and read the server's databases")
                }
                if let databasesError {
                    Text(databasesError).font(.caption).foregroundStyle(.red).lineLimit(3)
                }
            }
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Text(config.kind.isFileBased ? "Database" : "Show").frame(width: config.kind.isFileBased ? 150 : 60, alignment: .leading)
                    Divider().frame(height: 14)
                    Text(config.kind.isFileBased ? "File" : "Database").padding(.leading, 6).frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(size: 11.5, weight: .semibold))
                .padding(.horizontal, 10)
                .frame(height: 28)
                Divider()
                ScrollView {
                    VStack(spacing: 0) {
                        if config.kind.isFileBased {
                            mainDatabaseRow
                            ForEach(config.attachedDatabases ?? []) { database in attachedRow(database) }
                        } else {
                            ForEach(shownServerDatabases, id: \.self) { name in serverDatabaseRow(name) }
                        }
                    }
                }
                .frame(height: 360)
                .background(Color(nsColor: .textBackgroundColor))
            }
            .overlay(Rectangle().strokeBorder(Color(nsColor: .separatorColor)))
            if config.kind.isFileBased {
                HStack(spacing: 4) {
                    ToolIconButton(systemImage: "plus", help: "Attach a Database File…", tint: .primary) { attachDatabaseFile() }
                    ToolIconButton(systemImage: "minus", help: "Remove the Selected Database", tint: .primary) {
                        config.attachedDatabases?.removeAll { $0.id == selectedAttachment }
                        selectedAttachment = nil
                    }
                    .disabled(selectedAttachment == nil)
                }
            } else if (config.visibleDatabases ?? []).isEmpty {
                Text("Every database of the server is listed in the navigator.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(width: 660)
    }

    private var mainDatabaseRow: some View {
        HStack(spacing: 0) {
            Text("main").frame(width: 150, alignment: .leading)
            Text(config.filePath.isEmpty ? "(in memory)" : config.filePath)
                .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).padding(.leading, 7)
            Spacer()
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .frame(height: 24)
    }

    private func attachedRow(_ database: AttachedDatabase) -> some View {
        let binding = Binding(
            get: { config.attachedDatabases?.first { $0.id == database.id }?.alias ?? "" },
            set: { alias in
                if let index = config.attachedDatabases?.firstIndex(where: { $0.id == database.id }) { config.attachedDatabases?[index].alias = alias }
            }
        )
        return HStack(spacing: 0) {
            TextField("", text: binding).textFieldStyle(.plain).frame(width: 150, alignment: .leading)
            Text(database.path).lineLimit(1).truncationMode(.middle).padding(.leading, 7)
            Spacer()
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(selectedAttachment == database.id ? Color.accentColor.opacity(0.18) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { selectedAttachment = database.id }
    }

    /// The server's databases (once listed), or the chosen ones.
    private var shownServerDatabases: [String] {
        let chosen = (config.database.isEmpty ? [] : [config.database]) + (config.visibleDatabases ?? []).filter { $0 != config.database }
        return serverDatabases.isEmpty ? chosen : serverDatabases + chosen.filter { !serverDatabases.contains($0) }
    }

    private func serverDatabaseRow(_ name: String) -> some View {
        let all = (config.visibleDatabases ?? []).isEmpty
        let isShown = all || config.visibleDatabases?.contains(name) == true || name == config.database
        return HStack(spacing: 0) {
            Toggle("", isOn: Binding(
                get: { isShown },
                set: { show in
                    var chosen = all ? shownServerDatabases : (config.visibleDatabases ?? [])
                    if show { if !chosen.contains(name) { chosen.append(name) } } else { chosen.removeAll { $0 == name } }
                    config.visibleDatabases = chosen
                }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
            .disabled(name == config.database)
            .frame(width: 60, alignment: .leading)
            Text(name).padding(.leading, 7)
            Spacer()
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .frame(height: 24)
        .help(name == config.database ? "The connection's own database is always shown" : "")
    }

    private func attachDatabaseFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        var list = config.attachedDatabases ?? []
        for url in panel.urls {
            list.append(AttachedDatabase(alias: AttachedDatabase.suggestedAlias(for: url.path, taken: list.map(\.alias)), path: url.path))
        }
        config.attachedDatabases = list
    }

    private func listServerDatabases() {
        isListingDatabases = true
        databasesError = nil
        let driver = model.makeDriver(for: config, secrets: secrets)
        Task {
            defer { isListingDatabases = false }
            do {
                try await driver.connect()
                serverDatabases = try await driver.listDatabases()
            } catch {
                databasesError = error.localizedDescription
            }
            await driver.disconnect()
        }
    }

    // HTTP tunnels (Navicat's tunnel scripts) aren't supported, so the HTTP tab isn't listed; this stays for reference.
    private var httpTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Use HTTP tunnel", isOn: .constant(false)).toggleStyle(.checkbox)
            HStack {
                Text("Tunnel URL:")
                TextField("", text: .constant("")).frame(width: 300)
            }
            .padding(.leading, 20)
            Toggle("Encode outgoing query with base64", isOn: .constant(false)).toggleStyle(.checkbox)
        }
        .disabled(true)
        .frame(width: 660, alignment: .leading)
        .help("HTTP tunnels aren't supported yet; use SSH instead.")
    }

    // MARK: Remarks

    private var remarks: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Remarks:")
            TextEditor(text: Binding(get: { config.remarks ?? "" }, set: { config.remarks = $0.isEmpty ? nil : $0 }))
                .font(.system(size: 13))
                .frame(height: 360)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor)))
            Text("Shown in the Info pane when the connection is selected.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(width: 560)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Button { showProfiles.toggle() } label: {
                Image(systemName: "sidebar.left").foregroundStyle(showProfiles ? Color.accentColor : .secondary)
            }
            .help(showProfiles ? "Hide Connection Profiles" : "Show Connection Profiles")
            Button("URI") { showingURI.toggle() }
                .popover(isPresented: $showingURI, arrowEdge: .top) {
                    URIPopover(config: $config, password: $password)
                }
            Button("Test Connection", action: test)
                .disabled(testState == .testing || !isValid)
            testStatus
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            if let onBack {
                Button("Back", action: onBack)
            }
            Button("OK") {
                if config.name.isEmpty { config.name = type.map { $0.isEngine ? config.displayName : $0.name } ?? config.displayName }
                model.save(config, secrets: secrets)
                if isNew { model.connect(config.id) }
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!isValid)
        }
        .controlSize(.large)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var testStatus: some View {
        switch testState {
        case .idle: EmptyView()
        case .testing: ProgressView().controlSize(.small)
        case .success(let version):
            Label("Connection Successful", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).lineLimit(1).help(version)
        case .failure(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red).lineLimit(2).help(message)
        }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        GridRow {
            Text(label.isEmpty ? "" : label + ":").gridColumnAlignment(.trailing)
            content()
        }
    }

    private var isValid: Bool {
        if config.kind.isFileBased { return !config.filePath.isEmpty }
        if let ssh = config.activeSSH, ssh.host.trimmingCharacters(in: .whitespaces).isEmpty || ssh.username.isEmpty || ssh.port <= 0 {
            return false
        }
        return usesSocket || (!config.host.isEmpty && config.port > 0)
    }

    private var secrets: ConnectionSecrets {
        ConnectionSecrets(password: password, sshSecret: sshSecret, sslKeyPassphrase: sslKeyPassphrase)
    }

    /// Connects like a real session would: through the SSH tunnel and with the SSL tab's settings.
    private func test() {
        testState = .testing
        let driver = model.makeDriver(for: config, secrets: secrets)
        let config = config
        Task {
            do {
                try await driver.connect()
                try await Session.runInitialQueries(config, on: driver)
                var detail = try await driver.serverVersion()
                await driver.disconnect()
                if let ssh = config.activeSSH,
                   let key = KnownHostsStore().key(forHost: ssh.host.trimmingCharacters(in: .whitespaces), port: ssh.port) {
                    detail += "\nSSH host key: \(key.typeName) \(key.fingerprint)"
                }
                hostKeyRevision += 1
                testState = .success(detail)
            } catch {
                await driver.disconnect()
                hostKeyRevision += 1
                testState = .failure(error.localizedDescription)
            }
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { config.filePath = url.path }
    }

    private func createFile() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "database.sqlite"
        if panel.runModal() == .OK, let url = panel.url { config.filePath = url.path }
    }
}

/// "BunnyGrid ─── Database": the app's icon linked to the engine, as in Navicat's form.
private struct ConnectionDiagram: View {
    let kind: DatabaseKind
    let type: ConnectionType?

    var body: some View {
        HStack(spacing: 14) {
            VStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 48, height: 48)
                Text("BunnyGrid").font(.system(size: 12, weight: .medium))
            }
            Rectangle()
                .fill(LinearGradient(colors: [.secondary.opacity(0.3), .secondary.opacity(0.7), .secondary.opacity(0.3)], startPoint: .leading, endPoint: .trailing))
                .frame(width: 110, height: 1.5)
                .padding(.bottom, 18)
            VStack(spacing: 6) {
                Group {
                    if let type { ConnectionTypeIcon(type: type, size: 44) } else { DatabaseBadge(kind: kind, size: 44) }
                }
                .frame(width: 48, height: 48)
                Text("Database").font(.system(size: 12, weight: .medium))
            }
        }
    }
}

/// The URI button: copy the connection as a URI, or paste one to fill the form.
private struct URIPopover: View {
    @Binding var config: ConnectionConfig
    @Binding var password: String
    @State private var pasted = ""
    @State private var error: String?
    @State private var includePassword = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Connection URI").font(.headline)
            HStack {
                Text(ConnectionURI.string(for: config, password: includePassword ? password : nil))
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(ConnectionURI.string(for: config, password: includePassword ? password : nil), forType: .string)
                }
            }
            if !config.kind.isFileBased {
                Toggle("Include password", isOn: $includePassword).font(.caption)
            }
            Divider()
            Text("Fill from a URI").font(.subheadline)
            HStack {
                TextField("postgresql://user:pass@host:5432/db", text: $pasted)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                Button("Apply") { apply() }.disabled(pasted.isEmpty)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .padding(16)
        .frame(width: 480)
    }

    private func apply() {
        do {
            let parsed = try ConnectionURI.parse(pasted)
            let name = config.name
            let id = config.id
            config = parsed.config
            config.id = id
            config.name = name
            if let parsedPassword = parsed.password { password = parsedPassword }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
