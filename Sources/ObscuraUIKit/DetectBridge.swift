// Read-only views of the detector catalogue for the UI.
import ObscuraDetect

enum ObscuraDetectBridge {
    /// Built-in detector id → title.
    static let builtInTitles: [String: String] = Dictionary(uniqueKeysWithValues: Catalogue.builtIn.map { ($0.id, $0.title) })
}
