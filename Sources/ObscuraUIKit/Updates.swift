// The update offer and the one place its life is decided (B-8, G-33). The app target's Updater adapts ObscuraUpdate
// (Obscura's own signed feed and verified install) to the plain calls below, so the rules are testable without the
// network: a check that finds an update shows Obscura's banner (Install / Later); Install downloads, verifies and
// relaunches, or says plainly why it did not; Later clears the banner until the next check reports the update again.
public import Foundation

/// An update the updater found and is holding for the user.
public struct UpdateOffer: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// Found and waiting for Install or Later.
        case ready
        /// Install pressed: downloading, verifying, replacing. Ends with a relaunch or `failed`.
        case installing
        /// Install stopped; the installed app is unchanged. The reason is one plain sentence.
        case failed(reason: String)
    }

    /// The version as the user reads it (the manifest's marketing version), e.g. "1.1".
    public var version: String
    /// The release notes, when the manifest names them.
    public var releaseNotesURL: URL?
    public var phase: Phase

    public init(version: String, releaseNotesURL: URL? = nil, phase: Phase = .ready) {
        self.version = version
        self.releaseNotesURL = releaseNotesURL
        self.phase = phase
    }
}

/// What one check found.
public enum UpdateCheckResult: Equatable, Sendable {
    case upToDate(version: String)
    case available(UpdateOffer)
    case failed(reason: String)
}

/// How an install ended.
public enum UpdateInstallResult: Equatable, Sendable {
    /// Installed and verified; the app is about to quit and the new copy to open.
    case relaunching
    case failed(reason: String)
}

/// The updater behind the coordinator: ObscuraUpdate in the app, a fake in tests.
@MainActor
public protocol UpdateDriver: AnyObject {
    /// False when this build cannot check at all (no release key or feed address yet, B-8): Check for Updates… says so.
    var isAvailable: Bool { get }
    /// When the last check ran (any kind), for the once-a-day schedule.
    var lastCheck: Date? { get }
    func recordCheck(at date: Date)
    /// Fetches and verifies the signed feed.
    func check() async -> UpdateCheckResult
    /// Installs the update the last successful check found. `.relaunching` means the app is about to quit.
    func install() async -> UpdateInstallResult
}

/// What Check for Updates… says when this build has no updater, instead of doing nothing (recon M-3).
public enum UpdateCopy {
    public static var notSetUpTitle: String { String(localized: "Updates aren't set up in this build") }
    public static var notSetUpBody: String {
        String(localized: "This copy of Obscura was built without an update signing key, so it can't check for new versions. Protection works as usual.")
    }
    public static func upToDateTitle(_ version: String) -> String { String(localized: "Obscura \(version) is up to date") }
    public static var checkFailedTitle: String { String(localized: "Couldn't check for updates") }
    public static func availableTitle(_ version: String) -> String { String(localized: "Obscura \(version) is available") }
    public static var availableBody: String {
        String(localized: "Installing downloads it, checks that it is signed by the same developer as this copy, and relaunches Obscura. Protection resumes right away.")
    }
}

/// Decides what the update banner shows, from checks, installs and the user's two buttons.
@MainActor
public final class UpdateCoordinator {
    /// At most one scheduled check a day (Settings → About: "At most once a day, when Obscura starts or a window opens").
    public static let checkInterval: TimeInterval = 24 * 60 * 60

    public weak var model: AppModel?
    public weak var driver: (any UpdateDriver)?
    /// Called each time a scheduled check starts showing an offer; the app posts the passive macOS banner from it.
    public var onOffer: ((UpdateOffer) -> Void)?
    private let now: () -> Date
    private var checking = false

    public init(model: AppModel, driver: (any UpdateDriver)? = nil, now: @escaping () -> Date = Date.init) {
        self.model = model
        self.driver = driver
        self.now = now
    }

    /// Whether Check for Updates… can reach an updater in this build.
    public var isAvailable: Bool { driver?.isAvailable ?? false }

    /// A scheduled check: only with "Check for updates automatically" on, and only once a day. Returns whether it ran.
    /// A failure changes nothing on screen (it is retried at the next opportunity); nothing newer clears a stale offer.
    @discardableResult
    public func scheduledCheck() async -> Bool {
        guard let driver, driver.isAvailable, let model, model.settings.updatesCheckAutomatically, !checking else { return false }
        if let last = driver.lastCheck, now().timeIntervalSince(last) < Self.checkInterval, last <= now() { return false }
        let result = await runCheck(driver)
        switch result {
        case .available(let offer):
            guard model.updateOffer?.phase != .installing else { break }
            // The passive notification goes once per offer showing: a new version, or the same one again after Later.
            let isNew = model.updateOffer?.version != offer.version
            model.updateOffer = offer
            if isNew { onOffer?(offer) }
        case .upToDate:
            if model.updateOffer?.phase != .installing { model.updateOffer = nil }
        case .failed:
            break
        }
        return true
    }

    /// "Check for Updates…": always checks now. The caller shows the result (an alert); a found update also becomes the
    /// banner so Install is one click away. Nil when this build cannot check (the caller says updates aren't set up).
    public func checkForUpdates() async -> UpdateCheckResult? {
        guard let driver, driver.isAvailable, !checking else { return nil }
        let result = await runCheck(driver)
        switch result {
        case .available(let offer):
            if model?.updateOffer?.phase != .installing { model?.updateOffer = offer }
        case .upToDate:
            if model?.updateOffer?.phase != .installing { model?.updateOffer = nil }
        case .failed:
            break
        }
        return result
    }

    /// Install (the banner's button, the menu row, the notification): ready or failed → installing → relaunch, or failed
    /// with its reason. Ignored while an install runs or when nothing is offered.
    public func install() async {
        guard let driver, var offer = model?.updateOffer, offer.phase != .installing else { return }
        offer.phase = .installing
        model?.updateOffer = offer
        switch await driver.install() {
        case .relaunching:
            break
        case .failed(let reason):
            offer.phase = .failed(reason: reason)
            model?.updateOffer = offer
        }
    }

    /// Later: the banner goes until the next check reports the update again. An install in progress is not interrupted.
    public func dismiss() {
        guard model?.updateOffer?.phase != .installing else { return }
        model?.updateOffer = nil
    }

    private func runCheck(_ driver: any UpdateDriver) async -> UpdateCheckResult {
        checking = true
        defer { checking = false }
        let result = await driver.check()
        driver.recordCheck(at: now())
        return result
    }
}
