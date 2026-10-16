import BunnyGridCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            AISettings()
                .tabItem { Label("AI Assistant", systemImage: "sparkle") }
        }
        .frame(width: 520)
    }
}

private struct GeneralSettings: View {
    @AppStorage("appearance") private var appearance = AppearancePreference.system.rawValue

    var body: some View {
        Form {
            Picker("Appearance", selection: $appearance) {
                ForEach(AppearancePreference.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            Text("Light matches Navicat's default look; System follows macOS.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }
}

private struct AISettings: View {
    @Environment(AppModel.self) private var app
    @State private var key = ""
    @State private var saved = false

    var body: some View {
        @Bindable var assistant = app.assistant
        Form {
            Section {
                SecureField("Anthropic API key", text: $key, prompt: Text("sk-ant-…"))
                HStack {
                    Button("Save") {
                        assistant.setAPIKey(key)
                        saved = true
                    }
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Remove", role: .destructive) {
                        assistant.setAPIKey("")
                        key = ""
                        saved = false
                    }
                    .disabled(assistant.storedAPIKey.isEmpty)
                    Spacer()
                    if saved { Label("Saved to Keychain", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                }
                Text(ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]?.isEmpty == false && assistant.storedAPIKey.isEmpty
                     ? "Using ANTHROPIC_API_KEY from the environment."
                     : "Create a key at console.anthropic.com. It is stored in your login Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Claude API")
            }
            Section("Model") {
                Picker("Default model", selection: $assistant.model) {
                    ForEach(ClaudeModel.allCases) { Text("\($0.displayName) (\($0.rawValue))").tag($0) }
                }
                Text("Requests to Opus, Sonnet and Fable fall back to another model automatically if a safety classifier declines them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
        .onAppear { key = assistant.storedAPIKey }
    }
}
