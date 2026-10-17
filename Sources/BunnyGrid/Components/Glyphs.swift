import AppKit
import BunnyGridCore
import SwiftUI

/// Behind-window blur (the translucent sidebar material of Finder and Navicat).
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
    }
}

/// The engine's database drum (our artwork, no vendor logos), dimmed when not connected.
struct DatabaseBadge: View {
    let kind: DatabaseKind
    var size: CGFloat = 16
    var isActive = true

    var body: some View {
        AppIcon(name: kind.iconName, size: size)
            .saturation(isActive ? 1 : 0.15)
            .opacity(isActive ? 1 : 0.8)
    }
}

/// Loads the app's SVG artwork (Resources/Icons) once and caches it.
@MainActor
enum IconLibrary {
    private static var cache: [String: NSImage] = [:]

    /// The SwiftPM resource bundle: inside the .app's Resources, or next to the executable during `swift run`.
    private static let bundle: Bundle? = {
        let name = "BunnyGrid_BunnyGrid.bundle"
        let candidates = [
            Bundle.main.resourceURL?.appending(path: name),
            Bundle.main.bundleURL.appending(path: name),
            Bundle.main.executableURL?.deletingLastPathComponent().appending(path: name),
        ]
        return candidates.compactMap { $0 }.lazy.compactMap { Bundle(url: $0) }.first
    }()

    static func image(_ name: String) -> NSImage? {
        if let cached = cache[name] { return cached }
        guard let url = bundle?.url(forResource: name, withExtension: "svg", subdirectory: "Icons")
                ?? bundle?.url(forResource: name, withExtension: "svg"),
              let image = NSImage(contentsOf: url) else { return nil }
        cache[name] = image
        return image
    }

    /// A copy drawn at a fixed point size, for places that ignore SwiftUI frames (menu and popup button labels).
    static func image(_ name: String, size: CGFloat) -> NSImage? {
        let key = "\(name)@\(size)"
        if let cached = cache[key] { return cached }
        guard let source = image(name) else { return nil }
        let sized = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            source.draw(in: rect)
            return true
        }
        cache[key] = sized
        return sized
    }
}

/// One of the app's illustrated SVG icons.
struct AppIcon: View {
    let name: String
    var size: CGFloat = 16
    var isEnabled = true

    var body: some View {
        Group {
            if let image = IconLibrary.image(name) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "questionmark.square.dashed").resizable().aspectRatio(contentMode: .fit).foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .saturation(isEnabled ? 1 : 0)
        .opacity(isEnabled ? 1 : 0.45)
    }
}

extension View {
    /// Liquid Glass on macOS 26+, a thin material before that.
    @ViewBuilder
    func glassBackground<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
    }
}

extension DatabaseKind {
    var iconName: String {
        switch self {
        case .postgresql: "engine-postgresql"
        case .mysql: "engine-mysql"
        case .mariadb: "engine-mariadb"
        case .sqlite: "engine-sqlite"
        case .sqlserver: "engine-sqlserver"
        }
    }
}

extension DatabaseObjectKind {
    var iconName: String {
        switch self {
        case .table: "table"
        case .view: "view"
        case .materializedView: "materialized-view"
        case .routine: "function"
        }
    }
}
