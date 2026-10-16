import BunnyGridCore
import SwiftUI

/// The center pane: the tab bar (fixed "Objects" tab first) and the selected tab's content.
struct WorkspaceView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            TabBar()
            Divider()
            Group {
                switch app.selectedTab {
                case .table(let model):
                    TableTabView(model: model).id(model.id)
                case .query(let model):
                    QueryTabView(model: model).id(model.id)
                case .design(let model):
                    DesignTableView(model: model).id(model.id)
                case nil:
                    ObjectsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct TabBar: View {
    @Environment(AppModel.self) private var app
    @State private var pendingClose: WorkspaceTab?

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
                        close: { requestClose(tab) }
                    )
                }
            }
        }
        .frame(height: 30)
        .background(Color(nsColor: .windowBackgroundColor))
        .confirmationDialog(
            "Close “\(pendingClose?.title ?? "")” and discard its unsaved changes?",
            isPresented: Binding(get: { pendingClose != nil }, set: { if !$0 { pendingClose = nil } })
        ) {
            Button("Discard Changes", role: .destructive) {
                if let tab = pendingClose { app.closeTab(tab.id) }
                pendingClose = nil
            }
        }
    }

    private func requestClose(_ tab: WorkspaceTab) {
        if tab.hasUnsavedChanges { pendingClose = tab } else { app.closeTab(tab.id) }
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
                .font(.system(size: 12.5))
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
        .background(isSelected ? Color(nsColor: .controlBackgroundColor) : (isHovering ? Color.primary.opacity(0.04) : .clear))
        .overlay(alignment: .top) {
            if isSelected { Rectangle().fill(Color.accentColor).frame(height: 2) }
        }
        .overlay(alignment: .trailing) { Divider() }
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { isHovering = $0 }
        .help(title)
        .contextMenu {
            if closable { Button("Close Tab", action: close) }
        }
    }
}
