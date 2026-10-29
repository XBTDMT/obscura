/// The two search defaults of G-24, in one place (2026-10-27: "test/figure out what is the best way and make that
/// one default"). They are provisional until a test on an installed copy decides them: flipping either is
/// this one line, and every test that pins a default reads these constants.
public enum SearchIndexDefaults {
    /// Covered screenshots appear in Spotlight under the kind of secret they hid (Core Spotlight, labels only).
    public static let spotlightEntries = true
    /// Covered files carry the Finder tags "Obscura" and the kind of secret. Tags travel with a shared file.
    public static let finderTags = false
}
