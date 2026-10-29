// ObscuraDetect — the plain-words name of each category, shared by the Settings tiles and the search labels (G-24),
// so a category reads the same in Detectors, in Spotlight and on a Finder tag.
import Foundation

extension Detector.Category {
    public var displayTitle: String {
        switch self {
        case .ai: return String(localized: "AI providers")
        case .cloud: return String(localized: "Cloud")
        case .payments: return String(localized: "Payments")
        case .scm: return String(localized: "Source control & packages")
        case .messaging: return String(localized: "Messaging & email")
        case .databases: return String(localized: "Databases")
        case .tokens: return String(localized: "Tokens & private keys")
        case .config: return String(localized: "Config files")
        case .personal: return String(localized: "Personal info")
        case .network: return String(localized: "Network")
        case .custom: return String(localized: "Your rules")
        }
    }
}
