// G-31: pass 1 reads in the user's languages plus English, never by Vision's automatic language detection (which read
// the ai.replicate.token fixture's token as possibly Arabic and loaded that model for 12–15 s inside the deadline).
import Foundation
import Testing
import Vision
@testable import ObscuraOCR

@Suite("Recognition languages (G-31)")
struct RecognitionLanguagesTests {
    let supported = ["en-US", "fr-FR", "de-DE", "pt-BR", "zh-Hans", "zh-Hant", "ar-SA"].map { Locale.Language(identifier: $0) }

    func ids(_ languages: [Locale.Language]) -> [String] { languages.map(\.minimalIdentifier) }

    @Test func theUsersLanguagesInTheirOrderThenEnglish() {
        let resolved = RecognitionLanguages.resolve(preferred: ["fr-CA", "de-AT"], supported: supported)
        #expect(ids(resolved) == ids(["fr-FR", "de-DE", "en-US"].map { Locale.Language(identifier: $0) }))
    }

    @Test func anotherEnglishRegionReadsAsTheSupportedOneAndEnglishIsNotRepeated() {
        let resolved = RecognitionLanguages.resolve(preferred: ["en-GB", "pt-PT"], supported: supported)
        #expect(ids(resolved) == ids(["en-US", "pt-BR"].map { Locale.Language(identifier: $0) }))
    }

    @Test func theScriptDecidesBetweenChineseVariants() {
        let resolved = RecognitionLanguages.resolve(preferred: ["zh-Hant-TW"], supported: supported)
        #expect(ids(resolved) == ids(["zh-Hant", "en-US"].map { Locale.Language(identifier: $0) }))
    }

    @Test func aScriptTheUserReadsIsKeptOneTheyDoNotIsNever() {
        let arabic = Locale.Language(identifier: "ar").languageCode
        #expect(RecognitionLanguages.resolve(preferred: ["ar-SA"], supported: supported).contains { $0.languageCode == arabic })
        #expect(!RecognitionLanguages.resolve(preferred: ["en-US", "fr-FR"], supported: supported).contains { $0.languageCode == arabic })
    }

    @Test func unsupportedLanguagesAreLeftOutAndTheResultIsNeverEmpty() {
        #expect(ids(RecognitionLanguages.resolve(preferred: ["xx-YY"], supported: supported)) == ["en"])
        #expect(ids(RecognitionLanguages.resolve(preferred: [], supported: [])) == ["en"])
    }

    @Test func theRequestNeverDetectsTheLanguageItself() {
        let byDefault = VisionTextRecognizer.request(for: OCROptions(), preferred: ["de-DE"])
        #expect(byDefault.automaticallyDetectsLanguage == false)
        #expect(byDefault.recognitionLanguages.contains { $0.languageCode == Locale.Language(identifier: "en").languageCode })
        var named = OCROptions()
        named.languages = ["en-US"]
        let reread = VisionTextRecognizer.request(for: named)
        #expect(reread.automaticallyDetectsLanguage == false && reread.recognitionLanguages.map(\.minimalIdentifier) == ["en"])
    }
}
