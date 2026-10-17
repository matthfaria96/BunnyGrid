import BunnyGridCore
import SwiftUI

/// Navicat's User manager: the server's users and roles, their privileges, and new / delete / set password.
struct UsersView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let session: Session
    @State private var users: [DatabaseUser] = []
    @State private var selection: DatabaseUser.ID?
    @State private var grants: QueryResult?
    @State private var error: String?
    @State private var creating = false
    @State private var draft = UserDraft()
    @State private var confirmDrop = false
    @State private var settingPassword = false
    @State private var newPassword = ""

    private var dialect: SQLDialect { session.driver.dialect }
    private var selected: DatabaseUser? { users.first { $0.id == selection } }
    private var isMySQL: Bool { session.config.kind == .mysql || session.config.kind == .mariadb }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Users — \(session.config.name)").font(.headline)
                Spacer()
                Button { draft = UserDraft(); creating = true } label: { Label("New User", systemImage: "plus") }
                Button { settingPassword = true } label: { Label("Password", systemImage: "key") }.disabled(selected == nil)
                Button(role: .destructive) { confirmDrop = true } label: { Label("Delete", systemImage: "minus") }.disabled(selected == nil)
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }.help("Refresh")
            }
            .padding(12)
            Divider()
            HSplitView {
                Table(users, selection: $selection) {
                    TableColumn("Name") { Text($0.name) }
                    TableColumn("Host") { Text($0.host ?? "—").foregroundStyle($0.host == nil ? .tertiary : .primary) }
                    TableColumn("Attributes") { Text($0.attributes.joined(separator: ", ")).foregroundStyle(.secondary) }
                }
                .frame(minWidth: 320)
                privileges.frame(minWidth: 280)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }.padding(12)
        }
        .frame(width: 760, height: 480)
        .task { await load() }
        .task(id: selection) { await loadGrants() }
        .sheet(isPresented: $creating) { newUserForm }
        .alert("Delete “\(selected?.name ?? "")”?", isPresented: $confirmDrop) {
            Button("Delete", role: .destructive) { if let user = selected { run([dialect.dropUser(user)]) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The user loses access to the server.") }
        .alert("New password for “\(selected?.name ?? "")”", isPresented: $settingPassword) {
            SecureField("Password", text: $newPassword)
            Button("Change") { if let user = selected { run([dialect.setPassword(user, to: newPassword)]) }; newPassword = "" }
            Button("Cancel", role: .cancel) { newPassword = "" }
        }
    }

    @ViewBuilder private var privileges: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Privileges").font(.subheadline.weight(.semibold))
            if let grants, !grants.rows.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(grants.rows.enumerated()), id: \.offset) { _, row in
                            Text(row.map(\.displayString).joined(separator: " — "))
                                .font(.system(size: 12, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text(selected == nil ? "Select a user." : "No table privileges.").foregroundStyle(.tertiary)
                Spacer()
            }
        }
        .padding(12)
    }

    private var newUserForm: some View {
        Form {
            TextField("Name", text: $draft.name)
            if isMySQL { TextField("Host", text: $draft.host) }
            SecureField("Password", text: $draft.password)
            if !isMySQL { Toggle("Can log in", isOn: $draft.canLogin) }
            Toggle("Superuser (all privileges)", isOn: $draft.superuser)
            Toggle("Can create databases", isOn: $draft.createDatabases)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { creating = false }
                Button("Create") {
                    do { run(try dialect.createUser(draft)); creating = false } catch { self.error = error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func load() async {
        guard let sql = dialect.listUsersSQL else { return }
        do {
            users = dialect.users(from: try await session.driver.executeStatement(sql))
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadGrants() async {
        grants = nil
        guard let user = selected, let sql = dialect.grantsSQL(user) else { return }
        grants = try? await session.driver.executeStatement(sql)
    }

    private func run(_ statements: [String]) {
        Task {
            do {
                for sql in statements { _ = try await session.driver.executeTimed(sql) }
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
            await load()
        }
    }
}
