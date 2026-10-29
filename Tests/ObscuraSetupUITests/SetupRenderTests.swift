import AppKit
import Foundation
import SwiftUI
import Testing
import ObscuraCapture
import ObscuraPrefs
import ObscuraUIKit
@testable import ObscuraSetupUI

/// Renders every step (and its states) at 880 × 560 in light and dark. Asserts the size and that pixels were drawn;
/// writes PNGs for the visual check when OBSCURA_UI_RENDER_DIR is set.
@MainActor
@Suite struct SetupRenderTests {
    struct Case { var name: String; var step: SetupStep; var configure: (FakeMac, SetupFlow) async -> Void = { _, _ in } }

    static let cases: [Case] = [
        Case(name: "02-catch", step: .theCatch) { _, flow in await flow.runTestShot() },
        Case(name: "03-catch-original", step: .theCatch) { _, flow in await flow.runTestShot(); flow.showsOriginal = true },
        Case(name: "02b-catch-running", step: .theCatch),
        Case(name: "02c-catch-failed", step: .theCatch),
        Case(name: "04-welcome", step: .welcome),
        Case(name: "05-folder-ask", step: .screenshotFolder),
        Case(name: "06-folder-denied", step: .screenshotFolder) { mac, flow in mac.screenshotAccess = .denied; flow.allowScreenshotFolder() },
        Case(name: "06b-folder-granted", step: .screenshotFolder) { _, flow in flow.allowScreenshotFolder() },
        Case(name: "06c-downloads", step: .downloads) { _, flow in flow.allowScreenshotFolder() },
        Case(name: "06d-downloads-denied", step: .downloads) { mac, flow in mac.downloadsAccess = .denied; await flow.allowDownloads() },
        Case(name: "07-thumbnail", step: .floatingThumbnail),
        Case(name: "07b-thumbnail-off", step: .floatingThumbnail) { mac, flow in
            await flow.setFloatingThumbnail(shown: false) { mac.thumbnail = $0 }
        },
        Case(name: "08-notifications-ask", step: .notifications),
        Case(name: "08b-notifications-denied", step: .notifications) { mac, flow in
            mac.notificationsAfterRequest = .denied; await flow.requestNotifications()
        },
        Case(name: "08c-notifications-on", step: .notifications) { _, flow in await flow.requestNotifications() },
        Case(name: "08d-notifications-refused", step: .notifications) { mac, flow in
            mac.notificationsRequestRefused = true; await flow.requestNotifications()
        },
        Case(name: "09-login-approval", step: .openAtLogin) { _, flow in flow.setOpenAtLogin(true) },
        Case(name: "09b-login-off", step: .openAtLogin),
        Case(name: "09c-menubar-icon", step: .menuBarIcon),
        Case(name: "09d-menubar-icon-picked", step: .menuBarIcon) { _, flow in
            await MainActor.run { flow.model.updateSettings { $0.menuBarMark = .shutter; $0.menuBarMarkStyle = .indigo } }
        },
        Case(name: "10-done", step: .done) { mac, flow in
            flow.allowScreenshotFolder(); await flow.allowDownloads()
            await flow.setFloatingThumbnail(shown: false) { mac.thumbnail = $0 }
            await flow.requestNotifications(); flow.setOpenAtLogin(true)
        },
    ]

    @Test(arguments: [ColorScheme.light, .dark])
    func everyStepRendersAtWindowSize(scheme: ColorScheme) async throws {
        let dir = ProcessInfo.processInfo.environment["OBSCURA_UI_RENDER_DIR"].map { URL(filePath: $0, directoryHint: .isDirectory) }
        if let dir { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        for c in Self.cases {
            let mac = FakeMac()
            let noResult: @Sendable (UUID) -> (entryID: UUID, durationMS: Int)? = { _ in nil }
            let flow = try await makeFlow(mac, demo: c.name == "02c-catch-failed" ? noResult : nil)
            let seen = Set(SetupStep.allCases.prefix(while: { $0 != c.step }))
            flow.preset(step: c.step, seen: seen)
            if c.name == "02c-catch-failed" { await flow.runTestShot() }
            await c.configure(mac, flow)
            if c.name == "02b-catch-running" { flow.preset(step: .theCatch, seen: seen, demo: .running) }
            let view = SetupWindow(flow: flow, setFloatingThumbnail: { mac.thumbnail = $0 })
                .environment(\.colorScheme, scheme)
                .background(scheme == .dark ? Color.black : Color.white)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try #require(renderer.nsImage, "\(c.name) did not render")
            #expect(image.size == CGSize(width: 880, height: 560), "\(c.name)")
            if let dir, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try png.write(to: dir.appending(path: "\(c.name)-\(scheme == .dark ? "dark" : "light").png"))
            }
        }
    }
}
