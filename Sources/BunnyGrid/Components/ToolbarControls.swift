import SwiftUI

/// Wraps its children onto new lines when they don't fit, like Navicat's object toolbars.
struct FlowLayout: Layout {
    var spacing: CGFloat = 14
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: proposal.width ?? maxX, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

/// Small icon + label button used in tab toolbars ("Begin Transaction", "Filter & Sort").
struct ToolbarChip: View {
    let title: String
    let systemImage: String
    var tint: Color = .accentColor
    var isOn = false
    var isEnabled = true
    var help: String?
    var showsMenuIndicator = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(isEnabled ? tint : .secondary)
                    .frame(width: 16)
                Text(title)
                    .foregroundStyle(isEnabled ? .primary : .secondary)
                if showsMenuIndicator {
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 12.5))
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(isOn ? Color.accentColor.opacity(0.16) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(help ?? (isEnabled ? title : "\(title) — coming soon"))
    }
}

/// Large icon-over-label button of the main toolbar ("Connection", "Table", "Query").
struct BigToolbarButton: View {
    let title: String
    let systemImage: String
    var colors: [Color] = [.accentColor]
    var isSelected = false
    var isEnabled = true
    var help: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            BigToolbarLabel(title: title, systemImage: systemImage, colors: colors, isSelected: isSelected, isEnabled: isEnabled)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(help ?? (isEnabled ? title : "\(title) — coming soon"))
    }
}

struct BigToolbarLabel: View {
    let title: String
    let systemImage: String
    var colors: [Color] = [.accentColor]
    var isSelected = false
    var isEnabled = true
    var showsMenuIndicator = false

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: systemImage)
                .symbolRenderingMode(colors.count > 1 ? .palette : .hierarchical)
                .foregroundStyle(colors.first ?? .accentColor, colors.dropFirst().first ?? colors.first ?? .accentColor, colors.last ?? .accentColor)
                .font(.system(size: 24, weight: .regular))
                .frame(height: 28)
                .opacity(isEnabled ? 1 : 0.45)
            HStack(spacing: 2) {
                Text(title)
                if showsMenuIndicator {
                    Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
                }
            }
            .font(.system(size: 11.5))
            .foregroundStyle(isEnabled ? .primary : .secondary)
            .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(minWidth: 62)
        .background(RoundedRectangle(cornerRadius: 6).fill(isSelected ? Color.accentColor.opacity(0.18) : .clear))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(isSelected ? Color.accentColor.opacity(0.35) : .clear))
        .contentShape(Rectangle())
    }
}

/// Small borderless icon button for footers and pane headers.
struct IconButton: View {
    let systemImage: String
    var help: String
    var isOn = false
    var tint: Color = .secondary
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isOn ? Color.accentColor : (isEnabled ? tint : Color.secondary.opacity(0.4)))
                .frame(width: 22, height: 20)
                .background(RoundedRectangle(cornerRadius: 4).fill(isOn ? Color.accentColor.opacity(0.15) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(help)
    }
}
