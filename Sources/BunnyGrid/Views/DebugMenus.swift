#if DEBUG
import AppKit

/// `--connection-menu`: pops the first connection's context menu from the navigator with a synthetic right-click
/// event (nothing moves the real pointer), so the menu can be captured with `screencapture`.
@MainActor
enum DebugMenus {
    static func popConnectionMenuIfRequested() {
        guard CommandLine.arguments.contains("--connection-menu") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }),
                  let content = window.contentView,
                  let outline = findOutline(in: content), outline.numberOfRows > 1 else { return }
            // Row 0 is My Connections; row 1 is the first connection.
            let rect = outline.rect(ofRow: 1)
            let point = outline.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
            guard let event = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
                  let hit = content.hitTest(content.convert(point, from: nil)) else { return }
            var view: NSView? = hit
            while let current = view {
                if let menu = current.menu(for: event) {
                    NSMenu.popUpContextMenu(menu, with: event, for: current)
                    return
                }
                view = current.superview
            }
        }
    }

    private static func findOutline(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView, table.numberOfRows > 0, table.tableColumns.count == 1 { return table }
        for subview in view.subviews {
            if let found = findOutline(in: subview) { return found }
        }
        return nil
    }
}
#endif
