import BunnyGridCore
import CoreGraphics
import Foundation
import Observation

/// A Model tab (Navicat Modeling): the ER diagram reverse-engineered from one database or schema.
/// Card positions are saved per connection, database and schema, so the user's arrangement survives reopening.
@MainActor
@Observable
final class ModelTabModel: Identifiable {
    let id = UUID()
    let connectionID: UUID?
    let databaseName: String
    let schema: String?
    let location: String
    let kind: DatabaseKind
    @ObservationIgnored private let driver: any DatabaseDriver
    @ObservationIgnored private let driverSchema: String?
    @ObservationIgnored private let store: ERLayoutStore
    @ObservationIgnored private let storeKey: String

    private(set) var model: ERModel?
    private(set) var positions: [String: CGPoint] = [:]
    private(set) var isLoading = false
    private(set) var error: String?
    /// The selected table: its relationships and neighbors are highlighted.
    var selection: String?
    var zoom: CGFloat = 1
    /// Bumped to ask the canvas to fit the whole diagram in view.
    private(set) var fitRequest = 0
    var showingSQL = false

    static let zoomRange: ClosedRange<CGFloat> = 0.2...3

    init(context: DatabaseContext, schema: String?) {
        self.driver = context.driver
        self.connectionID = context.session?.id
        self.databaseName = context.name
        self.schema = context.usesSchemas ? schema : nil
        self.driverSchema = context.driverSchema(schema)
        self.location = context.location(schema: self.schema)
        self.kind = context.kind
        self.store = ERLayoutStore(fileURL: AppModel.dataDirectory.appending(path: "model-layouts.json"))
        self.storeKey = ERLayoutStore.key(connectionID: context.session?.id ?? UUID(), database: context.name, schema: self.schema)
    }

    /// "main", "dvdrental.public": what the model shows.
    var displayName: String { schema.map { "\(databaseName).\($0)" } ?? databaseName }

    var frames: [String: CGRect] {
        guard let model else { return [:] }
        return ERLayout.frames(model, positions: positions)
    }

    /// The canvas size: every card plus the margin, never smaller than a screenful.
    var canvasSize: CGSize {
        let bounds = ERLayout.bounds(frames.values)
        return CGSize(width: max(bounds.maxX + ERLayout.margin * 2, 800), height: max(bounds.maxY + ERLayout.margin * 2, 600))
    }

    /// Tables shown highlighted: the selection and the tables it is linked to.
    var highlighted: Set<String> {
        guard let selection, let model else { return [] }
        return model.neighbors(of: selection).union([selection])
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let model = try await ERModel.reverseEngineer(driver: driver, schema: driverSchema, displaySchema: schema)
            self.model = model
            let saved = store.positions(for: storeKey) ?? [:]
            positions = ERLayout.layout(model, keeping: saved)
            if positions != saved { savePositions() }
            if let selection, model.table(selection) == nil { self.selection = nil }
            error = nil
            fitRequest += 1
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Discards the manual arrangement and lays the diagram out again.
    func autoLayout() {
        guard let model else { return }
        positions = ERLayout.autoLayout(model)
        savePositions()
        fitRequest += 1
    }

    func zoomToFit() { fitRequest += 1 }

    func setZoom(_ value: CGFloat) {
        zoom = min(max(value, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
    }

    /// Moves a card while it is dragged; `savePositions()` runs when the drag ends.
    func move(_ tableID: String, to point: CGPoint) {
        positions[tableID] = CGPoint(x: max(0, point.x.rounded()), y: max(0, point.y.rounded()))
    }

    func savePositions() {
        try? store.save(positions, for: storeKey)
    }

    func generateSQL(for kind: DatabaseKind, selectedOnly: Bool, includeDrop: Bool) -> String {
        guard let model else { return "" }
        let tables: Set<String>? = selectedOnly ? selection.map { [$0] } : nil
        return model.generateSQL(for: kind, options: .init(tables: tables, includeDrop: includeDrop))
    }

    var summary: String {
        guard let model else { return isLoading ? "Reading the schema…" : "" }
        let tables = model.tables.count, relations = model.relationships.count
        return "\(tables) table\(tables == 1 ? "" : "s") | \(relations) relationship\(relations == 1 ? "" : "s") | Zoom: \(Int((zoom * 100).rounded()))%"
    }
}
