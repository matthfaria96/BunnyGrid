import Combine
import Foundation
import Sparkle
import SwiftUI

/// Sparkle auto-updates. Inert unless the bundle was built with an update feed: scripts/release.sh writes
/// `SUFeedURL` and `SUPublicEDKey` into Info.plist only when `BUNNYGRID_SPARKLE_FEED_URL` and
/// `BUNNYGRID_SPARKLE_PUBLIC_KEY` are set. Without both, no updater is created and no menu item appears.
/// The headless `--run-job` runner exits before the app starts, so it never touches the updater.
@MainActor @Observable
final class AppUpdater {
    static let shared = AppUpdater()

    /// Feed and key both present in Info.plist.
    static var isConfigured: Bool {
        let info = Bundle.main.infoDictionary ?? [:]
        let feed = (info["SUFeedURL"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let key = (info["SUPublicEDKey"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        return URL(string: feed)?.scheme == "https" && !key.isEmpty
    }

    private let controller: SPUStandardUpdaterController?
    private(set) var canCheckForUpdates = false
    @ObservationIgnored private var observation: AnyCancellable?

    var isEnabled: Bool { controller != nil }

    private init() {
        guard Self.isConfigured else { controller = nil; return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        observation = controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in MainActor.assumeIsolated { self?.canCheckForUpdates = value } }
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}

/// "Check for Updates…" under the app menu's About item; absent when updates are not configured.
struct CheckForUpdatesCommands: Commands {
    let updater: AppUpdater

    var body: some Commands {
        // About BunnyGrid opens Settings › About (version, licenses), as in MacDash.
        CommandGroup(replacing: .appInfo) {
            AboutItem()
        }
        CommandGroup(after: .appInfo) {
            if updater.isEnabled {
                CheckForUpdatesItem(updater: updater)
            }
        }
    }
}

private struct AboutItem: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("About BunnyGrid") {
            UserDefaults.standard.set("about", forKey: "settingsTab")
            openSettings()
        }
    }
}

private struct CheckForUpdatesItem: View {
    let updater: AppUpdater

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
    }
}
