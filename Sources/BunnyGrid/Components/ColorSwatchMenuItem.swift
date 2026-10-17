import AppKit
import BunnyGridCore

/// The "Color:" row of the connection context menu as one AppKit menu-item view with small inline swatches,
/// like Navicat's (SwiftUI's palette control group draws a large cell per colour and can't be resized).
///
/// The SwiftUI menu holds a placeholder item whose title is `marker(for:)`; when AppKit adds that item to the
/// context menu, its view is replaced by `ColorSwatchRowView`.
@MainActor
enum ColorSwatchMenuItem {
    private static let prefix = "\u{2063}bunnygrid-color-row:"
    private static var observer: NSObjectProtocol?
    private static var current: (UUID) -> ConnectionColor? = { _ in nil }
    private static var choose: (ConnectionColor, UUID) -> Void = { _, _ in }

    static func marker(for id: UUID) -> String { prefix + id.uuidString }

    /// Installs the replacement once; `current` reads a connection's colour, `choose` applies one.
    static func install(current: @escaping (UUID) -> ConnectionColor?, choose: @escaping (ConnectionColor, UUID) -> Void) {
        self.current = current
        self.choose = choose
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: NSMenu.didAddItemNotification, object: nil, queue: nil) { note in
            // Menus are built on the main thread (queue nil delivers on the posting thread).
            nonisolated(unsafe) let menu = note.object as? NSMenu
            guard let index = note.userInfo?["NSMenuItemIndex"] as? Int else { return }
            MainActor.assumeIsolated {
                guard let menu else { return }
                replace(in: menu, at: index)
            }
        }
    }

    private static func replace(in menu: NSMenu, at index: Int) {
        guard index < menu.numberOfItems else { return }
        let item = menu.item(at: index)!
        guard item.view == nil, item.title.hasPrefix(prefix), let id = UUID(uuidString: String(item.title.dropFirst(prefix.count))) else { return }
        item.view = ColorSwatchRowView(selected: current(id) ?? ConnectionColor.none) { color in choose(color, id) }
    }
}

/// Nine 10 pt swatches (the first is "no colour", a cross) on one menu row; the current colour has a ring.
final class ColorSwatchRowView: NSView {
    private let colors = ConnectionColor.allCases
    private let selected: ConnectionColor
    private let onChoose: (ConnectionColor) -> Void
    private var hovered: Int?
    private static let swatch: CGFloat = 10, cell: CGFloat = 18, leading: CGFloat = 14

    init(selected: ConnectionColor, onChoose: @escaping (ConnectionColor) -> Void) {
        self.selected = selected
        self.onChoose = onChoose
        super.init(frame: NSRect(x: 0, y: 0, width: Self.leading * 2 + CGFloat(ConnectionColor.allCases.count) * Self.cell, height: 20))
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func index(at point: NSPoint) -> Int? {
        let i = Int((point.x - Self.leading) / Self.cell)
        return point.x >= Self.leading && colors.indices.contains(i) ? i : nil
    }

    override func mouseMoved(with event: NSEvent) { hovered = index(at: convert(event.locationInWindow, from: nil)); needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = nil; needsDisplay = true }

    override func mouseUp(with event: NSEvent) {
        guard let i = index(at: convert(event.locationInWindow, from: nil)) else { return }
        enclosingMenuItem?.menu?.cancelTracking()
        onChoose(colors[i])
    }

    override func draw(_ dirtyRect: NSRect) {
        for (i, color) in colors.enumerated() {
            let center = NSPoint(x: Self.leading + CGFloat(i) * Self.cell + Self.cell / 2, y: bounds.midY)
            let rect = NSRect(x: center.x - Self.swatch / 2, y: center.y - Self.swatch / 2, width: Self.swatch, height: Self.swatch)
            if i == hovered {
                NSColor.labelColor.withAlphaComponent(0.12).setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: -3, dy: -3), xRadius: 3, yRadius: 3).fill()
            }
            if let fill = color.nsColor {
                fill.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
            } else {
                NSColor.secondaryLabelColor.setStroke()
                let cross = NSBezierPath()
                cross.move(to: NSPoint(x: rect.minX + 1, y: rect.minY + 1)); cross.line(to: NSPoint(x: rect.maxX - 1, y: rect.maxY - 1))
                cross.move(to: NSPoint(x: rect.minX + 1, y: rect.maxY - 1)); cross.line(to: NSPoint(x: rect.maxX - 1, y: rect.minY + 1))
                cross.lineWidth = 1.3
                cross.stroke()
            }
            if color == selected {
                NSColor.labelColor.setStroke()
                let ring = NSBezierPath(roundedRect: rect.insetBy(dx: -2.5, dy: -2.5), xRadius: 3, yRadius: 3)
                ring.lineWidth = 1.2
                ring.stroke()
            }
        }
    }
}
