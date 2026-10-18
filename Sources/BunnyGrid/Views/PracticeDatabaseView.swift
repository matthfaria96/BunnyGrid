import BunnyGridCore
import SwiftUI

/// The highlighted card at the top of New Connection: a database to learn and test with, nothing to install.
struct PracticeDatabaseBanner: View {
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(LinearGradient(colors: [Color(hex: 0x5E5CE6), Color(hex: 0xBF5AF2)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: "graduationcap.fill")
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("Create a Practice Database").font(.system(size: 14, weight: .semibold))
                        Text("NO INSTALL")
                            .font(.system(size: 9.5, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.green.opacity(0.18)))
                            .foregroundStyle(.green)
                    }
                    Text("A ready-to-use database with sample data: SaaS, notes, finances, tasks, a store or a blog. Learn SQL, try an idea or test your app.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 8)
                Text("Create…")
                    .font(.system(size: 12.5, weight: .semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.accentColor))
                    .foregroundStyle(.white)
            }
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.accentColor.opacity(isHovering ? 0.14 : 0.09))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.45), lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityIdentifier("practice.banner")
    }
}

/// Pick a template and a name; Create builds the SQLite file, saves the connection and opens it.
struct PracticeDatabaseView: View {
    @Environment(AppModel.self) private var app
    let back: () -> Void
    let done: () -> Void

    @State private var name = "bunnygrid"
    @State private var template = PracticeDatabase.templates[0]

    private let columns = [GridItem(.adaptive(minimum: 250), spacing: 12, alignment: .top)]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: back) { Label("Back", systemImage: "chevron.left") }
                    .buttonStyle(.borderless)
                Spacer()
                Text("Create a Practice Database").font(.system(size: 13, weight: .semibold))
                Spacer()
                Color.clear.frame(width: 60, height: 1)
            }
            .padding(.horizontal, 20)
            .frame(height: 44)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Nothing to install or configure.").font(.system(size: 20, weight: .semibold))
                        Text("BunnyGrid creates a SQLite database on this Mac with tables and sample rows, plus example queries you can run right away. Break it, change it, delete it: it's yours to practice with.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 10) {
                        Text("Name").frame(width: 50, alignment: .leading)
                        TextField("bunnygrid", text: $name)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 240)
                            .accessibilityIdentifier("practice.name")
                        Spacer()
                    }
                    Text("Template").font(.system(size: 13, weight: .semibold))
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(PracticeDatabase.templates) { option in
                            Button { template = option } label: {
                                TemplateCard(template: option, isSelected: option == template)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("practice.template.\(option.id)")
                        }
                    }
                    loginNote
                }
                .padding(24)
            }
            Divider()
            HStack {
                Text(PracticeDatabase.availableURL(named: name, in: AppModel.practiceDirectory).path(percentEncoded: false))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button("Create Database", action: create)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("practice.create")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }

    /// SQLite has no users or passwords; say so plainly, since people expect a login.
    private var loginNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "key.fill").foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text("No user or password needed").font(.system(size: 12, weight: .semibold))
                Text("A practice database is a file on this Mac, so there is no login to remember. To share it, send the .sqlite file or use the Export Wizard.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
    }

    private func create() {
        if app.createPracticeDatabase(template, name: name) { done() }
    }
}

private struct TemplateCard: View {
    let template: PracticeTemplate
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color(hex: template.tint).gradient)
                Image(systemName: template.symbol).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
            }
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text(template.name).font(.system(size: 13, weight: .semibold))
                Text(template.summary)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !template.tables.isEmpty {
                    Text(template.tables.joined(separator: " · "))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.035))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: isSelected ? 1.5 : 1)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
