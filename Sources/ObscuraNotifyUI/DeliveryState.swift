// ObscuraNotifyUI — how macOS is delivering Obscura's notifications right now, read from UNNotificationSettings.
// Pure so tests can feed every combination; the Notifier fills the snapshot.
import Foundation

/// The parts of `UNNotificationSettings` the notifier reads.
struct DeliverySnapshot: Sendable, Hashable {
    enum Authorization: Sendable, Hashable { case notDetermined, denied, authorized }
    var authorization: Authorization
    /// Banners or alerts may appear on screen (`alertSetting == .enabled` and `alertStyle != .none`).
    var showsOnScreen: Bool
    /// Notifications are kept in Notification Centre (`notificationCenterSetting == .enabled`).
    var keepsInCentre: Bool
    /// "Play sound for notifications" is on for Obscura (`soundSetting == .enabled`). Off, no plan asks for a sound.
    var playsSounds: Bool = true
}

/// What the snapshot means for Obscura.
enum DeliveryMode: Sendable, Hashable {
    /// Not asked yet: the first post asks.
    case undetermined
    /// Banners appear.
    case banners
    /// macOS keeps them in Notification Centre without a banner (delivered quietly, or a Focus that holds them):
    /// the mark shows the waiting dot.
    case quiet
    /// Denied, or neither banners nor Notification Centre: panel only.
    case off

    init(_ s: DeliverySnapshot) {
        switch s.authorization {
        case .notDetermined: self = .undetermined
        case .denied: self = .off
        case .authorized:
            if s.showsOnScreen { self = .banners }
            else if s.keepsInCentre { self = .quiet }
            else { self = .off }
        }
    }

    /// Whether to post at all (an `.off` post would be dropped by macOS; skipping it keeps the log honest).
    var posts: Bool { self == .banners || self == .quiet }
    /// `AppModel.focusHolding`: catches are waiting in Notification Centre.
    var holdsBanners: Bool { self == .quiet }
}
