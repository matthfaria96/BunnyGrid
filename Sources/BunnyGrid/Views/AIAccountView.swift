import AppKit
import BunnyGridCore
import SwiftUI

extension AIProvider {
    var iconName: String {
        switch self {
        case .claude: "ai-claude"
        case .chatGPT: "ai-chatgpt"
        }
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
                AppIcon(name: app.assistant.provider.iconName, size: size * 0.5)
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
            ProfileAvatarWithPlatform(size: 30)
                .padding(3)
                .glassBackground(in: Circle(), interactive: true)
                .scaleEffect(isHovering ? 1.05 : 1)
                .animation(.easeOut(duration: 0.15), value: isHovering)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("\(app.profile.name) · AI: \(app.assistant.provider.displayName)")
        .popover(isPresented: $app.showingAccountMenu, arrowEdge: .bottom) {
            AIAccountPopover()
        }
    }
}

/// Profile, AI platform switcher, key entry and model choice.
struct AIAccountPopover: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let assistant = app.assistant
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(16)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("AI Platform").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                ForEach(AIProvider.allCases) { provider in
                    PlatformRow(provider: provider)
                }
                if !assistant.hasAPIKey || isFailed(assistant.provider) {
                    APIKeyEditor(provider: assistant.provider, compact: true)
                        .padding(.top, 2)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                HStack {
                    Text("Model").font(.system(size: 12))
                    Spacer()
                    ModelMenu(provider: assistant.provider)
                }
                .padding(.top, 4)
            }
            .padding(16)
            .animation(.easeInOut(duration: 0.2), value: assistant.provider)
            .animation(.easeInOut(duration: 0.2), value: assistant.hasAPIKey)
            Divider()
            HStack {
                SettingsLink { Text("AI Settings…") }
                    .buttonStyle(.link)
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
            for provider in AIProvider.allCases { assistant.verifyIfNeeded(provider) }
        }
    }

    private func isFailed(_ provider: AIProvider) -> Bool {
        if case .failed = app.assistant.verification[provider] { return true }
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
                    AppIcon(name: app.assistant.provider.iconName, size: 12)
                    Text("\(app.assistant.provider.displayName) · \(app.assistant.modelName(for: app.assistant.provider))")
                        .lineLimit(1)
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

/// One selectable AI platform with its connection status.
private struct PlatformRow: View {
    @Environment(AppModel.self) private var app
    let provider: AIProvider
    @State private var isHovering = false

    var body: some View {
        let isActive = app.assistant.provider == provider
        Button {
            app.assistant.provider = provider
            app.assistant.verifyIfNeeded(provider)
        } label: {
            HStack(spacing: 10) {
                AppIcon(name: provider.iconName, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(provider.displayName).font(.system(size: 13, weight: .semibold))
                    KeyStatusLabel(provider: provider)
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

/// "Connected", "Checking…", "API key rejected" or "Not connected", by the provider's company name.
struct KeyStatusLabel: View {
    @Environment(AppModel.self) private var app
    let provider: AIProvider

    var body: some View {
        let assistant = app.assistant
        HStack(spacing: 4) {
            if !assistant.hasAPIKey(for: provider) {
                Circle().fill(Color.secondary.opacity(0.5)).frame(width: 6, height: 6)
                Text("\(provider.company) · Not connected")
            } else {
                switch assistant.verification[provider] ?? .unknown {
                case .checking:
                    ProgressView().controlSize(.mini)
                    Text("\(provider.company) · Checking…")
                case .connected:
                    Circle().fill(Color.green).frame(width: 6, height: 6)
                    Text("\(provider.company) · Connected")
                case .failed(let message):
                    Circle().fill(Color.red).frame(width: 6, height: 6)
                    Text("\(provider.company) · Key not accepted").help(message)
                case .unknown:
                    Circle().fill(Color.green.opacity(0.6)).frame(width: 6, height: 6)
                    Text("\(provider.company) · \(assistant.usesEnvironmentKey(provider) ? "Key from environment" : "API key saved")")
                }
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

/// The model picker for one platform.
struct ModelMenu: View {
    @Environment(AppModel.self) private var app
    let provider: AIProvider

    var body: some View {
        let assistant = app.assistant
        Menu {
            ForEach(assistant.models(for: provider)) { model in
                Button {
                    assistant.select(provider, model: model.id)
                } label: {
                    if assistant.selectedModel(for: provider) == model.id { Label(model.name, systemImage: "checkmark") } else { Text(model.name) }
                }
            }
        } label: {
            Text(assistant.modelName(for: provider)).font(.system(size: 12))
        }
        .menuStyle(.button)
        .fixedSize()
    }
}

/// Paste, save and test an API key; stored in the login Keychain.
struct APIKeyEditor: View {
    @Environment(AppModel.self) private var app
    let provider: AIProvider
    var compact = false
    @State private var key = ""

    var body: some View {
        let assistant = app.assistant
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                SecureField("\(provider.company) API key", text: $key, prompt: Text(provider.keyPlaceholder))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                Button(compact ? "Connect" : "Save", action: save)
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                if !compact {
                    Button("Remove", role: .destructive) {
                        assistant.setAPIKey("", for: provider)
                        key = ""
                    }
                    .disabled(assistant.storedAPIKey(for: provider).isEmpty)
                }
            }
            if case .failed(let message) = assistant.verification[provider] ?? .unknown {
                Text(message).font(.system(size: 11)).foregroundStyle(.red).lineLimit(3).textSelection(.enabled)
            }
            HStack(spacing: 4) {
                Link("Get an \(provider.company) API key", destination: provider.keysURL)
                Text("· stored in your Keychain").foregroundStyle(.secondary)
            }
            .font(.system(size: 11))
        }
        .onAppear { if !compact { key = assistant.storedAPIKey(for: provider) } }
        .onChange(of: assistant.storedAPIKey(for: provider)) { _, stored in if !compact { key = stored } }
    }

    private func save() {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        app.assistant.setAPIKey(trimmed, for: provider)
        if compact { key = "" }
    }
}
