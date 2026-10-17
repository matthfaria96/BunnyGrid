import AppKit

/// Lets a data grid be freed once it leaves its window. Found with the soak scenario (`scripts/soak.sh`): every
/// grid ever shown stayed in memory (≈ 9 MB per table tab, ≈ 2 MB per query run) because AppKit's key-view
/// loop keeps its views in global tables (`previousKeyViews`) and the header's column tooltips keep the header
/// (and through it the table) in the tooltip manager. Breaking those links when the grid is removed lets it go.
enum GridTeardown {
    static func release(_ root: NSView) {
        var stack = [root]
        while let view = stack.popLast() {
            // Links into the grid from outside, then from the grid outwards.
            var guardCount = 0
            while let previous = view.previousKeyView, guardCount < 64 {
                previous.nextKeyView = nil
                guardCount += 1
            }
            view.nextKeyView = nil
            if view is NSTableHeaderView { view.removeAllToolTips() }
            stack.append(contentsOf: view.subviews)
            if let scroll = view as? NSScrollView, let header = (scroll.documentView as? NSTableView)?.headerView {
                stack.append(header)
            }
        }
    }
}

extension GridContainerView {
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil, window != nil { GridTeardown.release(self) }
    }
}
