// Obscura's own updates (G-33; Sparkle removed so library validation is back on). The rules live in
// `UpdateCoordinator` (ObscuraUIKit) and the checking and installing in ObscuraUpdate; this file only wires them to the
// running app: the compiled-in public key, the feed address from Info.plist, the app's own bundle, and the relaunch.
//
// A build with the placeholder key or feed address (every build until the maintainer creates the release key, B-8) has no
// updater: `isAvailable` is false, Check for Updates… says updates aren't set up, and nothing is ever fetched.
import AppKit
import Foundation
import ObscuraSupport
import ObscuraUIKit
import ObscuraUpdate

@MainActor
final class Updater: UpdateDriver {
    let coordinator: UpdateCoordinator
    private let installer: UpdateInstaller?
    /// The manifest the last successful check found; Install installs exactly this one.
    private var found: UpdateManifest?
    /// Quits the app for the relaunch (the router's real Quit).
    var quit: (() -> Void)?

    /// Info.plist key holding the feed address (set from the OBSCURA_UPDATE_FEED_URL build setting).
    static let feedURLKey = "ObscuraUpdateFeedURL"

    /// The feed address, when it is a real HTTPS address (not the project.yml placeholder).
    static var feedURL: URL? {
        guard let text = Bundle.main.object(forInfoDictionaryKey: feedURLKey) as? String, !text.contains("REPLACE_WITH"),
              let url = URL(string: text), url.scheme == "https", url.host() != nil else { return nil }
        return url
    }

    init(model: AppModel) {
        coordinator = UpdateCoordinator(model: model)
        if let trust = UpdateTrust(base64PublicKey: UpdateBuildConfig.publicKey), let feed = Self.feedURL,
           let app = InstalledApp.running(), let state = try? Self.stateFolder() {
            installer = UpdateInstaller(installed: app, feedURL: feed, trust: trust, transport: URLSessionUpdateTransport(),
                                        codeVerifier: RunningAppVerifier(), stateFolder: state)
        } else {
            installer = nil
        }
        coordinator.driver = self
        // This launch may be the new copy a just-finished install opened: the rollback copy can go.
        if let version = installer?.settlePendingInstall() {
            Log.app.notice("update: now running \(version, privacy: .public); rollback copy removed")
        }
    }

    /// `~/Library/Application Support/Obscura/Updates` (0700): the pending-install record and the last check time.
    static func stateFolder() throws -> URL {
        let folder = try AppEnvironment.supportRoot().appending(path: "Updates", directoryHint: .isDirectory)
        try FileAtomics.makePrivateDirectory(folder)
        return folder
    }

    // MARK: UpdateDriver

    var isAvailable: Bool { installer != nil }
    var lastCheck: Date? { installer?.lastCheck }
    func recordCheck(at date: Date) { installer?.recordCheck(at: date) }

    func check() async -> UpdateCheckResult {
        guard let installer else { return .failed(reason: UpdateError.notConfigured.reason) }
        do {
            switch try await installer.check() {
            case .upToDate:
                found = nil
                return .upToDate(version: installer.installed.version.marketingString)
            case .available(let manifest):
                found = manifest
                return .available(UpdateOffer(version: manifest.version, releaseNotesURL: manifest.releaseNotesURL))
            }
        } catch {
            Log.app.notice("update: check stopped (\(String(describing: error), privacy: .public))")
            return .failed(reason: error.reason)
        }
    }

    func install() async -> UpdateInstallResult {
        guard let installer, let manifest = found else { return .failed(reason: UpdateError.notConfigured.reason) }
        do {
            let prepared = try await installer.install(manifest)
            guard Relauncher.start(prepared) else { return .failed(reason: UpdateError.relaunchFailed.reason) }
            quit?()
            return .relaunching
        } catch {
            Log.app.notice("update: install stopped (\(String(describing: error), privacy: .public)); installed app unchanged")
            return .failed(reason: error.reason)
        }
    }
}
