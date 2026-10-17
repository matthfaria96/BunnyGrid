import BunnyGridCore
import SwiftUI

/// Data Profiling: per-column statistics and the most frequent values.
struct DataProfilingView: View {
    @Environment(\.dismiss) private var dismiss
    let model: TableTabModel
    /// nil for a query result, whose rows are profiled in memory.
    let driver: (any DatabaseDriver)?
    let driverSchema: String?

    @State private var profiles: [ColumnProfile] = []
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "chart.bar.doc.horizontal").foregroundStyle(.green).font(.title2)
                VStack(alignment: .leading) {
                    Text("Data Profiling").font(.headline)
                    Text(model.isQueryResult
                         ? "\(model.page?.rows.count.formatted() ?? "0") rows of the query result \(model.location)"
                         : "\(model.object.qualifiedName) \(model.location)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if isLoading {
                    ProgressView().controlSize(.small)
                    Text("Profiling \(profiles.count + 1) of \(model.columns.count)…").font(.caption).foregroundStyle(.secondary)
                }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12, alignment: .top)], spacing: 12) {
                    ForEach(profiles) { profile in
                        ProfileCard(profile: profile)
                    }
                }
                .padding()
                .animation(.easeOut(duration: 0.2), value: profiles.count)
            }
            .background(Color(nsColor: .underPageBackgroundColor))
        }
        .frame(width: 760, height: 600)
        .task { await run() }
    }

    /// Profiles column by column so cards appear as they finish.
    private func run() async {
        isLoading = true
        defer { isLoading = false }
        guard let driver, !model.isQueryResult else {
            // A query result: the rows it holds, not the whole table.
            guard let page = model.page else { return }
            profiles = DataProfiler.profile(columns: page.columns, types: page.columns.map { model.columnTypes[$0] ?? "" }, rows: model.exportRows)
            return
        }
        for column in model.columns {
            guard !Task.isCancelled else { return }
            let result = await DataProfiler.profile(driver: driver, table: model.object.name, schema: driverSchema, columns: [column])
            profiles += result
        }
    }
}

private struct ProfileCard: View {
    let profile: ColumnProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: GridHeaderCell.symbolName(for: profile.type)).foregroundStyle(.secondary).font(.caption)
                Text(profile.name).font(.system(size: 13, weight: .semibold))
                Text(profile.type).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                stat("Records", profile.total.countText)
                stat("Null", "\(profile.nullCount.formatted()) (\(profile.nullRatio.formatted(.percent.precision(.fractionLength(0...1)))))")
                if let distinct = profile.distinct { stat("Distinct", distinct.countText) }
                if let minimum = profile.minimum { stat("Min", minimum) }
                if let maximum = profile.maximum { stat("Max", maximum) }
                if let average = profile.average { stat("Average", average) }
            }
            FillMeter(filled: 1 - profile.nullRatio)
            if !profile.topValues.isEmpty {
                Text("Most frequent").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                let largest = max(profile.topValues.map(\.count).max() ?? 1, 1)
                VStack(spacing: 4) {
                    ForEach(profile.topValues) { item in
                        HStack(spacing: 6) {
                            Text(item.value)
                                .font(.system(size: 11))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(width: 96, alignment: .leading)
                                .help(item.value)
                            GeometryReader { proxy in
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color(nsColor: NSColor(hex: AppOptions.shared.values.profilingColors.bar) ?? .controlAccentColor).gradient)
                                    .frame(width: max(3, proxy.size.width * Double(item.count) / Double(largest)))
                            }
                            .frame(height: 12)
                            Text(item.count.countText)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                }
            }
            if let note = profile.note {
                Text(note).font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
    }

    private func stat(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 11.5, design: .monospaced)).lineLimit(1).textSelection(.enabled)
        }
    }
}

/// How much of the column is filled (non-NULL): green, turning orange when mostly empty.
private struct FillMeter: View {
    let filled: Double

    var body: some View {
        HStack(spacing: 6) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(filled < 0.5 ? Color(nsColor: NSColor(hex: AppOptions.shared.values.profilingColors.spotlight) ?? .systemOrange) : Color(nsColor: NSColor(hex: AppOptions.shared.values.profilingColors.valid) ?? .systemGreen))
                        .frame(width: max(0, proxy.size.width * filled))
                }
            }
            .frame(height: 6)
            Text("\(filled.formatted(.percent.precision(.fractionLength(0...1)))) filled")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize()
        }
    }
}

/// Per-column masking rules for the open table.
struct DataMaskingPopover: View {
    @Bindable var model: TableTabModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Data Masking", systemImage: "theatermasks").font(.headline)
                Spacer()
                Button("Clear All") { model.masks = [:] }.disabled(model.masks.values.allSatisfy { $0 == .none })
            }
            Text("Masked fields show and export masked, and can't be edited. The database is not changed.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    ForEach(model.page?.columns ?? [], id: \.self) { column in
                        GridRow {
                            Text(column).lineLimit(1)
                            Picker("", selection: Binding(
                                get: { model.masks[column] ?? MaskRule.none },
                                set: { model.masks[column] = $0 == MaskRule.none ? nil : $0 }
                            )) {
                                ForEach(MaskRule.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .labelsHidden()
                            .frame(width: 190)
                        }
                    }
                }
            }
            .frame(maxHeight: 320)
        }
        .padding()
        .frame(width: 380)
    }
}
