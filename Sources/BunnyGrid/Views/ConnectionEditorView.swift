import AppKit
import BunnyGridCore
import SwiftUI

struct ConnectionEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var config: ConnectionConfig
    @State private var password: String
    @State private var testState: TestState = .idle
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

    init(draft: ConnectionDraft, type: ConnectionType? = nil, onBack: (() -> Void)? = nil) {
        _config = State(initialValue: draft.config)
        _password = State(initialValue: draft.password)
        isNew = draft.isNew
        self.type = type
        self.onBack = onBack
    }

    private var title: String {
        if let type { return "New Connection — \(type.name)" }
        return isNew ? "New Connection" : "Edit Connection"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if let type {
                    ConnectionTypeIcon(type: type, size: 34)
                } else {
                    DatabaseBadge(kind: config.kind, size: 34)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text(config.kind.displayName + (type.map { $0.isEngine ? "" : " protocol" } ?? ""))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 6)
            Form {
                Section {
                    TextField("Connection Name", text: $config.name, prompt: Text(type?.name ?? (config.displayName.isEmpty ? "Optional" : config.displayName)))
                    if type == nil {
                        Picker("Type", selection: $config.kind) {
                            ForEach(DatabaseKind.allCases) { Text($0.displayName).tag($0) }
                        }
                        .onChange(of: config.kind) { old, new in
                            if config.port == old.defaultPort ?? 0 { config.port = new.defaultPort ?? 0 }
                        }
                    }
                    TextField("Group", text: Binding(
                        get: { config.group ?? "" },
                        set: { config.group = $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
                    ), prompt: Text("None (folder in the navigator)"))
                    Picker("Color", selection: $config.color) {
                        ForEach(ConnectionColor.allCases) { color in
                            Text(color.rawValue.capitalized).tag(color)
                        }
                    }
                }

                if config.kind.isFileBased {
                    Section("Database File") {
                        HStack {
                            TextField("Path", text: $config.filePath, prompt: Text("~/data/app.sqlite"))
                            Button("Choose…", action: chooseFile)
                            Button("New…", action: createFile)
                        }
                    }
                } else {
                    Section("Server") {
                        TextField("Host", text: $config.host, prompt: Text(type?.vendor?.hostHint ?? "localhost"))
                        TextField("Port", value: $config.port, format: .number.grouping(.never))
                        TextField("User", text: $config.username)
                        SecureField("Password", text: $password)
                        TextField("Database", text: $config.database, prompt: Text("Optional"))
                        Picker("SSL", selection: $config.tls) {
                            ForEach(TLSMode.allCases) { Text($0.displayName).tag($0) }
                        }
                    }
                }

                Section {
                    Toggle("Read-only", isOn: $config.readOnly)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if let onBack {
                    Button("Back", action: onBack)
                }
                Button("Test Connection", action: test)
                    .disabled(testState == .testing)
                testStatus
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Save & Connect" : "Save") {
                    if config.name.isEmpty, let type, !type.isEngine { config.name = type.name }
                    model.save(config, password: password)
                    if isNew { model.connect(config.id) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
            .padding()
        }
        .frame(width: onBack == nil ? 520 : 900, height: onBack == nil ? 560 : 700)
    }

    @ViewBuilder
    private var testStatus: some View {
        switch testState {
        case .idle: EmptyView()
        case .testing: ProgressView().controlSize(.small)
        case .success(let version):
            Label(version, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).lineLimit(1).help(version)
        case .failure(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red).lineLimit(2).help(message)
        }
    }

    private var isValid: Bool {
        config.kind.isFileBased ? !config.filePath.isEmpty : !config.host.isEmpty && config.port > 0
    }

    private func test() {
        testState = .testing
        let driver = model.makeDriver(for: config, password: password)
        Task {
            do {
                try await driver.connect()
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
