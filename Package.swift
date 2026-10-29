// swift-tools-version: 6.0
// Obscura — engine packages, CLI and tests. The macOS app target lives in project.yml (XcodeGen).
// Dependency direction is the one in knowledge/spec/ARCHITECTURE.md §2 and is enforced here.
import PackageDescription

let strict: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
]

let package = Package(
    name: "Obscura",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ObscuraSupport", targets: ["ObscuraSupport"]),
        .library(name: "ObscuraPrefs", targets: ["ObscuraPrefs"]),
        .library(name: "ObscuraDetect", targets: ["ObscuraDetect"]),
        .library(name: "ObscuraOCR", targets: ["ObscuraOCR"]),
        .library(name: "ObscuraRender", targets: ["ObscuraRender"]),
        .library(name: "ObscuraJournal", targets: ["ObscuraJournal"]),
        .library(name: "ObscuraCapture", targets: ["ObscuraCapture"]),
        .library(name: "ObscuraSearch", targets: ["ObscuraSearch"]),
        .library(name: "ObscuraEngine", targets: ["ObscuraEngine"]),
        .library(name: "ObscuraUIKit", targets: ["ObscuraUIKit"]),
        .library(name: "ObscuraUpdate", targets: ["ObscuraUpdate"]),
        .library(name: "ObscuraAppUI", targets: ["ObscuraMenuBarUI", "ObscuraJournalUI", "ObscuraViewerUI", "ObscuraSettingsUI", "ObscuraSetupUI", "ObscuraNotifyUI", "ObscuraThumbnailUI"]),
        .executable(name: "obscura", targets: ["obscura"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(name: "ObscuraSupport", exclude: ["README.md"], swiftSettings: strict),
        .target(name: "ObscuraPrefs", dependencies: ["ObscuraSupport"], exclude: ["README.md"], swiftSettings: strict),
        .target(name: "ObscuraDetect", dependencies: ["ObscuraSupport", "ObscuraPrefs"], exclude: ["README.md"], swiftSettings: strict),
        .target(name: "ObscuraOCR", dependencies: ["ObscuraSupport"], exclude: ["README.md"], swiftSettings: strict),
        .target(name: "ObscuraRender", dependencies: ["ObscuraSupport"], exclude: ["README.md"], swiftSettings: strict),
        .target(name: "ObscuraJournal", dependencies: ["ObscuraSupport"], exclude: ["README.md", "Migrations/001_initial.sql", "Migrations/002_unchecked.sql", "Migrations/003_covered_files.sql", "Migrations/004_unchecked_reasons.sql", "Migrations/005_uncovered_files.sql", "Migrations/006_clean_digest.sql", "Migrations/007_drop_text_hash.sql", "Migrations/008_seal_rule_values.sql", "Migrations/009_seal_detector_overrides.sql", "Migrations/010_unread_spots.sql"], swiftSettings: strict, linkerSettings: [.linkedLibrary("sqlite3")]),
        .target(name: "ObscuraCapture", dependencies: ["ObscuraSupport"], exclude: ["README.md"], swiftSettings: strict),
        // G-24: Spotlight entries and Finder tags for covered files (labels only).
        .target(name: "ObscuraSearch", dependencies: ["ObscuraSupport", "ObscuraDetect", "ObscuraJournal"], exclude: ["README.md"],
                swiftSettings: strict, linkerSettings: [.linkedFramework("CoreSpotlight")]),
        .target(name: "ObscuraEngine",
                dependencies: ["ObscuraSupport", "ObscuraPrefs", "ObscuraDetect", "ObscuraOCR", "ObscuraRender", "ObscuraJournal", "ObscuraCapture", "ObscuraSearch"], exclude: ["README.md"],
                swiftSettings: strict),
        // G-33: Obscura's own signed update check and verified install (no third-party framework in the app).
        .target(name: "ObscuraUpdate", dependencies: ["ObscuraSupport"], exclude: ["README.md"], swiftSettings: strict),
        // UI (G-7): a shared kit, one module per surface, and a thin XcodeGen app target that composes them.
        .target(name: "ObscuraUIKit", dependencies: ["ObscuraEngine", "ObscuraSupport", "ObscuraPrefs", "ObscuraDetect", "ObscuraRender", "ObscuraJournal", "ObscuraCapture"], exclude: ["README.md"], swiftSettings: strict),
        .target(name: "ObscuraMenuBarUI", dependencies: ["ObscuraUIKit", "ObscuraEngine", "ObscuraJournal", "ObscuraPrefs", "ObscuraDetect", "ObscuraCapture", "ObscuraRender", "ObscuraSupport"], swiftSettings: strict),
        .target(name: "ObscuraJournalUI", dependencies: ["ObscuraUIKit", "ObscuraEngine", "ObscuraJournal", "ObscuraPrefs", "ObscuraDetect", "ObscuraCapture", "ObscuraRender", "ObscuraSupport"], swiftSettings: strict),
        .target(name: "ObscuraViewerUI", dependencies: ["ObscuraUIKit", "ObscuraEngine", "ObscuraJournal", "ObscuraPrefs", "ObscuraDetect", "ObscuraCapture", "ObscuraRender", "ObscuraSupport"], swiftSettings: strict),
        .target(name: "ObscuraSettingsUI", dependencies: ["ObscuraUIKit", "ObscuraEngine", "ObscuraJournal", "ObscuraPrefs", "ObscuraDetect", "ObscuraCapture", "ObscuraRender", "ObscuraSupport"], swiftSettings: strict),
        .target(name: "ObscuraSetupUI", dependencies: ["ObscuraUIKit", "ObscuraEngine", "ObscuraJournal", "ObscuraPrefs", "ObscuraDetect", "ObscuraCapture", "ObscuraRender", "ObscuraSupport"], swiftSettings: strict),
        .target(name: "ObscuraNotifyUI", dependencies: ["ObscuraUIKit", "ObscuraEngine", "ObscuraJournal", "ObscuraPrefs", "ObscuraDetect", "ObscuraCapture", "ObscuraRender", "ObscuraSupport"], swiftSettings: strict),
        .target(name: "ObscuraThumbnailUI", dependencies: ["ObscuraUIKit", "ObscuraEngine", "ObscuraJournal", "ObscuraPrefs", "ObscuraDetect", "ObscuraCapture", "ObscuraRender", "ObscuraSupport"], swiftSettings: strict),
        .executableTarget(name: "obscura", dependencies: ["ObscuraEngine", "ObscuraSearch", "ObscuraUpdate", .product(name: "ArgumentParser", package: "swift-argument-parser")], path: "Tools/obscura", swiftSettings: strict),

        // Helpers shared by test targets only (TestDefaults, ViewSnapshot); not a product, never linked into the app.
        .target(name: "ObscuraTestSupport", path: "Tests/ObscuraTestSupport", swiftSettings: strict),

        .testTarget(name: "ObscuraSupportTests", dependencies: ["ObscuraSupport"]),
        .testTarget(name: "ObscuraPrefsTests", dependencies: ["ObscuraPrefs", "ObscuraTestSupport"]),
        .testTarget(name: "ObscuraDetectTests", dependencies: ["ObscuraDetect"], resources: [.copy("../Fixtures/text")]),
        .testTarget(name: "ObscuraOCRTests", dependencies: ["ObscuraOCR"]),
        .testTarget(name: "ObscuraRenderTests", dependencies: ["ObscuraRender"]),
        .testTarget(name: "ObscuraJournalTests", dependencies: ["ObscuraJournal"]),
        .testTarget(name: "ObscuraCaptureTests", dependencies: ["ObscuraCapture", "ObscuraTestSupport"]),
        .testTarget(name: "ObscuraSearchTests", dependencies: ["ObscuraSearch", "ObscuraJournal", "ObscuraDetect", "ObscuraSupport"]),
        .testTarget(name: "ObscuraEngineTests", dependencies: ["ObscuraEngine", "ObscuraSearch", "ObscuraTestSupport"]),
        .testTarget(name: "ObscuraUpdateTests", dependencies: ["ObscuraUpdate"]),
        .testTarget(name: "ObscuraUIKitTests", dependencies: ["ObscuraUIKit", "ObscuraTestSupport"]),
        .testTarget(name: "ObscuraMenuBarUITests", dependencies: ["ObscuraMenuBarUI", "ObscuraTestSupport"]),
        .testTarget(name: "ObscuraJournalUITests", dependencies: ["ObscuraJournalUI", "ObscuraTestSupport"]),
        .testTarget(name: "ObscuraViewerUITests", dependencies: ["ObscuraViewerUI", "ObscuraTestSupport"]),
        .testTarget(name: "ObscuraSettingsUITests", dependencies: ["ObscuraSettingsUI", "ObscuraTestSupport"]),
        .testTarget(name: "ObscuraSetupUITests", dependencies: ["ObscuraSetupUI", "ObscuraTestSupport"]),
        .testTarget(name: "ObscuraNotifyUITests", dependencies: ["ObscuraNotifyUI"]),
        .testTarget(name: "ObscuraThumbnailUITests", dependencies: ["ObscuraThumbnailUI", "ObscuraEngine", "ObscuraOCR"]),
    ],
    swiftLanguageModes: [.v6]
)
