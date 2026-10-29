public import OSLog

/// Redaction-safe logging. Callers pass counts, ids and rects — never image bytes or recognized text.
/// The `secretSafe` wrappers exist so a reviewer can grep for every place text could leak.
public enum Log {
    public static let subsystem = AppIdentity.current.logSubsystem
    public static let engine = Logger(subsystem: subsystem, category: "engine")
    public static let capture = Logger(subsystem: subsystem, category: "capture")
    public static let ocr = Logger(subsystem: subsystem, category: "ocr")
    public static let detect = Logger(subsystem: subsystem, category: "detect")
    public static let render = Logger(subsystem: subsystem, category: "render")
    public static let journal = Logger(subsystem: subsystem, category: "journal")
    public static let app = Logger(subsystem: subsystem, category: "app")
    /// Spotlight entries and Finder tags (G-24): counts and entry ids only.
    public static let search = Logger(subsystem: subsystem, category: "search")
}

/// A value that is safe to log: it carries a count or an identifier, never content.
public struct Count: Sendable, CustomStringConvertible {
    public let value: Int
    public init(_ value: Int) { self.value = value }
    public var description: String { String(value) }
}
