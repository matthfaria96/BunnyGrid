import AppKit
import SwiftUI

/// Settings › About: centered and quiet, like About This Mac (the same layout as MacDash's About).
struct AboutPane: View {
    @State private var showLicenses = false

    private var version: String {
        let info = Bundle.main.infoDictionary
        let marketing = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "Version \(marketing) (\(build))"
    }

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
                .padding(.bottom, 18)
            Text("BunnyGrid")
                .font(.system(size: 24, weight: .semibold))
            Text(version)
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.top, 4)

            Text("BunnyGrid is a native database client for SQLite, PostgreSQL, MySQL, MariaDB, SQL Server, MongoDB and Redis: browse objects, edit data, write and run SQL, design tables, import and export, sync, back up, chart with BI and ask an AI assistant. It is free, with no accounts or tracking.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 460)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 26)

            Text("BunnyGrid is free software under the GNU AGPL v3.0. It builds on the open-source projects listed in its licenses.")
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)

            Button("Open-source licenses") { showLicenses = true }
                .buttonStyle(.link)
                .font(.system(size: 12))
                .padding(.top, 10)
                .accessibilityIdentifier("about.licenses")
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 14)
        .padding(.bottom, 20)
        .sheet(isPresented: $showLicenses) { OpenSourceLicensesView() }
    }
}

/// The licenses of the open-source work BunnyGrid is built from, shown in full so the notices travel with the app.
/// The list is generated from the packages' own LICENSE and NOTICE files (scripts/gen-notices.py).
struct OpenSourceLicensesView: View {
    @Environment(\.dismiss) private var dismiss

    struct Entry: Decodable, Identifiable {
        let id: String
        let name: String
        let license: String
        let usage: String
        let url: String
        let text: String
    }

    struct Reference: Decodable, Identifiable {
        let name: String
        let url: String
        let license: String
        let usage: String
        var id: String { name }
    }

    private struct Payload: Decodable {
        let entries: [Entry]
        let references: [Reference]
    }

    private static let payload: Payload? = {
        guard let url = IconLibrary.bundle?.url(forResource: "licenses", withExtension: "json", subdirectory: "Licenses"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Payload.self, from: data)
    }()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Open-source licenses")
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    Text("BunnyGrid is built on the open-source projects below. Their copyright notices and licenses are kept here as those licenses require.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    ForEach(Self.payload?.entries ?? []) { entry in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(entry.name).font(.headline)
                                Text(entry.license)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                if let url = URL(string: entry.url), !entry.url.isEmpty {
                                    Link("Source", destination: url).font(.caption)
                                }
                            }
                            if !entry.usage.isEmpty {
                                Text("Used for \(entry.usage)").font(.caption).foregroundStyle(.secondary)
                            }
                            Text(entry.text)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    }
                    if let references = Self.payload?.references, !references.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("References").font(.headline)
                            Text("Studied for design and behaviour; no code or artwork was copied.")
                                .font(.caption).foregroundStyle(.secondary)
                            ForEach(references) { reference in
                                HStack(alignment: .firstTextBaseline, spacing: 4) {
                                    if let url = URL(string: reference.url) {
                                        Link(reference.name, destination: url)
                                    } else {
                                        Text(reference.name)
                                    }
                                    Text("(\(reference.license)): \(reference.usage)").foregroundStyle(.secondary)
                                }
                                .font(.callout)
                            }
                        }
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 640, height: 560)
    }
}
