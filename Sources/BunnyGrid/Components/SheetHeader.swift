import SwiftUI

/// The title row every tool sheet shares (Backup, Export, Import, Data Generation, Data Transfer, Sync): a teal
/// symbol, the title in headline, an optional location line, and an optional trailing control.
/// The sheets put a full-width `Divider()` right under it.
struct SheetHeader<Accessory: View>: View {
    let title: String
    let systemImage: String
    var subtitle: String?
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 20))
                .foregroundStyle(.teal)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 8)
            accessory()
        }
        .frame(minHeight: 34)
    }
}

extension SheetHeader where Accessory == EmptyView {
    init(title: String, systemImage: String, subtitle: String? = nil) {
        self.init(title: title, systemImage: systemImage, subtitle: subtitle) { EmptyView() }
    }
}
