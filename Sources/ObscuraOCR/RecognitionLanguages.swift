// G-31: the languages a recognition reads in when its caller names none. Never Vision's automatic language detection:
// measured 2026-10-28, it read the ai.replicate.token fixture's random token text as possibly Arabic and loaded the
// Arabic-script recognizer on demand, 12–15 s inside the image's deadline whenever the system had let the model go.
// Pure.
public import Foundation

public enum RecognitionLanguages {
    /// English is always read: every secret format is ASCII, and the G-12 re-read reads in it.
    public static let english = Locale.Language(identifier: "en-US")

    /// The user's `preferred` languages (BCP-47, most preferred first, as `Locale.preferredLanguages` lists them) that
    /// `supported` holds, in the user's order, then English when none of them is English. A preferred language matches
    /// a supported one with the same language and script, the exact region first, else the first supported region
    /// (`en-GB` reads as `en-US`, `zh-Hant-TW` as `zh-Hant`, `pt-PT` as `pt-BR`). Unsupported ones are left out. Never empty.
    public static func resolve(preferred: [String], supported: [Locale.Language]) -> [Locale.Language] {
        var result: [Locale.Language] = []
        func add(_ language: Locale.Language) {
            if !result.contains(where: { $0.maximalIdentifier == language.maximalIdentifier }) { result.append(language) }
        }
        for identifier in preferred {
            let wanted = Locale.Language(identifier: identifier)
            let sameLanguage = supported.filter { $0.languageCode == wanted.languageCode && script(of: $0) == script(of: wanted) }
            if let match = sameLanguage.first(where: { $0.maximalIdentifier == wanted.maximalIdentifier }) ?? sameLanguage.first {
                add(match)
            }
        }
        if !result.contains(where: { $0.languageCode == english.languageCode }) {
            add(supported.first { $0.languageCode == english.languageCode && script(of: $0) == script(of: english) } ?? english)
        }
        return result
    }

    /// The script `language` is written in, filled in from its likely script when the identifier leaves it out.
    static func script(of language: Locale.Language) -> Locale.Script? {
        Locale.Language(identifier: language.maximalIdentifier).script
    }
}
