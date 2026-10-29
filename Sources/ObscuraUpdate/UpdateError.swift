// Every way an update check or install can stop (G-33). Each case carries a plain reason the update banner shows as is;
// none of them carries a secret, a key or file contents. Any of them leaves the installed app untouched.
import Foundation
import OSLog
internal import ObscuraSupport

public enum UpdateError: Error, Equatable, Sendable {
    /// This build has no real update key or feed address (the placeholder values from project.yml).
    case notConfigured
    /// An address that is not HTTPS (the feed, a redirect or the download).
    case insecureURL(String)
    /// The server redirected to a different host or to plain HTTP; nothing from it was used.
    case redirectRefused(from: String, to: String)
    /// The request failed before an answer came (offline, DNS, TLS, timeout).
    case network(String)
    /// The server answered with something other than 200 OK.
    case httpStatus(Int)
    /// The feed is larger than any real feed is.
    case feedTooLarge
    /// The feed is not the signed-feed JSON.
    case feedMalformed
    /// The feed's signature does not verify with the key built into Obscura.
    case badSignature
    /// The signed manifest is missing a field or holds an impossible value (named, never a value).
    case manifestInvalid(String)
    /// The manifest is for another app.
    case wrongApp(String)
    /// The update needs a newer macOS than this Mac runs.
    case systemTooOld(required: String)
    /// The offered version is not newer than the running one (no downgrade, no reinstall).
    case notNewer(offered: String, current: String)
    /// The download's size differs from the signed manifest's.
    case downloadSizeMismatch(expected: Int64, got: Int64)
    /// The download's SHA-256 differs from the signed manifest's.
    case downloadHashMismatch
    /// The disk image could not be opened read-only.
    case diskImage(String)
    /// The disk image does not hold exactly one app at its top level.
    case appMissingInImage
    /// The app in the update fails code-signature validation (damaged or altered).
    case signatureInvalid(String)
    /// The app in the update is validly signed, but not by the identity that signed this copy of Obscura.
    case requirementNotMet
    /// This copy of Obscura has no stable signature (ad-hoc), so no update can be shown to come from the same developer.
    case ownSignatureUnusable
    /// The app in the update is not built the way a release must be (hardened runtime, no exceptions).
    case unsafeBuild(String)
    /// The app in the update says a different version or bundle than the signed manifest.
    case versionMismatch(expected: String, found: String)
    /// Obscura cannot replace itself where it is (read-only volume, translocated, no permission).
    case cannotReplace(String)
    /// A file step failed (temporary folder, copy, swap).
    case fileSystem(String)
    /// The install is done but the new copy could not be started.
    case relaunchFailed

    /// The sentence the update banner and the Check for Updates alert show.
    public var reason: String {
        switch self {
        case .notConfigured:
            String(localized: "This copy of Obscura was built without an update key, so it can't check for new versions.")
        case .insecureURL:
            String(localized: "The update address isn't a secure (HTTPS) address, so Obscura didn't use it.")
        case .redirectRefused(let from, let to):
            String(localized: "The update server at \(from) sent Obscura to \(to). Obscura only downloads from the address it was given.")
        case .network(let detail):
            String(localized: "Obscura couldn't reach the update server (\(detail)).")
        case .httpStatus(let code):
            String(localized: "The update server answered with error \(code).")
        case .feedTooLarge, .feedMalformed:
            String(localized: "The update information isn't in the expected format.")
        case .badSignature:
            String(localized: "The update information isn't signed with Obscura's update key, so Obscura ignored it.")
        case .manifestInvalid(let field):
            String(localized: "The signed update information has an invalid \(field).")
        case .wrongApp(let id):
            String(localized: "The update is for a different app (\(id)).")
        case .systemTooOld(let required):
            String(localized: "This update needs macOS \(required) or later.")
        case .notNewer(let offered, let current):
            String(localized: "Version \(offered) isn't newer than the installed \(current).")
        case .downloadSizeMismatch, .downloadHashMismatch:
            String(localized: "The downloaded update doesn't match its signed description, so Obscura discarded it.")
        case .diskImage:
            String(localized: "The downloaded disk image couldn't be opened.")
        case .appMissingInImage:
            String(localized: "The downloaded disk image doesn't hold the Obscura app.")
        case .signatureInvalid:
            String(localized: "The app in the update has a damaged or altered signature, so Obscura discarded it.")
        case .requirementNotMet:
            String(localized: "The app in the update isn't signed by the same developer as this copy, so Obscura discarded it.")
        case .ownSignatureUnusable:
            String(localized: "This copy of Obscura isn't signed with a stable identity, so it can't verify updates. Download the new version yourself.")
        case .unsafeBuild:
            String(localized: "The app in the update turns off a macOS code protection, so Obscura discarded it.")
        case .versionMismatch(let expected, let found):
            String(localized: "The app in the update is \(found), not the announced \(expected).")
        case .cannotReplace(let why):
            String(localized: "Obscura can't replace itself here: \(why).")
        case .fileSystem:
            String(localized: "A file step of the update failed.")
        case .relaunchFailed:
            String(localized: "The update is installed, but Obscura couldn't relaunch. Open it again yourself.")
        }
    }
}

/// The update log: steps and reason codes only (never a key, a signature or file contents).
enum UpdateLog {
    static let logger = Logger(subsystem: Log.subsystem, category: "update")
}
