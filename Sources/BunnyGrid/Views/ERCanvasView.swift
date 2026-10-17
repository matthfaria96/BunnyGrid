import AppKit
import BunnyGridCore
import SwiftUI

/// The ER diagram drawn by AppKit: relationship lines in the canvas's own `draw(_:)` (only the dirty part),
/// one layer-backed view per table card that draws once and is then just moved. Dragging a card moves one
/// view and redraws the strip of lines around its relationships, instead of re-rendering 200 SwiftUI cards.
/// Also rendered off screen for PNG and PDF export (`interactive = false`).
@MainActor
final class ERCanvasView: NSView {
    struct Callbacks {
        var select: (String?) -> Void = { _ in }
        var move: (String, CGPoint) -> Void = { _, _ in }
        var moveEnded: () -> Void = {}
        var open: (String) -> Void = { _ in }
        var menu: (String) -> NSMenu? = { _ in nil }
    }

    var callbacks = Callbacks()
    var interactive = true

    private(set) var diagram: ERModel?
    private var tablesByID: [String: ERTable] = [:]
    private(set) var frames: [String: CGRect] = [:]
    private var selection: String?
    private var highlighted: Set<String> = []
    private var cards: [String: ERCardView] = [:]
    /// Relationship indexes per table, and each relationship's route and the rectangle it covers.
    private var relationsByTable: [String: [Int]] = [:]
    private var routes: [[CGPoint]?] = []
    private var routeBounds: [CGRect] = []

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        // Lines are redrawn only in the rectangles invalidated by a move.
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Applies a new diagram, positions and selection, touching only what changed.
    func update(diagram: ERModel, frames newFrames: [String: CGRect], selection: String?, highlighted: Set<String>) {
        if self.diagram != diagram {
            setDiagram(diagram, frames: newFrames)
        } else {
            for (id, frame) in newFrames where frames[id] != frame {
                move(id, to: frame)
            }
        }
        if selection != self.selection || highlighted != self.highlighted {
            let wasSelected = self.selection
            self.selection = selection
            self.highlighted = highlighted
            for (id, card) in cards {
                card.setState(isSelected: selection == id,
                              isRelated: highlighted.contains(id) && selection != id,
                              isDimmed: selection != nil && !highlighted.contains(id))
            }
            // Active lines change colour and width; every other line's opacity depends on whether anything is selected.
            if (wasSelected == nil) != (selection == nil) {
                needsDisplay = true
            } else {
                for id in [wasSelected, selection].compactMap({ $0 }) {
                    for index in relationsByTable[id] ?? [] { setNeedsDisplay(routeBounds[index]) }
                }
            }
        }
    }

    private func setDiagram(_ diagram: ERModel, frames newFrames: [String: CGRect]) {
        self.diagram = diagram
        frames = newFrames
        tablesByID = Dictionary(diagram.tables.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        relationsByTable = [:]
        for (index, relation) in diagram.relationships.enumerated() {
            relationsByTable[relation.fromTable, default: []].append(index)
            if relation.toTable != relation.fromTable { relationsByTable[relation.toTable, default: []].append(index) }
        }
        routes = Array(repeating: nil, count: diagram.relationships.count)
        routeBounds = Array(repeating: .zero, count: diagram.relationships.count)
        for index in diagram.relationships.indices { reroute(index) }
        // Cards in table order (later tables on top, as before).
        var reused = cards
        cards = [:]
        var ordered: [ERCardView] = []
        for table in diagram.tables {
            guard let frame = newFrames[table.id], cards[table.id] == nil else { continue }
            let card = reused.removeValue(forKey: table.id) ?? ERCardView(tableID: table.id)
            card.canvas = self
            card.configure(table: table, cardFrame: frame)
            cards[table.id] = card
            ordered.append(card)
        }
        for card in reused.values { card.removeFromSuperview() }
        subviews = ordered
        selection = nil
        highlighted = []
        for card in ordered { card.setState(isSelected: false, isRelated: false, isDimmed: false) }
        needsDisplay = true
    }

    private func move(_ id: String, to frame: CGRect) {
        frames[id] = frame
        cards[id]?.setCardFrame(frame)
        for index in relationsByTable[id] ?? [] {
            setNeedsDisplay(routeBounds[index])
            reroute(index)
            setNeedsDisplay(routeBounds[index])
        }
    }

    private func reroute(_ index: Int) {
        guard let diagram else { return }
        let relation = diagram.relationships[index]
        guard let child = tablesByID[relation.fromTable], let parent = tablesByID[relation.toTable],
              let childFrame = frames[relation.fromTable], let parentFrame = frames[relation.toTable] else {
            routes[index] = nil
            routeBounds[index] = .zero
            return
        }
        let points = ERLayout.route(relation, child: child, at: childFrame, parent: parent, at: parentFrame)
        routes[index] = points
        let xs = points.map(\.x), ys = points.map(\.y)
        // The crow's feet and circles reach 22 pt along the line and 6 pt across it; line width on top.
        routeBounds[index] = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            .insetBy(dx: -26, dy: -26)
    }

    // MARK: - Lines

    override func draw(_ dirtyRect: NSRect) {
        guard let diagram, let context = NSGraphicsContext.current?.cgContext else { return }
        let plain = ERColors.resolved(.secondaryLabelColor, opacity: selection == nil ? 0.75 : 0.35)
        let accent = NSColor.controlAccentColor.cgColor
        context.setLineCap(.round)
        context.setLineJoin(.round)
        var active: [Int] = []
        // Plain lines first, the selection's on top.
        for index in diagram.relationships.indices where routeBounds[index].intersects(dirtyRect) {
            let relation = diagram.relationships[index]
            if selection != nil && (relation.fromTable == selection || relation.toTable == selection) {
                active.append(index)
                continue
            }
            stroke(index, relation, in: context, color: plain, width: 1.2)
        }
        for index in active { stroke(index, diagram.relationships[index], in: context, color: accent, width: 2) }
    }

    private func stroke(_ index: Int, _ relation: ERRelationship, in context: CGContext, color: CGColor, width: CGFloat) {
        guard let points = routes[index], points.count >= 2 else { return }
        context.setStrokeColor(color)
        context.setLineWidth(width)
        context.beginPath()
        context.addLines(between: points)
        ERLineEnds.child(context, at: points[0], toward: points[1], oneToOne: relation.isOneToOne)
        let count = points.count
        ERLineEnds.parent(context, at: points[count - 1], toward: points[count - 2], optional: relation.isOptional)
        context.strokePath()
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        if interactive { callbacks.select(nil) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        for card in cards.values { card.needsDisplay = true }
    }

    /// The whole diagram as a PNG (2x) or vector PDF, in light mode on white.
    static func export(_ diagram: ERModel, positions: [String: CGPoint], pdf: Bool) -> Data? {
        let frames = ERLayout.frames(diagram, positions: positions)
        let bounds = ERLayout.bounds(frames.values)
        let size = CGSize(width: bounds.maxX + ERLayout.margin, height: bounds.maxY + ERLayout.margin)
        let container = ERExportBackground(frame: CGRect(origin: .zero, size: size))
        container.appearance = NSAppearance(named: .aqua)
        let canvas = ERCanvasView(frame: container.bounds)
        canvas.interactive = false
        container.addSubview(canvas)
        var data: Data?
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            canvas.update(diagram: diagram, frames: frames, selection: nil, highlighted: [])
            if pdf {
                data = container.dataWithPDF(inside: container.bounds)
            } else if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
                rep.size = size
                container.cacheDisplay(in: container.bounds, to: rep)
                data = rep.representation(using: .png, properties: [:])
            }
        }
        return data
    }
}

/// White page behind an exported diagram.
private final class ERExportBackground: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        dirtyRect.fill()
    }
}

/// Crow's-foot ends: "many" (or "one" for 1:1 keys) at the child, "exactly one" (‖) or "zero or one" (o|,
/// nullable key) at the parent.
@MainActor
enum ERLineEnds {
    private typealias Direction = (dx: CGFloat, dy: CGFloat)

    private static func unit(_ from: CGPoint, _ to: CGPoint) -> Direction {
        let dx = to.x - from.x, dy = to.y - from.y
        let length = max((dx * dx + dy * dy).squareRoot(), 0.001)
        return (dx / length, dy / length)
    }

    private static func point(_ p: CGPoint, _ d: Direction, along: CGFloat, across: CGFloat = 0) -> CGPoint {
        CGPoint(x: p.x + d.dx * along - d.dy * across, y: p.y + d.dy * along + d.dx * across)
    }

    private static func bar(_ context: CGContext, _ p: CGPoint, _ d: Direction, at distance: CGFloat) {
        context.move(to: point(p, d, along: distance, across: -6))
        context.addLine(to: point(p, d, along: distance, across: 6))
    }

    private static func circle(_ context: CGContext, _ p: CGPoint, _ d: Direction, at distance: CGFloat) {
        let center = point(p, d, along: distance)
        context.addEllipse(in: CGRect(x: center.x - 3.5, y: center.y - 3.5, width: 7, height: 7))
    }

    static func child(_ context: CGContext, at p: CGPoint, toward next: CGPoint, oneToOne: Bool) {
        let d = unit(p, next)
        if oneToOne {
            bar(context, p, d, at: 8)
        } else {
            let joint = point(p, d, along: 12)
            for across in [-6.0, 0, 6] {
                context.move(to: joint)
                context.addLine(to: point(p, d, along: 0, across: across))
            }
        }
        circle(context, p, d, at: 18)
    }

    static func parent(_ context: CGContext, at p: CGPoint, toward previous: CGPoint, optional: Bool) {
        let d = unit(p, previous)
        bar(context, p, d, at: 7)
        if optional { circle(context, p, d, at: 16) } else { bar(context, p, d, at: 12) }
    }
}

@MainActor
enum ERColors {
    /// A dynamic color with its own alpha multiplied by `opacity` (SwiftUI's `Color(...).opacity`), for the current appearance.
    static func resolved(_ color: NSColor, opacity: CGFloat) -> CGColor {
        let base = color.usingColorSpace(.sRGB) ?? color
        return base.withAlphaComponent(base.alphaComponent * opacity).cgColor
    }
}

/// One table card: name header, then one row per column with key / foreign key symbols and the type.
/// Draws itself once (and again when its state or the appearance changes); moving it costs no drawing.
/// The view is larger than the card by `margin` so the shadow is part of its own drawing (and of exports).
@MainActor
final class ERCardView: NSView {
    static let margin: CGFloat = 14

    let tableID: String
    weak var canvas: ERCanvasView?
    private var table: ERTable?
    private var isSelected = false
    private var isRelated = false
    private var isDimmed = false
    private var dragOrigin: CGPoint?
    private var mouseDownPoint: CGPoint?

    init(tableID: String) {
        self.tableID = tableID
        super.init(frame: .zero)
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    private var cardRect: CGRect { bounds.insetBy(dx: Self.margin, dy: Self.margin) }

    func configure(table: ERTable, cardFrame: CGRect) {
        if self.table != table {
            self.table = table
            needsDisplay = true
            updateToolTips(size: cardFrame.size)
        }
        setCardFrame(cardFrame)
    }

    func setCardFrame(_ frame: CGRect) {
        let outer = frame.insetBy(dx: -Self.margin, dy: -Self.margin)
        if self.frame.size != outer.size {
            self.frame = outer
            needsDisplay = true
        } else if self.frame.origin != outer.origin {
            setFrameOrigin(outer.origin)
        }
    }

    func setState(isSelected: Bool, isRelated: Bool, isDimmed: Bool) {
        if isSelected != self.isSelected || isRelated != self.isRelated {
            self.isSelected = isSelected
            self.isRelated = isRelated
            needsDisplay = true
        }
        if isDimmed != self.isDimmed {
            self.isDimmed = isDimmed
            alphaValue = isDimmed ? 0.55 : 1
        }
    }

    // MARK: Drawing

    private static let nameFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    private static let columnFont = NSFont.systemFont(ofSize: 11)
    private static let keyColumnFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    private static let typeFont = NSFont.systemFont(ofSize: 10.5)
    private static var symbols: [String: NSImage] = [:]

    /// An SF Symbol at a point size in one color (dynamic colors resolve when drawn).
    private static func symbol(_ name: String, size: CGFloat, color: NSColor, key: String) -> NSImage? {
        if let cached = symbols[key] { return cached }
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        symbols[key] = image
        return image
    }

    private static func lineHeight(_ font: NSFont) -> CGFloat { ceil(font.ascender - font.descender + font.leading) }

    private func drawText(_ text: String, font: NSFont, color: NSColor, x: CGFloat, maxX: CGFloat, midY: CGFloat,
                          truncation: NSLineBreakMode, alignRight: Bool = false) {
        guard maxX > x else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = truncation
        paragraph.alignment = alignRight ? .right : .left
        let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
        let height = Self.lineHeight(font)
        string.draw(with: CGRect(x: x, y: midY - height / 2, width: maxX - x, height: height),
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    private func drawSymbol(_ image: NSImage?, centeredIn box: CGRect) {
        guard let image else { return }
        let size = image.size
        image.draw(in: CGRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2, width: size.width, height: size.height))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let table, let context = NSGraphicsContext.current?.cgContext else { return }
        let card = cardRect
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous).path(in: card).cgPath
        let accent = NSColor.controlAccentColor

        // Background with its shadow.
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -1), blur: isSelected ? 12 : 4,
                          color: NSColor.black.withAlphaComponent(isSelected ? 0.18 : 0.08).cgColor)
        context.addPath(shape)
        context.setFillColor(NSColor.controlBackgroundColor.cgColor)
        context.fillPath()
        context.restoreGState()

        context.saveGState()
        context.addPath(shape)
        context.clip()
        // Header.
        context.setFillColor(accent.withAlphaComponent(isSelected ? 0.28 : 0.13).cgColor)
        context.fill(CGRect(x: card.minX, y: card.minY, width: card.width, height: ERLayout.headerHeight))
        context.setFillColor(ERColors.resolved(.textColor, opacity: 0.12))
        context.fill(CGRect(x: card.minX, y: card.minY + ERLayout.headerHeight - 0.5, width: card.width, height: 0.5))
        let headerMid = card.minY + ERLayout.headerHeight / 2
        let icon = Self.symbol("tablecells", size: 11, color: accent, key: "tablecells")
        let iconWidth = icon?.size.width ?? 14
        drawSymbol(icon, centeredIn: CGRect(x: card.minX + 8, y: headerMid - 8, width: iconWidth, height: 16))
        drawText(table.name, font: Self.nameFont, color: .labelColor, x: card.minX + 8 + iconWidth + 5, maxX: card.maxX - 8,
                 midY: headerMid, truncation: .byTruncatingMiddle)

        // One row per column.
        let firstRow = Int(max(0, (dirtyRect.minY - card.minY - ERLayout.headerHeight) / ERLayout.rowHeight))
        for (index, column) in table.columns.enumerated() where index >= firstRow {
            let top = card.minY + ERLayout.headerHeight + CGFloat(index) * ERLayout.rowHeight
            if top > dirtyRect.maxY { break }
            let mid = top + ERLayout.rowHeight / 2
            let box = CGRect(x: card.minX + 8, y: top, width: 13, height: ERLayout.rowHeight)
            if column.isPrimaryKey {
                drawSymbol(Self.symbol("key.fill", size: 9.5, color: .systemYellow, key: "key"), centeredIn: box)
            } else if column.isForeignKey {
                drawSymbol(Self.symbol("link", size: 9.5, color: accent, key: "link"), centeredIn: box)
            } else {
                let name = column.nullable ? "circle" : "circle.fill"
                drawSymbol(Self.symbol(name, size: 5, color: .tertiaryLabelColor, key: name), centeredIn: box)
            }
            let type = column.dataType.isEmpty ? "—" : column.dataType
            let typeWidth = ceil((type as NSString).size(withAttributes: [.font: Self.typeFont]).width)
            let typeX = max(card.maxX - 8 - typeWidth, box.maxX + 5 + 6)
            drawText(type, font: Self.typeFont, color: .secondaryLabelColor, x: typeX, maxX: card.maxX - 8, midY: mid,
                     truncation: .byTruncatingTail, alignRight: true)
            drawText(column.name, font: column.isPrimaryKey ? Self.keyColumnFont : Self.columnFont, color: .labelColor,
                     x: box.maxX + 5, maxX: typeX - 6, midY: mid, truncation: .byTruncatingTail)
        }
        context.restoreGState()

        // Border.
        let width: CGFloat = isSelected ? 2 : 1
        let border = isSelected ? accent.cgColor
            : (isRelated ? accent.withAlphaComponent(0.6).cgColor : ERColors.resolved(.textColor, opacity: 0.18))
        context.addPath(RoundedRectangle(cornerRadius: 7, style: .continuous).path(in: card.insetBy(dx: width / 2, dy: width / 2)).cgPath)
        context.setStrokeColor(border)
        context.setLineWidth(width)
        context.strokePath()
    }

    // MARK: Tool tips

    private func updateToolTips(size: CGSize) {
        removeAllToolTips()
        guard let table else { return }
        for (index, column) in table.columns.enumerated() {
            let rect = CGRect(x: Self.margin + 8, y: Self.margin + ERLayout.headerHeight + CGFloat(index) * ERLayout.rowHeight,
                              width: 13, height: ERLayout.rowHeight)
            let tip = column.isPrimaryKey ? "Primary key" : column.isForeignKey ? "Foreign key" : column.nullable ? "Nullable" : "Not null"
            addToolTip(rect, owner: tip as NSString, userData: nil)
        }
    }

    // MARK: Mouse

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        let local = convert(point, from: superview)
        return cardRect.contains(local) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let canvas, canvas.interactive else { return }
        if event.clickCount == 2 {
            canvas.callbacks.open(tableID)
            return
        }
        mouseDownPoint = canvas.convert(event.locationInWindow, from: nil)
        dragOrigin = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let canvas, canvas.interactive, let start = mouseDownPoint else { return }
        let point = canvas.convert(event.locationInWindow, from: nil)
        let dx = point.x - start.x, dy = point.y - start.y
        if dragOrigin == nil {
            guard dx * dx + dy * dy >= 9 else { return }
            dragOrigin = canvas.frames[tableID]?.origin ?? .zero
            canvas.callbacks.select(tableID)
        }
        guard let origin = dragOrigin else { return }
        canvas.callbacks.move(tableID, CGPoint(x: origin.x + dx, y: origin.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        guard let canvas, canvas.interactive, mouseDownPoint != nil else { return }
        mouseDownPoint = nil
        if dragOrigin != nil {
            dragOrigin = nil
            canvas.callbacks.moveEnded()
        } else if event.clickCount < 2 {
            canvas.callbacks.select(tableID)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let canvas, canvas.interactive else { return nil }
        return canvas.callbacks.menu(tableID)
    }
}

/// The canvas in a magnifying scroll view: pinch and the zoom controls set the magnification, like the old
/// `scaleEffect`, and "fit" requests are applied once the view has a size.
struct ERCanvasRepresentable: NSViewRepresentable {
    let diagram: ERModel
    let frames: [String: CGRect]
    let canvasSize: CGSize
    let selection: String?
    let highlighted: Set<String>
    let zoom: CGFloat
    let fitRequest: Int
    let callbacks: ERCanvasView.Callbacks
    /// The zoom that fits the diagram in a viewport; the representable then sets it.
    let fit: (CGSize) -> Void
    /// Pinch ended at this magnification.
    let zoomChanged: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ERScrollView {
        let scrollView = ERScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.allowsMagnification = true
        scrollView.minMagnification = ModelTabModel.zoomRange.lowerBound
        scrollView.maxMagnification = ModelTabModel.zoomRange.upperBound
        let canvas = ERCanvasView(frame: CGRect(origin: .zero, size: canvasSize))
        scrollView.documentView = canvas
        context.coordinator.observe(scrollView)
        return scrollView
    }

    func updateNSView(_ scrollView: ERScrollView, context: Context) {
        guard let canvas = scrollView.documentView as? ERCanvasView else { return }
        context.coordinator.zoomChanged = zoomChanged
        canvas.callbacks = callbacks
        if canvas.frame.size != canvasSize { canvas.setFrameSize(canvasSize) }
        canvas.update(diagram: diagram, frames: frames, selection: selection, highlighted: highlighted)
        if abs(scrollView.magnification - zoom) > 0.0005 {
            let visible = scrollView.documentVisibleRect
            scrollView.setMagnification(zoom, centeredAt: CGPoint(x: visible.midX, y: visible.midY))
        }
        if fitRequest != context.coordinator.appliedFit {
            scrollView.pendingFit = { [fit, weak scrollView] size in
                fit(size)
                // After the new magnification is applied.
                DispatchQueue.main.async { scrollView?.documentView?.scroll(.zero) }
            }
            context.coordinator.appliedFit = fitRequest
            scrollView.needsLayout = true
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var appliedFit = 0
        var zoomChanged: (CGFloat) -> Void = { _ in }
        private var observer: NSObjectProtocol?

        func observe(_ scrollView: NSScrollView) {
            observer = NotificationCenter.default.addObserver(forName: NSScrollView.didEndLiveMagnifyNotification, object: scrollView, queue: .main) {
                [weak self, weak scrollView] _ in
                MainActor.assumeIsolated {
                    guard let self, let scrollView else { return }
                    self.zoomChanged(scrollView.magnification)
                }
            }
        }
    }
}

/// Runs a pending "zoom to fit" once the scroll view has its size.
final class ERScrollView: NSScrollView {
    var pendingFit: ((CGSize) -> Void)?

    override func layout() {
        super.layout()
        guard let fit = pendingFit, frame.width > 0, frame.height > 0 else { return }
        pendingFit = nil
        let size = frame.size
        DispatchQueue.main.async { fit(size) }
    }
}

/// A menu item that runs a closure (the cards' context menu).
final class ERMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func run() { handler() }
}
