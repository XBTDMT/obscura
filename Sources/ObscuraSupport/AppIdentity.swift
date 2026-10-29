// G-38: Obscura's identity on a Mac, and every name derived from it. The bundle identifier is the root of everything the
// app stores under its own name: the defaults domain, the log subsystem, the Keychain services of the rule keys (G-30,
// G-34) and the folder confirmations (G-36), and the Core Spotlight domain (G-24). Deriving them in one place keeps them
// from drifting apart, and lets a migration name the same things under an earlier identity.
public import Foundation

public struct AppIdentity: Sendable, Hashable {
    /// The bundle identifier, which is also the defaults domain.
    public let bundleIdentifier: String

    public init(bundleIdentifier: String) {
        self.bundleIdentifier = bundleIdentifier
    }

    /// The identity this build runs under. project.yml's PRODUCT_BUNDLE_IDENTIFIER says the same (a test checks it).
    public static let current = AppIdentity(bundleIdentifier: "io.github.xbtdmt.obscura")

    /// The defaults domain the settings live in.
    public var defaultsDomain: String { bundleIdentifier }
    /// The unified logging subsystem.
    public var logSubsystem: String { bundleIdentifier }
    /// The Keychain service of the keys that seal custom rule values (G-30, G-34).
    public var ruleKeyService: String { bundleIdentifier + ".rule-values" }
    /// The Keychain service of the watched-folder confirmations (G-36).
    public var folderApprovalService: String { bundleIdentifier + ".folder-approvals" }
    /// The Core Spotlight domain (and index name) of the entries for covered files (G-24).
    public var spotlightDomain: String { bundleIdentifier + ".catches" }

    /// The Info.plist key naming the identity an earlier build of this copy ran under (`OBSCURA_PREVIOUS_IDENTITY`,
    /// Apps/Obscura/Identity.xcconfig). Empty in a public build.
    public static let previousIdentityInfoKey = "ObscuraPreviousIdentity"

    /// The identity an earlier build of this copy ran under, when the build names one; nil when it names none, names
    /// this identity, or names something that is not a bundle identifier.
    public static func previous(in bundle: Bundle = .main) -> AppIdentity? {
        previous(named: bundle.object(forInfoDictionaryKey: previousIdentityInfoKey) as? String)
    }

    /// `previous(in:)` on a value already read: the rules, without a bundle.
    public static func previous(named raw: String?) -> AppIdentity? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), isBundleIdentifier(raw),
              raw != current.bundleIdentifier else { return nil }
        return AppIdentity(bundleIdentifier: raw)
    }

    /// Reverse-DNS: at least two dot-separated parts of ASCII letters, digits and hyphens.
    static func isBundleIdentifier(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-") }
        }
    }
}
