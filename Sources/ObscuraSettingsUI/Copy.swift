// The words the Settings panes use that are not plain view literals: category names, the one kind → copy mapping
// (system.html §5, CHANGES.md 37), retention and style words, and the localized pattern errors.
import Foundation
import ObscuraDetect
import ObscuraJournal
import ObscuraPrefs

// MARK: - Categories

/// The ten built-in categories in catalogue order, with their tile copy.
enum CategoryCopy {
    static let ordered: [Detector.Category] = [.ai, .cloud, .payments, .scm, .messaging, .databases, .tokens, .config, .personal, .network]

    /// The one shared name (ObscuraDetect), so Detectors, Spotlight and Finder tags read the same (G-24).
    static func title(_ c: Detector.Category) -> String { c.displayTitle }

    /// The short tile label used only when the long one does not fit (open decision 5).
    static func shortTitle(_ c: Detector.Category) -> String {
        switch c {
        case .scm: return String(localized: "Source control")
        case .messaging: return String(localized: "Messaging")
        case .tokens: return String(localized: "Tokens & keys")
        case .personal: return String(localized: "Personal")
        case .ai: return String(localized: "AI")
        default: return title(c)
        }
    }

    /// SF Symbols for the system.html icon of each category (sparkle, cloud, card, branch, mail, database, key,
    /// document, person, globe).
    static func symbol(_ c: Detector.Category) -> String {
        switch c {
        case .ai: return "sparkles"
        case .cloud: return "cloud"
        case .payments: return "creditcard"
        case .scm: return "arrow.triangle.branch"
        case .messaging: return "envelope"
        case .databases: return "cylinder.split.1x2"
        case .tokens: return "key"
        case .config: return "doc.text"
        case .personal: return "person"
        case .network: return "globe"
        case .custom: return "pencil"
        }
    }
}

// MARK: - Counts

enum CountCopy {
    /// "12 of 12 on"
    static func on(_ on: Int, of total: Int) -> String { String(localized: "\(on) of \(total) on") }

    static func rules(_ n: Int) -> String { n == 1 ? String(localized: "1 rule") : String(localized: "\(n) rules") }

    /// The sidebar value of Custom Rules: "3 rules · 2 never", "No rules".
    static func rulesSidebar(blackOut: Int, never: Int) -> String {
        switch (blackOut, never) {
        case (0, 0): return String(localized: "No rules")
        case (_, 0): return rules(blackOut)
        case (0, _): return String(localized: "\(never) never")
        default: return String(localized: "\(rules(blackOut)) · \(never) never")
        }
    }
}

// MARK: - Pattern kinds

/// One mapping from a pattern kind to its menu title, its one-line explanation and the sentence tail
/// ("Black out · things that look like · CUS-004213").
enum KindCopy {
    static let menuOrder: [PatternSpec.Kind] = [.example, .exactText, .prefix, .label, .regex]

    static func title(_ k: PatternSpec.Kind) -> String {
        switch k {
        case .example: return String(localized: "Looks like this")
        case .exactText: return String(localized: "Exact text")
        case .prefix: return String(localized: "Starts with")
        case .label: return String(localized: "After a label")
        case .regex: return String(localized: "Regular expression")
        }
    }

    static func subtitle(_ k: PatternSpec.Kind) -> String {
        switch k {
        case .example: return String(localized: "Paste one example; the shape is learned")
        case .exactText: return String(localized: "These letters, anywhere")
        case .prefix: return String(localized: "A fixed beginning, then a run of characters")
        case .label: return String(localized: "The value written after a label")
        case .regex: return String(localized: "For advanced users")
        }
    }

    static func sentenceTail(_ k: PatternSpec.Kind) -> String {
        switch k {
        case .example: return String(localized: "things that look like")
        case .exactText: return String(localized: "the exact text")
        case .prefix: return String(localized: "anything that starts with")
        case .label: return String(localized: "the value after the label")
        case .regex: return String(localized: "anything matching")
        }
    }

    /// The label in front of the value field in the validation cards.
    static func fieldLabel(_ k: PatternSpec.Kind) -> String {
        switch k {
        case .example: return String(localized: "Example")
        case .exactText: return String(localized: "Text")
        case .prefix: return String(localized: "Beginning")
        case .label: return String(localized: "Label")
        case .regex: return String(localized: "Expression")
        }
    }

    static func placeholder(_ k: PatternSpec.Kind) -> String {
        switch k {
        case .example: return String(localized: "Paste an example, e.g. CUS-004213")
        case .exactText: return String(localized: "e.g. Project Falcon")
        case .prefix: return String(localized: "e.g. tok_")
        case .label: return String(localized: "e.g. Employee ID")
        case .regex: return String(localized: "e.g. \\bCUS-\\d{6}\\b")
        }
    }

    static func ruleKind(_ k: PatternSpec.Kind) -> RuleKind {
        switch k {
        case .example: return .example
        case .exactText: return .exactText
        case .prefix: return .prefix
        case .label: return .label
        case .regex: return .regex
        }
    }

    static func patternKind(_ k: RuleKind) -> PatternSpec.Kind {
        switch k {
        case .example: return .example
        case .exactText: return .exactText
        case .prefix: return .prefix
        case .label: return .label
        case .regex: return .regex
        }
    }
}

// MARK: - Pattern errors

enum PatternCopy {
    /// The localized sentence for a pattern that does not compile. Mirrors `PatternError.userMessage`, adding the
    /// reason for an invalid regular expression when one can be named.
    static func message(for error: PatternError) -> String {
        switch error {
        case .valueTooShort(let minimum) where minimum >= 3: return String(localized: "Paste a longer example")
        case .valueTooShort(let minimum): return minimum == 1 ? String(localized: "Type at least 1 character")
                                                              : String(localized: "Use at least \(minimum) characters")
        case .missingRegex: return String(localized: "Type a regular expression")
        case .invalidRegex(let source):
            if let reason = RegexDiagnosis.reason(source) {
                return String(localized: "This isn’t a valid regular expression — \(reason)")
            }
            return String(localized: "This isn’t a valid regular expression")
        case .regexTooLong(let maximum):
            return String(localized: "This regular expression is longer than \(maximum) characters")
        case .regexTooComplex:
            return String(localized: "This repeats a group that already repeats, which can take too long to check — simplify it, for example (\\w+\\s?)* to [\\w\\s]*")
        }
    }

    /// Compiles a spec, returning the regex source or the error.
    static func compile(_ spec: PatternSpec) -> Result<String, PatternError> {
        do { return .success(try spec.compiledPattern()) }
        catch let error as PatternError { return .failure(error) }
        catch { return .failure(.invalidRegex(spec.pattern ?? "")) }
    }
}

/// Names the commonest reason a regular expression does not compile (an unclosed bracket or group, a stray closer,
/// a dangling escape). Returns nil when the reason is something else; the caller then shows the plain message.
enum RegexDiagnosis {
    static func reason(_ source: String) -> String? {
        var stack: [Character] = []
        var inClass = false
        var escaped = false
        for ch in source {
            if escaped { escaped = false; continue }
            if ch == "\\" { escaped = true; continue }
            if inClass {
                if ch == "]" { inClass = false; _ = stack.popLast() }
                continue
            }
            switch ch {
            case "[": inClass = true; stack.append("[")
            case "(": stack.append("(")
            case "{": stack.append("{")
            case ")":
                guard stack.last == "(" else { return String(localized: "“)” has no opening “(”") }
                stack.removeLast()
            case "}":
                if stack.last == "{" { stack.removeLast() }
            default: break
            }
        }
        if escaped { return String(localized: "it ends with a lone “\\”") }
        if inClass { return String(localized: "“[” is never closed") }
        if stack.contains("(") { return String(localized: "“(” is never closed") }
        return nil
    }
}

// MARK: - Retention, style, appearance

enum RetentionCopy {
    /// "24 hours", "7 days".
    static func duration(_ r: JournalRetention) -> String {
        switch r {
        case .oneHour: return String(localized: "1 hour")
        case .oneDay: return String(localized: "24 hours")
        case .oneWeek: return String(localized: "7 days")
        case .thirtyDays: return String(localized: "30 days")
        }
    }

    static func deletedAfter(_ r: JournalRetention) -> String { String(localized: "Originals deleted after \(duration(r))") }

    /// "in 6 h", "in 2 d", "within the hour".
    static func remaining(_ seconds: TimeInterval) -> String {
        if seconds < 3600 { return String(localized: "within the hour") }
        let hours = Int((seconds / 3600).rounded(.down))
        if hours < 48 { return String(localized: "in \(hours) h") }
        return String(localized: "in \(hours / 24) d")
    }
}

/// Journal & Privacy words that are not retention.
enum JournalPrivacyCopy {
    /// The G-17 switch: a key left visible shows as text with Copy.
    static let keyTextTitle = String(localized: "Show uncovered keys as text")
    static let keyTextHelp = String(localized: "A key you leave visible shows as text you can copy, read again from the original when you look. The text is never saved")

    /// G-23: where the originals are, in plain words.
    static func originalsHelp(_ folder: String) -> String {
        String(localized: "\(folder) — readable by your macOS user only, kept out of Time Machine backups and Spotlight search")
    }

    /// G-24: the two search switches.
    static let spotlightTitle = String(localized: "Find covered screenshots in Spotlight")
    static let spotlightHelp = String(localized: "Search for the kind of secret, like “Stripe secret key”, to find the screenshot. Never the secret itself")
    static let tagsTitle = String(localized: "Tag covered files in Finder")
    static let tagsHelp = String(localized: "Adds the tags “Obscura” and the kind of secret. Tags travel with the file when you share it")
}

enum StyleCopy {
    static func kind(_ k: StyleKind) -> String {
        switch k {
        case .solid: return String(localized: "Solid")
        case .erase: return String(localized: "Erase")
        case .blur: return String(localized: "Blur")
        case .mosaic: return String(localized: "Mosaic")
        }
    }

    static func kindHelp(_ k: StyleKind) -> String {
        switch k {
        case .solid: return String(localized: "An opaque box in the colour you pick")
        case .erase: return String(localized: "Painted in the colour around the secret, so it looks like it was never there")
        case .blur: return String(localized: "Looks blurred, but is drawn from made-up text, so nothing can be recovered")
        case .mosaic: return String(localized: "Looks pixelated, but is drawn from made-up text, so nothing can be recovered")
        }
    }

    static func label(_ l: LabelMode) -> String {
        switch l {
        case .none: return String(localized: "None")
        case .redacted: return String(localized: "“REDACTED”")
        case .kind: return String(localized: "Kind of secret")
        }
    }

    /// A short colour name for the sidebar and headline: "near-black", "white", "custom colour".
    static func colourName(_ rgba: String) -> String {
        let parts = rgba.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count >= 3 else { return String(localized: "near-black") }
        let maxC = parts[0...2].max() ?? 0, minC = parts[0...2].min() ?? 0
        if maxC <= 0.2 { return String(localized: "near-black") }
        if minC >= 0.9 { return String(localized: "white") }
        if maxC - minC < 0.06 { return String(localized: "grey") }
        return String(localized: "custom colour")
    }

    /// "Solid, near-black" (sidebar) and "Solid covers, near-black" (headline).
    static func summary(_ s: StyleRecord) -> String { "\(kind(s.kind)), \(colourName(s.color))" }
    static func headline(_ s: StyleRecord) -> String { String(localized: "\(kind(s.kind)) covers, \(colourName(s.color))") }
}

enum PathCopy {
    /// "~/Desktop/Screenshots"
    static func abbreviated(_ url: URL) -> String { abbreviated(url.path) }

    static func abbreviated(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}

enum ByteCopy {
    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
