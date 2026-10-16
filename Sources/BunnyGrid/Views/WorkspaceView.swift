import BunnyGridCore
import SwiftUI

/// The center pane: the tab bar (fixed "Objects" tab first) and the selected tab's content.
struct WorkspaceView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            TabBar()
            Divider()
            // Every tab stays alive so switching back keeps its scroll position, selection and editor state.
            // Hidden tabs are disabled so their keyboard shortcuts (⌘↩, ⌘R…) don't fire.
            ZStack {
                ObjectsView()
                    .opacity(app.selectedTabID == nil ? 1 : 0)
                    .allowsHitTesting(app.selectedTabID == nil)
                    .disabled(app.selectedTabID != nil)
                ForEach(app.tabs) { tab in
                    let isActive = tab.id == app.selectedTabID
                    TabContent(tab: tab)
                        .opacity(isActive ? 1 : 0)
                        .allowsHitTesting(isActive)
                        .disabled(!isActive)
                        .accessibilityHidden(!isActive)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct TabContent: View {
    let tab: WorkspaceTab

    var body: some View {
        switch tab {
        case .table(let model): TableTabView(model: model)
        case .query(let model): QueryTabView(model: model)
        case .design(let model): DesignTableView(model: model)
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
        .frame(height: 30)
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
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.accentColor)
            }
            Text(title)
                .lineLimit(1)
                .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? .primary : .secondary)
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
                .opacity(isSelected || isHovering || hasUnsavedChanges ? 1 : 0)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .frame(maxWidth: 320)
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
