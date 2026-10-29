// ObscuraNotifyUI — folds per-file problem alerts into one (G-15, ruled 2026-10-27: "several failing files
// raise one combined problem alert"). A Downloads drop of oversized images, or OCR timeouts while Vision warms up, would
// otherwise sound one time-sensitive alert per file. Per family (left unchecked; too large; clean copy not saved): the first
// failure posts its own, sounded alert with its fixes; a second within a minute withdraws it and posts one combined
// alert ("2 images weren't checked") that shows once, without a second sound; later failures update that alert in place,
// quietly, while they keep coming less than a minute apart.
import Foundation

struct ProblemBatcher: Sendable {
    static let window: TimeInterval = 60

    /// Per-file problems that fold together.
    enum Family: String, Sendable, Hashable {
        /// Left as it is: OCR timed out or failed, or a stage threw before the clean copy existed (the Journal's
        /// "Not checked" list holds these).
        case unchecked
        /// Larger than the size Obscura reads (not in "Not checked": checking again cannot change it).
        case tooLarge
        /// Checked and covered in the Journal, but the clean copy could not be written over the file.
        case writeFailed

        init?(_ kind: ProblemNotice.Kind) {
            switch kind {
            case .fileUnchecked: self = .unchecked
            case .fileTooLarge: self = .tooLarge
            case .writeFailed: self = .writeFailed
            default: return nil
            }
        }
    }

    enum Decision: Sendable, Hashable {
        /// Post this problem on its own, sounded, as it always was.
        case single
        /// Post (or update) the family's combined alert. `first`: it replaces the single alert just withdrawn and
        /// shows once without a sound; later ones update it in place quietly.
        case combined(identifier: String, family: Family, notices: [ProblemNotice], first: Bool, withdraw: [String])
    }

    private struct Burst: Sendable {
        var notices: [ProblemNotice] = []
        var last: Date
        var combinedID: String?
    }

    private var bursts: [Family: Burst] = [:]

    init() {}

    mutating func add(_ notice: ProblemNotice, at now: Date) -> Decision {
        guard let family = Family(notice.kind) else { return .single }
        var burst = bursts[family].flatMap { now.timeIntervalSince($0.last) > Self.window ? nil : $0 } ?? Burst(last: now)
        burst.last = now
        // The same file failing again replaces its own line rather than counting twice.
        if let i = burst.notices.firstIndex(where: { $0.key == notice.key }) { burst.notices[i] = notice }
        else { burst.notices.append(notice) }
        defer { bursts[family] = burst }

        guard burst.notices.count >= 2 else { return .single }
        if let id = burst.combinedID {
            return .combined(identifier: id, family: family, notices: burst.notices, first: false, withdraw: [])
        }
        let id = "obscura.problem.files.\(family.rawValue).\(Int(now.timeIntervalSince1970))"
        burst.combinedID = id
        let withdraw = burst.notices.dropLast().map { NotifyID.problemRequest($0.key) }
        return .combined(identifier: id, family: family, notices: burst.notices, first: true, withdraw: withdraw)
    }
}
