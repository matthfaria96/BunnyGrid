import AppKit
import BunnyGridCore
import SwiftUI

/// The first-launch welcome sheet: Advanced (preselected) or Simple, each with a small drawing of its toolbar, and
/// the appearance, which applies as it is picked. ← → choose, Return continues. Shown once (AppModel.decideOnboarding);
/// later the avatar's Theme menu, Settings › General and View › Interface Mode change the same choices.
struct OnboardingView: View {
    @Environment(AppModel.self) private var app
    @AppStorage("appearance") private var appearance = AppearancePreference.system.rawValue
    @State private var choice: InterfaceMode = .advanced
    @FocusState private var focusedCard: InterfaceMode?

    /// Advanced first, as the default.
    private let modes: [InterfaceMode] = [.advanced, .simple]

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.top, 28)
                .padding(.bottom, 22)
            cards
                .padding(.horizontal, 32)
            appearanceRow
                .padding(.top, 22)
            Spacer(minLength: 16)
            Divider()
            footer
        }
        .frame(width: 680, height: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        .interactiveDismissDisabled()
        .onAppear {
            choice = AppOptions.shared.interfaceMode
            focusedCard = choice
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 88, height: 88)
                .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
                .accessibilityHidden(true)
            Text("Welcome to BunnyGrid")
                .font(.system(size: 24, weight: .semibold))
                .padding(.top, 2)
            Text("Choose how much of BunnyGrid you want to see. You can change it any time from your profile picture › Theme.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var cards: some View {
        HStack(spacing: 16) {
            ForEach(modes) { mode in
                ModeCard(mode: mode, isSelected: choice == mode, isFocused: focusedCard == mode) { select(mode) }
                    .focusable()
                    .focused($focusedCard, equals: mode)
                    .focusEffectDisabled()
            }
        }
        // Both cards as tall as the taller one.
        .fixedSize(horizontal: false, vertical: true)
        .onKeyPress(.leftArrow) { move(-1) }
        .onKeyPress(.rightArrow) { move(1) }
        .onKeyPress(.space) {
            if let focusedCard { select(focusedCard) }
            return .handled
        }
    }

    private var appearanceRow: some View {
        HStack(spacing: 12) {
            Text("Appearance").font(.system(size: 13))
            Picker("Appearance", selection: Binding(get: { AppearancePreference(rawValue: appearance) ?? .system }, set: { value in
                appearance = value.rawValue
                value.apply()
            })) {
                ForEach(AppearancePreference.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 230)
            .accessibilityIdentifier("onboarding.appearance")
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Label("Use ← → to choose and Return to continue", systemImage: "keyboard")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .labelStyle(.titleAndIcon)
            Spacer()
            Button("Continue", action: finish)
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                .frame(minWidth: 96)
                .accessibilityIdentifier("onboarding.continue")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color.primary.opacity(0.03))
    }

    private func select(_ mode: InterfaceMode) {
        withAnimation(.spring(duration: 0.3, bounce: 0.2)) { choice = mode }
        focusedCard = mode
    }

    private func move(_ offset: Int) -> KeyPress.Result {
        guard let index = modes.firstIndex(of: choice) else { return .ignored }
        let next = modes[min(max(index + offset, 0), modes.count - 1)]
        select(next)
        return .handled
    }

    private func finish() {
        AppOptions.shared.completeOnboarding(mode: choice)
        app.showingOnboarding = false
    }
}

/// One choice: a drawing of the window in that mode, its name and what it includes.
private struct ModeCard: View {
    let mode: InterfaceMode
    let isSelected: Bool
    let isFocused: Bool
    let select: () -> Void
    @State private var isHovering = false

    private var highlights: [(symbol: String, text: String)] {
        switch mode {
        case .advanced:
            [("point.3.connected.trianglepath.dotted", "Modeling, BI dashboards and automation"),
             ("arrow.triangle.2.circlepath", "Data transfer, sync, backups and users"),
             ("chart.bar.doc.horizontal", "Profiling, masking and data generation")]
        case .simple:
            [("tablecells", "Connect, browse and edit tables"),
             ("terminal", "SQL editor with explain and history"),
             ("sparkles", "Import, export and the AI Assistant")]
        }
    }

    private var tagline: String {
        switch mode {
        case .advanced: "Everything: modeling, BI, automation, sync…"
        case .simple: "Just the essentials: connect, browse, edit, query."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MiniWindow(mode: mode)
                .frame(height: 148)
                .padding(10)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(mode.title).font(.system(size: 15, weight: .semibold))
                    if mode == .advanced {
                        Text("Default")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(Color.primary.opacity(0.08)))
                    }
                    Spacer()
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 17))
                        .foregroundStyle(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                        .contentTransition(.symbolEffect(.replace))
                }
                Text(tagline)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(highlights, id: \.text) { item in
                        HStack(spacing: 7) {
                            Image(systemName: item.symbol)
                                .font(.system(size: 10.5))
                                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                                .frame(width: 15)
                            Text(item.text).font(.system(size: 11.5))
                        }
                    }
                }
                .padding(.top, 5)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(isSelected ? 0.14 : (isHovering ? 0.08 : 0.04)), radius: isSelected ? 10 : 5, y: isSelected ? 4 : 2)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(isHovering ? 0.2 : 0.12), lineWidth: isSelected ? 2 : 1)
        }
        // Keyboard focus: a soft outer ring, apart from the selection border.
        .overlay {
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(isFocused ? 0.35 : 0), lineWidth: 3)
                .padding(-4)
        }
        .scaleEffect(isHovering && !isSelected ? 1.01 : 1)
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .animation(.easeOut(duration: 0.15), value: isFocused)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture(perform: select)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(mode.title) mode")
        .accessibilityValue(tagline)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, select)
        .accessibilityIdentifier("onboarding.card.\(mode.rawValue)")
    }
}

/// A drawing of the main window in a mode: title bar, that mode's toolbar icons, tabs, navigator, grid and AI pane.
/// Built from the app's own toolbar icons, not a screenshot, so it follows light and dark.
struct MiniWindow: View {
    let mode: InterfaceMode

    private var icons: [String] {
        switch mode {
        case .advanced: ["connection", "new-query", "table", "view", "function", "user", "others", "query", "backup", "automation", "model", "bi"]
        case .simple: ["connection", "new-query", "table", "view", "query"]
        }
    }

    private var tabs: [String] {
        switch mode {
        case .advanced: ["Objects", "customers", "Model", "BI"]
        case .simple: ["Objects", "customers", "Query"]
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Title bar and toolbar.
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 4) {
                    ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18), Color(red: 0.16, green: 0.79, blue: 0.25)], id: \.self) {
                        Circle().fill($0).frame(width: 6, height: 6)
                    }
                    Spacer()
                }
                HStack(spacing: mode == .simple ? 11 : 4.5) {
                    ForEach(icons, id: \.self) { AppIcon(name: $0, size: mode == .simple ? 17 : 15.5) }
                    Spacer(minLength: 0)
                    Capsule().fill(Color.primary.opacity(0.1)).frame(width: 18, height: 10)
                    Circle().fill(LinearGradient(colors: [Color(white: 0.72), Color(white: 0.5)], startPoint: .top, endPoint: .bottom))
                        .frame(width: 11, height: 11)
                }
            }
            .padding(.horizontal, 7)
            .padding(.top, 6)
            .padding(.bottom, 5)
            .background(Color.primary.opacity(0.035))
            Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 0.5)
            HStack(spacing: 0) {
                navigator.frame(width: 52)
                Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 0.5)
                VStack(spacing: 0) {
                    tabBar
                    grid
                }
                Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 0.5)
                aiPane.frame(width: 40)
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5))
        .accessibilityHidden(true)
    }

    private var navigator: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array([0.8, 0.62, 0.7, 0.5, 0.66, 0.44].enumerated()), id: \.offset) { index, width in
                HStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 1).fill(index == 0 ? Color.blue.opacity(0.7) : Color.teal.opacity(0.55)).frame(width: 5, height: 5)
                    RoundedRectangle(cornerRadius: 1.5).fill(Color.primary.opacity(index == 2 ? 0.28 : 0.14)).frame(width: 36 * width, height: 3.5)
                }
                .padding(.leading, index == 0 ? 0 : 5)
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .background(Color.primary.opacity(0.03))
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(Array(tabs.enumerated()), id: \.offset) { index, title in
                Text(title)
                    .font(.system(size: 6.5, weight: .medium))
                    .foregroundStyle(index == 1 ? .primary : .secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 5)
                    .frame(height: 12)
                    .background(index == 1 ? Color(nsColor: .windowBackgroundColor) : .clear)
                    .overlay(alignment: .trailing) { Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 0.5) }
            }
            Spacer(minLength: 0)
        }
        .background(Color.primary.opacity(0.06))
    }

    private var grid: some View {
        VStack(spacing: 0) {
            ForEach(0..<7) { row in
                HStack(spacing: 0) {
                    ForEach(0..<4) { column in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.primary.opacity(row == 0 ? 0.22 : 0.1))
                            .frame(width: [14, 30, 22, 18][column], height: 3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 4)
                    }
                }
                .frame(height: 10)
                .background(row == 3 ? Color.accentColor.opacity(0.18) : (row % 3 == 0 && row > 0 ? Color.primary.opacity(0.03) : .clear))
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }

    private var aiPane: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Image(systemName: "sparkles").font(.system(size: 7)).foregroundStyle(Color.accentColor).frame(maxWidth: .infinity, alignment: .leading)
            RoundedRectangle(cornerRadius: 3).fill(Color.accentColor.opacity(0.35)).frame(width: 24, height: 8)
            RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.1)).frame(width: 30, height: 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
        }
        .padding(5)
        .background(Color.primary.opacity(0.02))
    }
}
