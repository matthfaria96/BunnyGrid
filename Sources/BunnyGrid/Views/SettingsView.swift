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

    var body: some View {
        @Bindable var assistant = app.assistant
        Form {
            Section {
                Picker("Platform", selection: $assistant.provider) {
                    ForEach(AIProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .pickerStyle(.segmented)
                Text("The assistant answers with the platform chosen here or from your profile picture in the toolbar. It uses your own API keys; ChatGPT Plus and Claude Pro subscriptions don't include API access.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(AIProvider.allCases) { provider in
                Section {
                    APIKeyEditor(provider: provider)
                    HStack {
                        Text("Model")
                        Spacer()
                        ModelMenu(provider: provider)
                    }
                    if provider == .claude {
                        Text("Requests to Opus, Sonnet and Fable fall back to another Claude model automatically if a safety classifier declines them.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Conversations are sent with store disabled, so OpenAI doesn't keep them as stored responses. Your account's other GPT models appear once the key is verified.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    HStack(spacing: 6) {
                        AppIcon(name: provider.iconName, size: 16)
                        Text("\(provider.displayName) (\(provider.company))")
                        Spacer()
                        KeyStatusLabel(provider: provider)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
        .onAppear {
            for provider in AIProvider.allCases { assistant.verifyIfNeeded(provider) }
        }
    }
}
