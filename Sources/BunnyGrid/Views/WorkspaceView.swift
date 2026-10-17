import BunnyGridCore
import SwiftUI

/// The center pane: the tab bar (fixed "Objects" tab first) and the selected tab's content. An AppKit container, not
/// a SwiftUI tree: the tab bar is a small hosting view on top and the tabs' hosting views sit in a `TabDeckView`
/// below it. Nested in one SwiftUI host, every layout pass inside a tab (each frame of a column resize or a scroll)
/// re-laid out the whole pane in SwiftUI.
@MainActor
final class WorkspaceViewController: NSViewController {
    private let app: AppModel
    private let deck = TabDeckView()
    private var tabBar: NSHostingView<AnyView>?
    private var tabBarHeight: CGFloat = 0

    init(app: AppModel) {
        self.app = app
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        let container = WorkspaceContainerView()
        container.layoutHandler = { [weak self] in self?.layoutPanes() }
        deck.clipsToBounds = true
        container.addSubview(deck)
        let bar = NSHostingView(rootView: AnyView(WorkspaceTabBar(controller: self).environment(app)))
        // The container owns the sizes.
        bar.sizingOptions = []
        container.addSubview(bar)
        tabBar = bar
        view = container
    }

    /// Called by the tab bar's SwiftUI view whenever the tabs, the selection or the tab bar's visibility change.
    fileprivate func update(tabs: [WorkspaceTab], selectedID: UUID?, showsTabBar: Bool) {
        let height: CGFloat = showsTabBar ? 30 : 0
        if height != tabBarHeight {
            tabBarHeight = height
            layoutPanes()
        }
        let app = app
        deck.show(selectedID, keeping: Set(tabs.map(\.id))) { id in
            if let id {
                guard let tab = tabs.first(where: { $0.id == id }) else { return nil }
                return AnyView(TabContent(tab: tab).environment(app))
            }
            return AnyView(ObjectsView().environment(app))
        }
    }

    private func layoutPanes() {
        let bounds = view.bounds
        tabBar?.frame = NSRect(x: 0, y: 0, width: bounds.width, height: tabBarHeight)
        tabBar?.isHidden = tabBarHeight == 0
        let deckFrame = NSRect(x: 0, y: tabBarHeight, width: bounds.width, height: max(bounds.height - tabBarHeight, 0))
        if deck.frame != deckFrame { deck.frame = deckFrame }
    }
}

private final class WorkspaceContainerView: NSView {
    var layoutHandler: (() -> Void)?
    override var isFlipped: Bool { true }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        layoutHandler?()
    }

    override func layout() {
        super.layout()
        layoutHandler?()
    }
}

/// The tab bar and its divider; it also hands the tab list and selection to the deck (`updateNSView` runs in the
/// same update as the tab bar, so a switch shows the new tab without waiting for another pass).
private struct WorkspaceTabBar: View {
    @Environment(AppModel.self) private var app
    let controller: WorkspaceViewController

    var body: some View {
        // Options › Tabs › "Always show the tab bar": otherwise it appears once a tab is open.
        let shows = AppOptions.shared.values.alwaysShowTabBar || !app.tabs.isEmpty
        VStack(spacing: 0) {
            if shows {
                TabBar()
                Divider()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background { DeckDriver(controller: controller, tabs: app.tabs, selectedID: app.selectedTabID, showsTabBar: shows) }
    }
}

private struct DeckDriver: NSViewRepresentable {
    let controller: WorkspaceViewController
    let tabs: [WorkspaceTab]
    let selectedID: UUID?
    let showsTabBar: Bool

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        controller.update(tabs: tabs, selectedID: selectedID, showsTabBar: showsTabBar)
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
                        hasUnsavedChanges: false, badge: nil, select: { app.selectedTabID = nil }, close: {})
                ForEach(app.tabs) { tab in
                    TabItem(
                        title: tab.title,
                        systemImage: tab.systemImage,
                        isSelected: tab.id == app.selectedTabID,
                        closable: true,
                        hasUnsavedChanges: tab.hasUnsavedChanges,
                        // A tab opened in Advanced stays open and usable in Simple, marked as such.
                        badge: tab.feature?.isAvailable == false ? "Advanced" : nil,
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
    /// A small capsule after the title ("Advanced" on tabs of features Simple mode hides).
    let badge: String?
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
            if let badge {
                Text(badge)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                    .fixedSize()
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                    .help("Opened in Advanced mode. It keeps working; switch to Advanced to open more.")
                    .accessibilityIdentifier("tab.badge")
            }
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
        .animation(.easeOut(duration: 0.2), value: badge)
        .contextMenu {
            if closable { Button("Close Tab", action: close) }
        }
    }
}
