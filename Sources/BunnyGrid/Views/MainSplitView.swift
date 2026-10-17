import AppKit
import SwiftUI

/// Navigation | workspace | right pane in an `NSSplitViewController`, like Navicat's window: the navigator opens at
/// 240 pt, the workspace takes any extra width, the side panes collapse and expand with AppKit's own animation, and
/// the divider positions are remembered between launches. SwiftUI's `HSplitView` could do none of that reliably.
struct MainSplitView: NSViewControllerRepresentable {
    @Environment(AppModel.self) private var app

    func makeNSViewController(context: Context) -> MainSplitViewController {
        MainSplitViewController(app: app)
    }

    func updateNSViewController(_ controller: MainSplitViewController, context: Context) {
        controller.update(showNavigator: app.showNavigator, showRightPane: app.showAssistant, expandedRightPane: app.assistant.isExpanded)
    }
}

@MainActor
final class MainSplitViewController: NSSplitViewController {
    private let navigatorItem: NSSplitViewItem
    private let workspaceItem: NSSplitViewItem
    private let rightItem: NSSplitViewItem
    private var expandedRightPane = false
    private var didRestore = false

    init(app: AppModel) {
        func host(_ view: some View) -> NSHostingController<AnyView> {
            let controller = NSHostingController(rootView: AnyView(view.environment(app)))
            // The split view owns the sizes; SwiftUI shouldn't push them around.
            controller.sizingOptions = []
            return controller
        }
        navigatorItem = NSSplitViewItem(viewController: host(NavigatorView()))
        navigatorItem.minimumThickness = 200
        navigatorItem.maximumThickness = 480
        navigatorItem.canCollapse = true
        navigatorItem.holdingPriority = .init(260)

        workspaceItem = NSSplitViewItem(viewController: WorkspaceViewController(app: app))
        workspaceItem.minimumThickness = 360
        workspaceItem.holdingPriority = .init(200)

        rightItem = NSSplitViewItem(viewController: host(RightPane()))
        rightItem.minimumThickness = 300
        rightItem.maximumThickness = 600
        rightItem.canCollapse = true
        rightItem.holdingPriority = .init(260)
        super.init(nibName: nil, bundle: nil)

        navigatorItem.isCollapsed = !app.showNavigator
        rightItem.isCollapsed = !app.showAssistant
        addSplitViewItem(navigatorItem)
        addSplitViewItem(workspaceItem)
        addSplitViewItem(rightItem)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard !didRestore else { return }
        didRestore = true
        // First launch: Navicat's widths. Later launches: the widths the user left (autosaved by AppKit).
        // Debug captures (`--window-size`) always start from the defaults and save nothing.
        let isCapture = CommandLine.arguments.contains("--window-size")
        let defaultsKey = "NSSplitView Subview Frames BunnyGridMain"
        if isCapture || UserDefaults.standard.object(forKey: defaultsKey) == nil {
            let width = splitView.bounds.width
            if !navigatorItem.isCollapsed { splitView.setPosition(240, ofDividerAt: 0) }
            if !rightItem.isCollapsed { splitView.setPosition(width - 300, ofDividerAt: 1) }
        }
        if !isCapture { splitView.autosaveName = "BunnyGridMain" }
    }

    func update(showNavigator: Bool, showRightPane: Bool, expandedRightPane: Bool) {
        if navigatorItem.isCollapsed == showNavigator { navigatorItem.animator().isCollapsed = !showNavigator }
        if rightItem.isCollapsed == showRightPane { rightItem.animator().isCollapsed = !showRightPane }
        guard expandedRightPane != self.expandedRightPane else { return }
        self.expandedRightPane = expandedRightPane
        // The AI Assistant's Expand: a wider right pane, and back.
        rightItem.minimumThickness = expandedRightPane ? 560 : 300
        rightItem.maximumThickness = expandedRightPane ? 900 : 600
        if !rightItem.isCollapsed {
            let target = splitView.bounds.width - (expandedRightPane ? 560 : 300)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.allowsImplicitAnimation = true
                splitView.setPosition(target, ofDividerAt: 1)
                splitView.layoutSubtreeIfNeeded()
            }
        }
    }
}
