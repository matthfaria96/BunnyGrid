import AppKit
import BunnyGridCore
import SwiftUI

extension AIProvider {
    /// The company's mark in its brand colour (Simple Icons, CC0; see Resources/Icons/brands/SOURCES.md).
    /// OpenAI and xAI asked Simple Icons to drop their logos, so they get a text tile like Oracle does.
    var brand: Brand {
        switch self {
        case .claude: .logo(slug: "claude", hex: 0xD97757)
        case .chatGPT: .monogram(short: "AI", long: "OpenAI", hex: 0x000000)
        case .gemini: .logo(slug: "googlegemini", hex: 0x8E75B2)
        case .grok: .monogram(short: "xAI", long: "Grok", hex: 0x000000)
        case .deepSeek: .logo(slug: "deepseek", hex: 0x5786FE)
        case .mistral: .logo(slug: "mistralai", hex: 0xFA520F)
        case .ollama: .logo(slug: "ollama", hex: 0x000000)
        case .lmStudio: .logo(slug: "lmstudio", hex: 0x000000)
        }
    }
}

/// An AI provider's brand mark: a plate from 22 pt up, the bare glyph below that.
struct ProviderIcon: View {
    let provider: AIProvider
    var size: CGFloat = 16

    var body: some View {
        BrandTile(brand: provider.brand, size: size, uniformPlates: true)
    }

    /// A fixed-size image for menu items, which ignore SwiftUI frames.
    @MainActor static func image(_ provider: AIProvider, size: CGFloat, dark: Bool) -> NSImage? {
        let renderer = ImageRenderer(content: BrandTile(brand: provider.brand, size: size, uniformPlates: true).environment(\.colorScheme, dark ? .dark : .light))
        renderer.scale = 2
        return renderer.nsImage
    }
}

/// The person's photo in a circle, or their initials when there is none.
struct ProfileAvatar: View {
    @Environment(AppModel.self) private var app
    var size: CGFloat = 30

    var body: some View {
        Group {
            if let photo = app.profile.photo {
                Image(nsImage: photo).resizable().interpolation(.high).scaledToFill()
            } else {
                ZStack {
                    LinearGradient(colors: [Color(white: 0.72), Color(white: 0.5)], startPoint: .top, endPoint: .bottom)
                    if app.profile.initials.isEmpty {
                        Image(systemName: "person.fill").font(.system(size: size * 0.5)).foregroundStyle(.white.opacity(0.92))
                    } else {
                        Text(app.profile.initials).font(.system(size: size * 0.4, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
    }
}

/// Avatar with the active AI platform's mark tucked into its lower-right edge.
struct ProfileAvatarWithPlatform: View {
    @Environment(AppModel.self) private var app
    var size: CGFloat = 30

    var body: some View {
        ProfileAvatar(size: size)
            .overlay(alignment: .bottomTrailing) {
                ProviderIcon(provider: app.assistant.provider, size: size * 0.5)
                    .background(Circle().fill(Color(nsColor: .windowBackgroundColor)).padding(-size * 0.05))
                    .offset(x: size * 0.12, y: size * 0.1)
                    .id(app.assistant.provider)
                    .transition(.scale.combined(with: .opacity))
            }
            .animation(.spring(duration: 0.35, bounce: 0.3), value: app.assistant.provider)
    }
}

/// The toolbar's account button: where the person picks which AI platform the assistant uses.
struct AccountBadge: View {
    @Environment(AppModel.self) private var app
    @State private var isHovering = false

    var body: some View {
        @Bindable var app = app
        Button { app.showingAccountMenu.toggle() } label: {
            ProfileAvatarWithPlatform(size: 26)
                .padding(3)
                .glassBackground(in: Circle(), interactive: true)
                .scaleEffect(isHovering ? 1.05 : 1)
                .animation(.easeOut(duration: 0.15), value: isHovering)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityIdentifier("toolbar.account")
        .help("\(app.profile.name) · AI: \(app.assistant.provider.displayName)")
        .popover(isPresented: $app.showingAccountMenu, arrowEdge: .bottom) {
            AIAccountPopover()
        }
    }
}

/// Profile, assistant switcher, key entry and model choice.
struct AIAccountPopover: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let assistant = app.assistant
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(16)
            Divider()
            VStack(spacing: 6) {
                ThemeRow()
                InterfaceRow()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("AI Assistant").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Menu {
                        ForEach(AIProvider.allCases) { provider in
                            Button {
                                let added = assistant.addAssistant(provider)
                                assistant.activate(added.id)
                            } label: {
                                if let icon = ProviderIcon.image(provider, size: 16, dark: NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua) {
                                    Label { Text(provider.menuTitle) } icon: { Image(nsImage: icon) }
                                } else {
                                    Text(provider.menuTitle)
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.accentColor)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Add Assistant")
                    .accessibilityIdentifier("account.addAssistant")
                }
                if !assistant.aiEnabled {
                    Toggle("Enable AI Assistant", isOn: Binding(get: { assistant.aiEnabled }, set: { assistant.aiEnabled = $0 }))
                        .font(.system(size: 12))
                } else if assistant.assistants.isEmpty {
                    Text("Click \"+\" to add an assistant: Claude, ChatGPT, Gemini, Grok, DeepSeek, Mistral, or a local model with Ollama or LM Studio.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                ForEach(assistant.aiEnabled ? assistant.assistants : []) { config in
                    AssistantRow(assistant: config)
                }
                if let active = assistant.active, !assistant.hasAPIKey(for: active) || isFailed(active) {
                    APIKeyEditor(assistant: active, compact: true)
                        .padding(.top, 2)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                if let active = assistant.active {
                    HStack {
                        Text("Model").font(.system(size: 12))
                        Spacer()
                        ModelMenu(assistant: active)
                    }
                    .padding(.top, 4)
                }
            }
            .padding(16)
            .animation(.easeInOut(duration: 0.2), value: assistant.activeAssistantID)
            .animation(.easeInOut(duration: 0.2), value: assistant.hasAPIKey)
            Divider()
            HStack {
                SettingsLink { Text("AI Settings…") }
                    .buttonStyle(.link)
                    .simultaneousGesture(TapGesture().onEnded { UserDefaults.standard.set("ai", forKey: "settingsTab") })
                Spacer()
                Button("Open Assistant") {
                    app.showAssistant = true
                    app.rightPane = .ai
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 330)
        .onAppear {
            for config in assistant.assistants { assistant.verifyIfNeeded(config) }
        }
    }

    private func isFailed(_ config: AIAssistantConfig) -> Bool {
        if case .failed = app.assistant.verification[config.id] { return true }
        return false
    }

    private var header: some View {
        HStack(spacing: 12) {
            Menu {
                Button("Choose Photo…") { app.profile.choosePhoto() }
                Button("Use macOS Account Picture") { app.profile.useAccountPicture() }
                    .disabled(!app.profile.hasCustomPhoto)
            } label: {
                ProfileAvatarWithPlatform(size: 52)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Change Photo")
            VStack(alignment: .leading, spacing: 2) {
                Text(app.profile.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                HStack(spacing: 4) {
                    ProviderIcon(provider: app.assistant.provider, size: 12)
                    Text(app.assistant.active.map { "\($0.name) · \(app.assistant.modelName(for: $0))" } ?? "No assistant")
                        .lineLimit(1)
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

/// "Theme" (System / Light / Dark) and "Interface" (Simple / Advanced): two rows, each with its own menu.
/// Settings › General and View › Interface Mode show the same choices.
private struct ThemeRow: View {
    @AppStorage("appearance") private var appearance = AppearancePreference.system.rawValue

    var body: some View {
        let current = AppearancePreference(rawValue: appearance) ?? .system
        AccountMenuRow(icon: "paintpalette", title: "Theme", id: "account.theme", help: "Appearance") {
            Picker("Theme", selection: Binding(get: { current }, set: { choice in
                appearance = choice.rawValue
                choice.apply()
            })) {
                ForEach(AppearancePreference.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(current.title)
        }
    }
}

private struct InterfaceRow: View {
    var body: some View {
        let options = AppOptions.shared
        AccountMenuRow(icon: "rectangle.3.group", title: "Interface", id: "account.interface", help: "Simple or Advanced interface") {
            Picker("Interface", selection: Binding(get: { options.interfaceMode }, set: { options.setInterfaceMode($0) })) {
                ForEach(InterfaceMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(options.interfaceMode.title)
        }
    }
}

/// Icon, title and a trailing pop-up menu showing the current choice.
private struct AccountMenuRow<Content: View, Label: View>: View {
    let icon: String
    let title: String
    let id: String
    let help: String
    @ViewBuilder var content: Content
    @ViewBuilder var label: Label

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(title).font(.system(size: 12))
            Spacer()
            Menu { content } label: { label.font(.system(size: 12)) }
                .menuStyle(.button)
                .fixedSize()
                .accessibilityIdentifier(id)
                .help(help)
        }
    }
}

/// One configured assistant with its connection status; click to make it the active one.
private struct AssistantRow: View {
    @Environment(AppModel.self) private var app
    let assistant: AIAssistantConfig
    @State private var isHovering = false

    var body: some View {
        let isActive = app.assistant.active?.id == assistant.id
        Button {
            app.assistant.activate(assistant.id)
        } label: {
            HStack(spacing: 10) {
                ProviderIcon(provider: assistant.provider, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(assistant.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    KeyStatusLabel(assistant: assistant)
                }
                Spacer()
                if isActive {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 16)).foregroundStyle(Color.accentColor)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background {
                if isActive {
                    Color.clear.glassBackground(in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else if isHovering {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06))
                }
            }
            .overlay {
                if isActive {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// "Connected", "Checking…", "Key not accepted" or "Not connected", after the provider's company name.
struct KeyStatusLabel: View {
    @Environment(AppModel.self) private var app
    let assistant: AIAssistantConfig

    var body: some View {
        let model = app.assistant
        let company = assistant.provider.company
        HStack(spacing: 4) {
            if !model.hasAPIKey(for: assistant) {
                Circle().fill(Color.secondary.opacity(0.5)).frame(width: 6, height: 6)
                Text("\(company) · Not connected")
            } else if assistant.provider.isLocal {
                switch model.verification[assistant.id] ?? .unknown {
                case .checking:
                    ProgressView().controlSize(.mini)
                    Text("On this Mac · Checking…")
                case .connected:
                    Circle().fill(Color.green).frame(width: 6, height: 6)
                    Text("On this Mac · Running")
                case .failed(let message):
                    Circle().fill(Color.red).frame(width: 6, height: 6)
                    Text("On this Mac · Not running").help(message)
                case .unknown:
                    Circle().fill(Color.secondary.opacity(0.5)).frame(width: 6, height: 6)
                    Text("On this Mac")
                }
            } else {
                switch model.verification[assistant.id] ?? .unknown {
                case .checking:
                    ProgressView().controlSize(.mini)
                    Text("\(company) · Checking…")
                case .connected:
                    Circle().fill(Color.green).frame(width: 6, height: 6)
                    Text("\(company) · Connected")
                case .failed(let message):
                    Circle().fill(Color.red).frame(width: 6, height: 6)
                    Text("\(company) · Key not accepted").help(message)
                case .unknown:
                    Circle().fill(Color.green.opacity(0.6)).frame(width: 6, height: 6)
                    Text("\(company) · \(model.usesEnvironmentKey(assistant) ? "Key from environment" : "API key saved")")
                }
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

/// The model picker for one assistant.
struct ModelMenu: View {
    @Environment(AppModel.self) private var app
    let assistant: AIAssistantConfig

    var body: some View {
        let model = app.assistant
        Menu {
            if model.models(for: assistant.provider).isEmpty {
                Text(assistant.provider.isLocal ? "No models loaded in \(assistant.provider.displayName)" : "Connect to list models")
            }
            ForEach(model.models(for: assistant.provider)) { option in
                Button {
                    model.setModel(option.id, for: assistant)
                } label: {
                    if assistant.model == option.id { Label(option.name, systemImage: "checkmark") } else { Text(option.name) }
                }
            }
        } label: {
            Text(model.modelName(for: assistant)).font(.system(size: 12))
        }
        .menuStyle(.button)
        .fixedSize()
    }
}

/// Paste, save and test an assistant's API key; stored in the login Keychain.
struct APIKeyEditor: View {
    @Environment(AppModel.self) private var app
    let assistant: AIAssistantConfig
    var compact = false
    @State private var key = ""

    var body: some View {
        let model = app.assistant
        let provider = assistant.provider
        if provider.isLocal {
            localServer(model: model, provider: provider)
        } else {
            keyField(model: model, provider: provider)
        }
    }

    /// Ollama and LM Studio take no key: say where the server is expected and offer to check again.
    private func localServer(model: AssistantModel, provider: AIProvider) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Runs on this Mac at \(assistant.apiHost)").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button("Check Again") { model.verify(assistant) }
            }
            if case .failed(let message) = model.verification[assistant.id] ?? .unknown {
                Text(message).font(.system(size: 11)).foregroundStyle(.red).lineLimit(3).textSelection(.enabled)
            }
            Link("Download \(provider.displayName)", destination: provider.keysURL).font(.system(size: 11))
        }
    }

    private func keyField(model: AssistantModel, provider: AIProvider) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                SecureField("\(provider.company) API key", text: $key, prompt: Text(provider.keyPlaceholder))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                Button(compact ? "Connect" : "Save", action: save)
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                if !compact {
                    Button("Remove", role: .destructive) {
                        model.setAPIKey("", for: assistant)
                        key = ""
                    }
                    .disabled(model.storedAPIKey(for: assistant).isEmpty)
                }
            }
            if case .failed(let message) = model.verification[assistant.id] ?? .unknown {
                Text(message).font(.system(size: 11)).foregroundStyle(.red).lineLimit(3).textSelection(.enabled)
            }
            HStack(spacing: 4) {
                Link("Get your \(provider.company) API key", destination: provider.keysURL)
                Text("· stored in your Keychain").foregroundStyle(.secondary)
            }
            .font(.system(size: 11))
        }
        .onAppear { if !compact { key = model.storedAPIKey(for: assistant) } }
        .onChange(of: assistant.id) { _, _ in if !compact { key = model.storedAPIKey(for: assistant) } }
    }

    private func save() {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        app.assistant.setAPIKey(trimmed, for: assistant)
        if compact { key = "" }
    }
}
