import AppKit
import SwiftUI

/// A product or company mark for the connection-type picker. Logos come from Simple Icons (CC0) or the
/// owner's own published files (see Resources/Icons/brands/SOURCES.md) and are tinted with the official
/// brand colour. Brands whose owners don't allow logo use in third-party software get a text tile instead. Logos belong to their
/// owners and are shown only to identify the product.
enum Brand: Hashable {
    /// `brands/brand-<slug>.svg`, single-colour, tinted with `hex`.
    case logo(slug: String, hex: UInt32)
    /// Text tile: `short` for small sizes, `long` for tiles.
    case monogram(short: String, long: String, hex: UInt32)

    var hex: UInt32 {
        switch self {
        case .logo(_, let hex), .monogram(_, _, let hex): hex
        }
    }

    var color: Color { Color(hex: hex) }

    /// Relative luminance (WCAG) of the brand colour.
    var luminance: Double {
        func channel(_ v: UInt32) -> Double {
            let c = Double(v & 0xFF) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(hex >> 16) + 0.7152 * channel(hex >> 8) + 0.0722 * channel(hex)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

extension ConnectionFamily {
    var brand: Brand {
        switch self {
        case .mysql: .logo(slug: "mysql", hex: 0x4479A1)
        case .postgresql: .logo(slug: "postgresql", hex: 0x4169E1)
        case .sqlserver: .monogram(short: "SQL", long: "SQL Server", hex: 0xCC2927)
        case .oracle: .monogram(short: "O", long: "ORACLE", hex: 0xC74634)
        case .sqlite: .logo(slug: "sqlite", hex: 0x003B57)
        case .mariadb: .logo(slug: "mariadb", hex: 0x003545)
        case .mongodb: .logo(slug: "mongodb", hex: 0x47A248)
        case .redis: .logo(slug: "redis", hex: 0xFF4438)
        case .snowflake: .logo(slug: "snowflake", hex: 0x29B5E8)
        }
    }
}

extension ConnectionVendor {
    var brand: Brand {
        switch self {
        case .aws: .monogram(short: "aws", long: "aws", hex: 0xFF9900)
        case .fujitsu: .logo(slug: "fujitsu", hex: 0xFF0000)
        case .google: .logo(slug: "googlecloud", hex: 0x4285F4)
        case .microsoft: .monogram(short: "Az", long: "Azure", hex: 0x0078D4)
        case .oracle: .monogram(short: "O", long: "ORACLE", hex: 0xC74634)
        case .alibaba: .logo(slug: "alibabacloud", hex: 0xFF6A00)
        case .highgo: .monogram(short: "HG", long: "HighGo", hex: 0xEC6C00)
        case .huawei: .logo(slug: "huawei", hex: 0xFF0000)
        case .kingbase: .logo(slug: "kingbase", hex: 0xC9151E)
        case .oceanbase: .logo(slug: "oceanbase", hex: 0x0096FE)
        case .pingcap: .logo(slug: "tidb", hex: 0xDC150B)
        case .tencent: .monogram(short: "TC", long: "Tencent Cloud", hex: 0x0052D9)
        }
    }
}

extension ConnectionType {
    /// The main mark: the product's own logo when it has one, else the vendor's, else the engine's.
    var brand: Brand {
        switch id {
        case "ivorysql": .logo(slug: "ivorysql", hex: 0xFBAF42)
        case "ms-garnet": .monogram(short: "G", long: "Garnet", hex: 0x7A060C)
        default: vendor?.brand ?? family?.brand ?? .monogram(short: "?", long: "?", hex: 0x8E8E93)
        }
    }

    /// Small engine badge on hosted services (Amazon RDS for PostgreSQL shows AWS with a PostgreSQL badge).
    var badge: Brand? {
        guard vendor != nil || id == "ms-garnet" || id == "ivorysql", id != "tidb" else { return nil }
        return family?.brand
    }
}

/// The brand mark on a plate: white in light mode; in dark mode a dark plate, or a light one when the
/// brand colour is too dark to read on dark (MariaDB, SQLite, PostgreSQL blue).
struct BrandTile: View {
    let brand: Brand
    var size: CGFloat = 50
    /// Small marks (filter rows, list rows) drop the plate so the logo fills the space.
    var plated: Bool { size >= 22 }
    @Environment(\.colorScheme) private var colorScheme

    /// Dark plate only when the brand colour keeps enough contrast on it (WCAG luminance ≥ 0.2).
    private var lightPlate: Bool { colorScheme == .light || brand.luminance < 0.2 }

    var body: some View {
        ZStack {
            if plated {
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    .fill(lightPlate ? Color.white : Color(white: 0.20))
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    .strokeBorder(lightPlate ? Color.black.opacity(0.10) : Color.white.opacity(0.12), lineWidth: max(0.5, size * 0.02))
            }
            // Without a plate, a very dark brand colour turns white on dark backgrounds (Simple Icons guidance).
            BrandGlyph(brand: brand, size: size * (plated ? 0.66 : 1),
                       color: !plated && colorScheme == .dark && brand.luminance < 0.08 ? .white : brand.color)
        }
        .frame(width: size, height: size)
    }
}

/// Just the logo or text, in the brand colour.
struct BrandGlyph: View {
    let brand: Brand
    var size: CGFloat
    var color: Color

    var body: some View {
        switch brand {
        case .logo(let slug, _):
            if let image = IconLibrary.image("brand-\(slug)", subdirectory: "Icons/brands") {
                Image(nsImage: image)
                    .renderingMode(.template)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(color)
                    .frame(width: size, height: size)
            } else {
                Color.clear.frame(width: size, height: size)
            }
        case .monogram(let short, let long, _):
            let text = size >= 24 ? long : short
            Text(text)
                .font(.system(size: size * (text.count <= 3 ? 0.5 : 0.4), weight: .heavy, design: text == "ORACLE" ? .default : .rounded))
                .tracking(text == "ORACLE" ? -0.02 * size : 0)
                .foregroundStyle(color)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.2)
                .frame(width: size * 1.1, height: size)
        }
    }
}
