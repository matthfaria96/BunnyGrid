import BunnyGridCore
import SwiftUI

/// Data Generation: fills a table with realistic sample rows, one generator per field.
struct DataGenerationView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let target: ImportTarget

    @State private var columns: [BunnyGridCore.TableColumn] = []
    @State private var generators: [String: ValueGenerator] = [:]
    @State private var countText = "100"
    @State private var seed = UInt64.random(in: 1...UInt64(UInt32.max))
    @State private var isRunning = false
    @State private var result: String?
    @State private var error: String?

    private var count: Int { min(max(Int(countText) ?? 0, 0), 100_000) }

    private var plan: [(name: String, generator: ValueGenerator)] {
        columns.map { ($0.name, generators[$0.name] ?? .skip) }
    }

    private var types: [String: String] {
        Dictionary(columns.map { ($0.name, $0.dataType) }, uniquingKeysWith: { first, _ in first })
    }

    private var preview: [RowChange] {
        ValueGenerator.rows(count: 5, columns: plan, types: types, seed: seed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: "Data Generation", systemImage: "wand.and.stars",
                        subtitle: "Into \(target.object.qualifiedName) \(target.context.location(schema: target.object.schema))") {
                HStack(spacing: 6) {
                    Text("Records")
                    TextField("100", text: $countText).frame(width: 80).textFieldStyle(.roundedBorder)
                }
            }
            .padding()
            Divider()
            Table(columns) {
                TableColumn("Field") { column in
                    HStack {
                        if column.isPrimaryKey { Image(systemName: "key.fill").foregroundStyle(.yellow).font(.caption) }
                        Text(column.name)
                    }
                }
                TableColumn("Type") { Text($0.dataType).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary) }
                    .width(min: 90, ideal: 120)
                TableColumn("Generator") { column in
                    Picker("", selection: Binding(
                        get: { generators[column.name] ?? .skip },
                        set: { generators[column.name] = $0 }
                    )) {
                        ForEach(ValueGenerator.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                }
                .width(min: 160, ideal: 190)
            }
            .frame(minHeight: 180)
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Preview").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Button("Shuffle") { seed = UInt64.random(in: 1...UInt64(UInt32.max)) }.controlSize(.small)
                }
                ScrollView([.horizontal, .vertical]) {
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                        GridRow {
                            ForEach(plan.filter { $0.generator != .skip }, id: \.name) { Text($0.name).font(.system(size: 11, weight: .semibold)) }
                        }
                        ForEach(Array(preview.enumerated()), id: \.offset) { _, change in
                            if case .insert(let values) = change {
                                GridRow {
                                    ForEach(values, id: \.column) { value in
                                        Text(value.value.isNull ? "(NULL)" : value.value.displayString)
                                            .font(.system(size: 11))
                                            .foregroundStyle(value.value.isNull ? .tertiary : .primary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(height: 110)
            }
            .padding()
            if let result { Label(result, systemImage: "checkmark.circle.fill").foregroundStyle(.green).padding(.horizontal) }
            if let error { Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(.red).textSelection(.enabled).padding(.horizontal) }
            Divider()
            HStack {
                if isRunning { ProgressView().controlSize(.small); Text("Generating…").foregroundStyle(.secondary) }
                Spacer()
                Button(result == nil ? "Cancel" : "Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Generate \(count.countText) Records") { Task { await generate() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(count == 0 || isRunning || plan.allSatisfy { $0.generator == .skip })
            }
            .padding()
        }
        .frame(width: 640, height: 620)
        .task { await loadColumns() }
    }

    private var driverSchema: String? {
        switch target.context.kind {
        case .postgresql, .sqlserver: target.object.schema
        case .mysql, .mariadb, .mongodb: target.context.name
        case .sqlite: nil
        case .redis: nil
        }
    }

    private func loadColumns() async {
        columns = (try? await target.context.driver.listColumns(table: target.object.name, schema: driverSchema)) ?? []
        for column in columns { generators[column.name] = ValueGenerator.suggested(for: column) }
    }

    private func generate() async {
        isRunning = true
        error = nil
        result = nil
        defer { isRunning = false }
        let rows = ValueGenerator.rows(count: count, columns: plan, types: types, seed: seed)
        do {
            try await target.context.driver.applyChanges(rows, table: target.object.name, schema: driverSchema, columns: columns)
            result = "Generated \(rows.count.countText) records in \(target.object.name)."
            seed &+= 1
            for tab in app.tabs {
                if case .table(let model) = tab, model.object == target.object { model.requestReload() }
            }
        } catch {
            self.error = "Nothing was inserted: \(error.localizedDescription)"
        }
    }
}
