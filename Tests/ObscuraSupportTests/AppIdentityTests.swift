// G-38: one identity, every stored name derived from it, and the build files saying the same.
import Foundation
import Testing
@testable import ObscuraSupport

@Suite struct AppIdentityTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test func theNamesDeriveFromTheBundleIdentifier() {
        let id = AppIdentity(bundleIdentifier: "org.example.app")
        #expect(id.defaultsDomain == "org.example.app")
        #expect(id.logSubsystem == "org.example.app")
        #expect(id.ruleKeyService == "org.example.app.rule-values")
        #expect(id.folderApprovalService == "org.example.app.folder-approvals")
        #expect(id.spotlightDomain == "org.example.app.catches")
        #expect(AppIdentity.current.bundleIdentifier == "io.github.xbtdmt.obscura")
    }

    @Test func anEarlierIdentityIsOnlyAWellFormedOtherOne() {
        #expect(AppIdentity.previous(named: "org.example.earlier") == AppIdentity(bundleIdentifier: "org.example.earlier"))
        #expect(AppIdentity.previous(named: " org.example.earlier ") == AppIdentity(bundleIdentifier: "org.example.earlier"))
        for raw in [nil, "", "   ", AppIdentity.current.bundleIdentifier, "obscura", "org..example", "org.example.", "org.ex ample",
                    "org.example/../x", "org.exämple", "$(OBSCURA_PREVIOUS_IDENTITY)"] as [String?] {
            #expect(AppIdentity.previous(named: raw) == nil, "\(String(describing: raw))")
        }
        #expect(AppIdentity.previous(in: Bundle(for: BundleMarker.self)) == nil, "a bundle that names none")
    }

    /// project.yml, the generated Info.plist and the code agree on the bundle identifier, and the public default names no
    /// earlier identity.
    @Test func theBuildFilesNameTheSameIdentity() throws {
        let project = try String(contentsOf: Self.root.appendingPathComponent("project.yml"), encoding: .utf8)
        let id = AppIdentity.current.bundleIdentifier
        #expect(project.contains("PRODUCT_BUNDLE_IDENTIFIER: \(id)\n"))
        #expect(project.contains("CFBundleIdentifier: \(id)\n"))
        #expect(project.contains("ObscuraPreviousIdentity: $(OBSCURA_PREVIOUS_IDENTITY)\n"))
        let plistData = try Data(contentsOf: Self.root.appendingPathComponent("Apps/Obscura/Resources/Info.plist"))
        let plist = try #require(try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any])
        #expect(plist["CFBundleIdentifier"] as? String == id)
        #expect(plist[AppIdentity.previousIdentityInfoKey] as? String == "$(OBSCURA_PREVIOUS_IDENTITY)")
        let identityConfig = try String(contentsOf: Self.root.appendingPathComponent("Apps/Obscura/Identity.xcconfig"), encoding: .utf8)
        #expect(identityConfig.split(separator: "\n").contains("OBSCURA_PREVIOUS_IDENTITY ="), "empty in the public build")
    }
}

private final class BundleMarker {}
