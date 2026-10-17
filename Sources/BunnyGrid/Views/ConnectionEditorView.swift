import AppKit
import BunnyGridCore
import SwiftUI

/// The connection form, laid out like Navicat's: Connection Profiles on the left, the type in the title,
/// General / Advanced / SSL / Remarks tabs, the app → database diagram, and URI · Test · Cancel · Back · OK.
struct ConnectionEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var config: ConnectionConfig
    @State private var password: String
    @State private var testState: TestState = .idle
    @State private var tab: Tab = .general
    @State private var showProfiles = true
    @State private var showingURI = false
    @State private var newFile = false
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
        case general = "General", advanced = "Advanced", ssl = "SSL", remarks = "Remarks"
        var id: Self { self }
    }

    init(draft: ConnectionDraft, type: ConnectionType? = nil, onBack: (() -> Void)? = nil) {
        _config = State(initialValue: draft.config)
        _password = State(initialValue: draft.password)
        isNew = draft.isNew
        self.type = type
        self.onBack = onBack
    }

    private var typeName: String { type?.name ?? config.kind.displayName }
    private var title: String { "\(isNew ? "New" : "Edit") Connection (\(typeName))" }
    private var tabs: [Tab] { config.kind.isFileBased ? [.general, .advanced, .remarks] : Tab.allCases }

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
        }
        .frame(width: 900, height: 700)
        .animation(.easeInOut(duration: 0.2), value: showProfiles)
    }

    // MARK: Sidebar

    private var profiles: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Connection Profiles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 44)
                .padding(.horizontal, 16)
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
                            .background(RoundedRectangle(cornerRadius: 5).fill(tab == item ? Color.accentColor.opacity(0.85) : .clear))
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
        }
        row("Port") {
            TextField("", value: $config.port, format: .number.grouping(.never)).frame(width: 90)
        }
        row("User Name") { TextField("", text: $config.username) }
        row("Password") { SecureField("", text: $password) }
        row(config.kind == .postgresql ? "Initial Database" : "Default Database") {
            TextField("", text: $config.database, prompt: Text(config.kind == .postgresql ? "postgres" : "Optional"))
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
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 12) {
            row("") {
                Toggle("Use SSL", isOn: Binding(get: { config.tls != .disable }, set: { config.tls = $0 ? .require : .disable }))
            }
            row("SSL Mode") {
                Picker("", selection: $config.tls) {
                    Text("Prefer (try SSL, fall back to plain)").tag(TLSMode.prefer)
                    Text("Require").tag(TLSMode.require)
                    Text("Disabled").tag(TLSMode.disable)
                }
                .labelsHidden()
                .frame(width: 280)
            }
            row("") {
                Text("Cloud services usually require SSL. The server certificate is checked against the system's trusted certificates.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 360, alignment: .leading)
            }
        }
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
                model.save(config, password: password)
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
        config.kind.isFileBased ? !config.filePath.isEmpty : !config.host.isEmpty && config.port > 0
    }

    private func test() {
        testState = .testing
        let driver = model.makeDriver(for: config, password: password)
        let config = config
        Task {
            do {
                try await driver.connect()
                try await Session.runInitialQueries(config, on: driver)
                let version = try await driver.serverVersion()
                await driver.disconnect()
                testState = .success(version)
            } catch {
                await driver.disconnect()
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
