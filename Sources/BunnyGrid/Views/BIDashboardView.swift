import BunnyGridCore
import SwiftUI

enum BIDashboardLayout {
    static let rowHeight: CGFloat = 72
    static let gap: CGFloat = 12

    static func cellWidth(_ width: CGFloat) -> CGFloat {
        (width - gap * CGFloat(BIDashboard.columns - 1)) / CGFloat(BIDashboard.columns)
    }

    static func frame(_ item: BIDashboardItem, width: CGFloat) -> CGRect {
        let cell = cellWidth(width)
        return CGRect(x: CGFloat(item.x) * (cell + gap), y: CGFloat(item.y) * (rowHeight + gap),
                      width: CGFloat(item.width) * cell + CGFloat(item.width - 1) * gap,
                      height: CGFloat(item.height) * rowHeight + CGFloat(item.height - 1) * gap)
    }

    static func contentSize(_ board: BIDashboard, width: CGFloat) -> CGSize {
        let rows = board.items.map { $0.y + $0.height }.max() ?? 4
        return CGSize(width: width, height: CGFloat(rows) * (rowHeight + gap) - gap)
    }
}

/// A dashboard: interactive filters on top, charts on a 12-column grid. Drag a tile's title bar to move it and its
/// corner to resize; tiles snap to the grid with a spring.
struct BIDashboardView: View {
    let model: BIWorkspaceModel
    let dashboard: BIDashboard
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            GeometryReader { geo in
                ScrollView {
                    let width = max(geo.size.width - 40, 480)
                    BIDashboardCanvas(model: model, dashboard: dashboard, width: width, interactive: true)
                        .frame(width: width, height: max(BIDashboardLayout.contentSize(dashboard, width: width).height + 120, geo.size.height - 40),
                               alignment: .topLeading)
                        .padding(20)
                }
                .overlay {
                    if dashboard.items.isEmpty {
                        ContentUnavailableView("Empty Dashboard", systemImage: "rectangle.3.group",
                                               description: Text("Drag charts here from the sidebar, or use Add Chart."))
                    }
                }
            }
            .background(Color(nsColor: .underPageBackgroundColor))
            .overlay { if isTargeted { RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 2).padding(4) } }
            .dropDestination(for: String.self) { payloads, _ in
                let ids = payloads.compactMap { $0.hasPrefix("bi-chart:") ? UUID(uuidString: String($0.dropFirst(9))) : nil }
                withAnimation(.smooth) { ids.forEach { model.place($0, on: dashboard.id) } }
                return !ids.isEmpty
            } isTargeted: { isTargeted = $0 }
        }
        .task(id: dashboard.id) { model.refreshDashboard(dashboard.id) }
    }

    private var filterBar: some View {
        HStack(spacing: 6) {
            TextField("Dashboard", text: Binding(get: { dashboard.name }, set: { name in model.updateDashboard(dashboard.id) { $0.name = name } }))
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .semibold))
                .frame(maxWidth: 200)
            Divider().frame(height: 16)
            Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.secondary).font(.system(size: 11))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(Array(dashboard.filters.enumerated()), id: \.element.id) { i, filter in
                        BIFilterChip(model: model, filter: filter, fieldType: fieldType(filter.field)) { new in
                            model.updateDashboard(dashboard.id, refresh: true) { board in
                                if let new { board.filters[i] = new } else { board.filters.remove(at: i) }
                            }
                        }
                    }
                    Menu {
                        let fields = model.filterableFields(dashboard)
                        if fields.isEmpty { Text("Add charts first") }
                        ForEach(fields) { field in
                            Button(field.name) {
                                let numeric = field.type == .number
                                model.updateDashboard(dashboard.id) {
                                    $0.filters.append(BIFilter(field: field.name, op: numeric ? .greater : .isIn, values: [], numeric: numeric))
                                }
                            }
                        }
                    } label: {
                        Label("Add Filter", systemImage: "plus").font(.system(size: 11.5))
                    }
                    .menuStyle(.button).buttonStyle(.plain).fixedSize().foregroundStyle(.secondary)
                }
            }
            Spacer()
            Menu {
                ForEach(model.workspace.charts) { chart in
                    Button { withAnimation(.smooth) { model.place(chart.id, on: dashboard.id) } } label: { Label(chart.name, systemImage: chart.type.systemImage) }
                }
            } label: {
                ToolbarChip(title: "Add Chart", systemImage: "plus.rectangle.on.rectangle", tint: .blue, showsMenuIndicator: true)
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .disabled(model.workspace.charts.isEmpty)
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
    }

    private func fieldType(_ name: String) -> BIFieldType {
        model.workspace.sources.lazy.flatMap(\.fields).first { $0.name == name }?.type ?? .text
    }
}

struct BIDashboardCanvas: View {
    let model: BIWorkspaceModel
    let dashboard: BIDashboard
    let width: CGFloat
    let interactive: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(dashboard.items) { item in
                if let chart = model.workspace.chart(item.chartID) {
                    BIDashboardTile(model: model, dashboard: dashboard, item: item, chart: chart, width: width, interactive: interactive)
                }
            }
        }
        .frame(width: width, alignment: .topLeading)
    }
}

struct BIDashboardTile: View {
    let model: BIWorkspaceModel
    let dashboard: BIDashboard
    let item: BIDashboardItem
    let chart: BIChart
    let width: CGFloat
    let interactive: Bool
    @State private var move: CGSize = .zero
    @State private var resize: CGSize = .zero
    @State private var hovering = false

    var body: some View {
        let frame = BIDashboardLayout.frame(item, width: width)
        let active = move != .zero || resize != .zero
        BIChartCard(model: model, chart: chart, key: item.id, compact: true) {
            if interactive && hovering {
                Menu {
                    Button("Edit Chart") { model.selection = .chart(chart.id) }
                    Button("Refresh") { model.refreshDashboard(dashboard.id) }
                    Divider()
                    Button("Remove from Dashboard", role: .destructive) {
                        withAnimation(.smooth) { model.updateDashboard(dashboard.id) { $0.items.removeAll { $0.id == item.id } } }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            }
        }
        .overlay(alignment: .top) {
            // Move handle: the title strip.
            if interactive {
                Color.clear.frame(height: 30).contentShape(Rectangle()).padding(.trailing, 30)
                    .gesture(DragGesture(minimumDistance: 2)
                        .onChanged { move = $0.translation }
                        .onEnded { value in commit(dx: value.translation.width, dy: value.translation.height, dw: 0, dh: 0) })
                    .onTapGesture(count: 2) { model.selection = .chart(chart.id) }
                    .help("Drag to move · double-click to edit")
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if interactive && (hovering || resize != .zero) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(5)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 1)
                        .onChanged { resize = $0.translation }
                        .onEnded { value in commit(dx: 0, dy: 0, dw: value.translation.width, dh: value.translation.height) })
            }
        }
        .frame(width: max(frame.width + resize.width, 120), height: max(frame.height + resize.height, 80))
        .scaleEffect(move != .zero ? 1.015 : 1)
        .shadow(color: .black.opacity(active ? 0.18 : 0), radius: 10, y: 4)
        .offset(x: frame.minX + move.width, y: frame.minY + move.height)
        .zIndex(active ? 1 : 0)
        .onHover { hovering = $0 }
    }

    private func commit(dx: CGFloat, dy: CGFloat, dw: CGFloat, dh: CGFloat) {
        let colStep = BIDashboardLayout.cellWidth(width) + BIDashboardLayout.gap
        let rowStep = BIDashboardLayout.rowHeight + BIDashboardLayout.gap
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            model.updateDashboard(dashboard.id) { board in
                guard let i = board.items.firstIndex(where: { $0.id == item.id }) else { return }
                var it = board.items[i]
                it.width = min(max(it.width + Int((dw / colStep).rounded()), 2), BIDashboard.columns)
                it.height = max(it.height + Int((dh / rowStep).rounded()), 2)
                it.x = min(max(it.x + Int((dx / colStep).rounded()), 0), BIDashboard.columns - it.width)
                it.y = max(it.y + Int((dy / rowStep).rounded()), 0)
                board.items[i] = it
                // Push overlapped tiles down so nothing stacks.
                var changed = true, passes = 0
                while changed && passes < 200 {
                    passes += 1
                    changed = false
                    for j in board.items.indices where j != i {
                        let other = board.items[j]
                        if board.items.contains(where: { $0.id != other.id && $0.overlaps(x: other.x, y: other.y, width: other.width, height: other.height) && ($0.id == it.id || $0.y < other.y || ($0.y == other.y && $0.x < other.x)) }) {
                            if let blocker = board.items.first(where: { $0.id != other.id && $0.overlaps(x: other.x, y: other.y, width: other.width, height: other.height) && ($0.id == it.id || $0.y <= other.y) }) {
                                board.items[j].y = blocker.y + blocker.height
                                changed = true
                            }
                        }
                    }
                }
            }
            move = .zero
            resize = .zero
        }
    }
}
