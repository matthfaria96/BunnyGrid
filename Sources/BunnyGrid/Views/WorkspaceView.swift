import BunnyGridCore
import SwiftUI

/// The center pane: the tab bar (fixed "Objects" tab first) and the selected tab's content.
struct WorkspaceView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            // Options › Tabs › "Always show the tab bar": otherwise it appears once a tab is open.
            if AppOptions.shared.values.alwaysShowTabBar || !app.tabs.isEmpty {
                TabBar()
                Divider()
            }
            // Every tab stays alive so switching back keeps its scroll position, selection and editor state, each in
            // its own hosting view; only the selected one is shown (see `TabDeck`).
            TabDeck(app: app, tabs: app.tabs, selectedID: app.selectedTabID)
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

/// The tabs' contents, one `NSHostingView` per tab. Hidden tabs stay alive (state, scroll positions, undo) but
/// are hidden AppKit views: switching tabs shows one view and hides another instead of changing opacity, hit
/// testing and the enabled state of every tab in one SwiftUI tree (which re-evaluated both tabs' bodies and
/// their AppKit views on each switch). A hidden view gets no key equivalents, so a hidden tab's shortcuts don't fire.
/// A tab's view is made the first time it is shown.
private struct TabDeck: NSViewRepresentable {
    let app: AppModel
    let tabs: [WorkspaceTab]
    let selectedID: UUID?

    func makeNSView(context: Context) -> TabDeckView {
        let view = TabDeckView()
        view.clipsToBounds = true
        return view
    }

    func updateNSView(_ view: TabDeckView, context: Context) {
        let app = app
        view.show(selectedID, keeping: Set(tabs.map(\.id))) { id in
            if let id {
                guard let tab = tabs.first(where: { $0.id == id }) else { return nil }
                return AnyView(TabContent(tab: tab).environment(app))
            }
            return AnyView(ObjectsView().environment(app))
        }
    }
}

@MainActor
final class TabDeckView: NSView {
    private struct Key: Hashable { let id: UUID? }
    private var hosts: [Key: NSHostingView<AnyView>] = [:]
    private var visible: Key?
    /// The first responder each hidden tab had, given back when it is shown again.
    private var savedResponders: [Key: NSResponder] = [:]

    override var isFlipped: Bool { true }

    func show(_ id: UUID?, keeping open: Set<UUID>, make: (UUID?) -> AnyView?) {
        // Closed tabs.
        for key in hosts.keys where key.id.map({ !open.contains($0) }) ?? false {
            hosts.removeValue(forKey: key)?.removeFromSuperview()
            savedResponders[key] = nil
        }
        let key = Key(id: id)
        guard key != visible || hosts[key] == nil else { return }
        let window = self.window
        let oldHost = visible.flatMap { hosts[$0] }
        var hadFocus = false
        if let old = visible, let oldHost, let responder = window?.firstResponder as? NSView, responder.isDescendant(of: oldHost) {
            savedResponders[old] = responder
            hadFocus = true
        }
        visible = key
        let host: NSHostingView<AnyView>
        if let existing = hosts[key] {
            host = existing
        } else {
            guard let root = make(id) else { return }
            host = NSHostingView(rootView: root)
            // The deck owns the size: a tab's minimum width must not widen the pane.
            host.sizingOptions = []
            host.frame = bounds
            host.autoresizingMask = [.width, .height]
            addSubview(host)
            hosts[key] = host
        }
        if host.frame != bounds { host.frame = bounds }
        host.isHidden = false
        // One first-responder change: straight to what the tab had focused, or away from the hidden tab
        // (a hidden editor must not keep receiving keystrokes).
        if let responder = savedResponders.removeValue(forKey: key) as? NSView, responder.isDescendant(of: host) {
            window?.makeFirstResponder(responder)
        } else if hadFocus {
            window?.makeFirstResponder(nil)
        }
        oldHost?.isHidden = true
    }
}

private struct TabContent: View {
    let tab: WorkspaceTab

    var body: some View {
        switch tab {
        case .table(let model): TableTabView(model: model)
        case .query(let model): QueryTabView(model: model)
        case .design(let model): DesignTableView(model: model)
        case .model(let model): ModelTabView(model: model)
        case .redis(let model): RedisTabView(model: model)
        case .document(let tab): DocumentTabView(tab: tab)
        case .automation: AutomationView()
        }
    }
}

private struct TabBar: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                TabItem(title: "Objects", systemImage: nil, isSelected: app.selectedTabID == nil, closable: false,
                        hasUnsavedChanges: false, select: { app.selectedTabID = nil }, close: {})
                ForEach(app.tabs) { tab in
                    TabItem(
                        title: tab.title,
                        systemImage: tab.systemImage,
                        isSelected: tab.id == app.selectedTabID,
                        closable: true,
                        hasUnsavedChanges: tab.hasUnsavedChanges,
                        select: { app.selectedTabID = tab.id },
                        close: { app.requestClose(tab) }
                    )
                }
            }
        }
        .frame(height: 29)
        .background(Color.primary.opacity(0.07))
        .confirmationDialog(
            "Close “\(app.tabPendingClose?.title ?? "")” and discard its unsaved changes?",
            isPresented: Binding(get: { app.tabPendingClose != nil }, set: { if !$0 { app.tabPendingClose = nil } })
        ) {
            Button("Discard Changes", role: .destructive) {
                if let tab = app.tabPendingClose { app.closeTab(tab.id) }
                app.tabPendingClose = nil
            }
        }
    }
}

private struct TabItem: View {
    let title: String
    let systemImage: String?
    let isSelected: Bool
    let closable: Bool
    let hasUnsavedChanges: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 5) {
            if !closable { Spacer(minLength: 0) }
            if let systemImage {
                AppIcon(name: systemImage, size: 15)
            }
            Text(title)
                .lineLimit(1)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(isSelected ? .primary : .secondary)
            Spacer(minLength: 0)
            if closable {
                Button(action: close) {
                    if hasUnsavedChanges && !isHovering {
                        Circle().fill(.orange).frame(width: 7, height: 7)
                    } else {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .frame(width: 12)
                .opacity(isHovering || hasUnsavedChanges ? 1 : 0)
                .animation(.easeOut(duration: 0.12), value: isHovering)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 29)
        .frame(width: closable ? 220 : 92)
        .background(isSelected ? Color(nsColor: .windowBackgroundColor) : (isHovering ? Color.primary.opacity(0.05) : .clear))
        .overlay(alignment: .trailing) { Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1) }
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { isHovering = $0 }
        .help(title)
        .contextMenu {
            if closable { Button("Close Tab", action: close) }
        }
    }
}
