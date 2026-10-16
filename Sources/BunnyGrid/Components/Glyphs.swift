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

/// A toolbar illustration: a symbol on a glossy gradient tile, or a bare symbol, with an optional badge.
/// Our own artwork in the spirit of Navicat's macOS icons.
struct ToolbarGlyph: View {
    enum Style {
        /// White symbol on a rounded gradient tile.
        case tile([Color])
        /// The symbol itself in one or two colors.
        case symbol([Color])
    }

    enum Badge {
        case plus
        case chevron
    }

    let systemImage: String
    let style: Style
    var badge: Badge?
    var size: CGFloat = 30
    var isEnabled = true

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            switch style {
            case .tile(let colors):
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
                    .overlay(
                        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                            .fill(LinearGradient(colors: [.white.opacity(0.35), .clear], startPoint: .top, endPoint: .center))
                    )
                    .overlay(
                        Image(systemName: systemImage)
                            .font(.system(size: size * 0.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.2), radius: 0.5, y: 0.5)
                    )
                    .frame(width: size * 0.86, height: size * 0.86)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
                    .frame(width: size, height: size)
            case .symbol(let colors):
                Image(systemName: systemImage)
                    .symbolRenderingMode(colors.count > 1 ? .palette : .monochrome)
                    .foregroundStyle(colors.first ?? .accentColor, colors.dropFirst().first ?? colors.first ?? .accentColor)
                    .font(.system(size: size * 0.78, weight: .regular))
                    .shadow(color: .black.opacity(0.18), radius: 0.5, y: 0.5)
                    .frame(width: size, height: size)
            }
            if let badge {
                switch badge {
                case .plus:
                    Image(systemName: "plus.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .green)
                        .font(.system(size: size * 0.38, weight: .bold))
                        .background(Circle().fill(.white).padding(2))
                        .offset(x: 2, y: 2)
                case .chevron:
                    Image(systemName: "chevron.down")
                        .font(.system(size: size * 0.22, weight: .bold))
                        .foregroundStyle(.secondary)
                        .offset(x: size * 0.18, y: -size * 0.3)
                }
            }
        }
        .saturation(isEnabled ? 1 : 0.2)
        .opacity(isEnabled ? 1 : 0.5)
    }
}

/// Rounded monogram tile identifying a database engine (no vendor logos).
struct DatabaseBadge: View {
    let kind: DatabaseKind
    var size: CGFloat = 16
    var isActive = true

    private var monogram: String {
        switch kind {
        case .postgresql: "Pg"
        case .mysql: "My"
        case .mariadb: "Ma"
        case .sqlite: "Sq"
        }
    }

    private var colors: [Color] {
        switch kind {
        case .postgresql: [Color(red: 0.36, green: 0.55, blue: 0.85), Color(red: 0.18, green: 0.35, blue: 0.62)]
        case .mysql: [Color(red: 0.98, green: 0.62, blue: 0.20), Color(red: 0.0, green: 0.46, blue: 0.62)]
        case .mariadb: [Color(red: 0.62, green: 0.45, blue: 0.33), Color(red: 0.36, green: 0.24, blue: 0.16)]
        case .sqlite: [Color(red: 0.35, green: 0.75, blue: 0.85), Color(red: 0.07, green: 0.44, blue: 0.62)]
        }
    }

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(LinearGradient(colors: isActive ? colors : [Color.gray.opacity(0.75), Color.gray.opacity(0.5)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(
                Text(monogram)
                    .font(.system(size: size * 0.48, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.5)
            )
            .frame(width: size, height: size)
    }
}
