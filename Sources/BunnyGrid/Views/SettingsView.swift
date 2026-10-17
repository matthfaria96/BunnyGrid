import BunnyGridCore
import SwiftUI

struct SettingsView: View {
    @AppStorage("settingsTab") private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag("general")
            AISettings()
                .tabItem { Label("AI Assistant", systemImage: "sparkle") }
                .tag("ai")
        }
        .frame(width: 580)
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
    @AppStorage("showAIFeatures") private var showAIFeatures = true

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
                    RequestOptionsEditor(provider: provider)
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
            Section("AI Assistant UI") {
                Picker("Action for Enter key", selection: $assistant.enterSends) {
                    Text("Send Message").tag(true)
                    Text("New Line (⌘↩ sends)").tag(false)
                }
                Toggle("Enable Compare with Other Assistants", isOn: $assistant.compareEnabled)
                Toggle("Show AI features", isOn: $showAIFeatures)
                Text("Compare asks the other platform the same question and shows both answers side by side. Hiding AI features removes Ask AI, Fix with AI and the AI tab.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
        .frame(minHeight: 560)
        .onAppear {
            for provider in AIProvider.allCases { assistant.verifyIfNeeded(provider) }
        }
    }
}

/// Max Tokens, Effort and Instruction for one platform.
private struct RequestOptionsEditor: View {
    @Environment(AppModel.self) private var app
    let provider: AIProvider
    @State private var maxTokens = ""

    var body: some View {
        let assistant = app.assistant
        let options = Binding<AIRequestOptions>(
            get: { assistant.options(for: provider) },
            set: { assistant.requestOptions[provider] = $0 }
        )
        Group {
            HStack {
                Text("Max Tokens")
                Spacer()
                TextField("", text: $maxTokens, prompt: Text(provider == .claude ? "64000" : "Model limit"))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 110)
                    .onSubmit(commit)
                    .onChange(of: maxTokens) { _, _ in commit() }
            }
            Picker("Effort", selection: options.effort) {
                ForEach(AIEffort.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            VStack(alignment: .leading, spacing: 4) {
                Text("Instruction")
                TextEditor(text: options.instruction)
                    .font(.system(size: 12))
                    .frame(height: 54)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
                Text("Standing rules for every answer, e.g. “Reply in Portuguese” or “Always use explicit JOINs”. Effort trades speed for depth; current models don't take a temperature.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { maxTokens = assistant.options(for: provider).maxTokens.map(String.init) ?? "" }
    }

    private func commit() {
        var options = app.assistant.options(for: provider)
        let digits = maxTokens.filter(\.isNumber)
        options.maxTokens = Int(digits).flatMap { $0 > 0 ? min($0, 128_000) : nil }
        if options != app.assistant.options(for: provider) { app.assistant.requestOptions[provider] = options }
    }
}
