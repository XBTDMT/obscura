import Foundation
import ServiceManagement
import Testing
import ObscuraTestSupport
@testable import ObscuraCapture

@Suite(.serialized) struct ScreenshotFolderTests {
    @Test func fallsBackToDesktopWhenKeyAbsent() throws {
        let defaults = TestDefaults("screencapture").defaults
        #expect(ScreenshotFolder.current(defaults: defaults) == ScreenshotFolder.desktop)
        #expect(ScreenshotFolder.floatingThumbnailEnabled(defaults: defaults) == true)
    }

    @Test func readsTildeExpandedDirectoryAndRejectsMissing() throws {
        let defaults = TestDefaults("screencapture").defaults
        let dir = try TestSupport.makeTempDirectory("shots")
        defer { try? FileManager.default.removeItem(at: dir) }

        defaults.set(dir.path, forKey: ScreenshotFolder.locationKey)
        #expect(ScreenshotFolder.current(defaults: defaults).resolvingSymlinksInPath().path == dir.path)

        defaults.set("~/Desktop", forKey: ScreenshotFolder.locationKey)
        #expect(ScreenshotFolder.current(defaults: defaults).path.hasSuffix("/Desktop"))

        defaults.set(dir.appending(path: "nope").path, forKey: ScreenshotFolder.locationKey)
        #expect(ScreenshotFolder.current(defaults: defaults) == ScreenshotFolder.desktop)

        defaults.set(false, forKey: ScreenshotFolder.thumbnailKey)
        #expect(ScreenshotFolder.floatingThumbnailEnabled(defaults: defaults) == false)
    }
}

@Suite struct FolderAccessTests {
    @Test func grantedOnTempDirectory() throws {
        let dir = try TestSupport.makeTempDirectory("access")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(FolderAccess.probe(dir) == .granted)
    }

    @Test func missingOnNonexistentPath() {
        #expect(FolderAccess.probe(URL(filePath: "/nonexistent/obscura/\(UUID().uuidString)")) == .missing)
    }

    @Test func deniedOnUnreadableDirectory() throws {
        let dir = try TestSupport.makeTempDirectory("locked")
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path); try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dir.path)
        // root ignores mode bits; only assert when the process is not root.
        if getuid() != 0 {
            #expect(FolderAccess.probe(dir) == .denied)
        }
    }

    @Test func classifiesPOSIXErrors() {
        #expect(FolderAccess.classify(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))) == .denied)
        #expect(FolderAccess.classify(NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))) == .denied)
        #expect(FolderAccess.classify(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))) == .missing)
    }
}

@Suite struct LoginItemTests {
    @Test func statusDoesNotCrash() {
        // Not toggled: that would change the user's login items. A test bundle is not a registrable app.
        let status = LoginItem.status()
        #expect([.enabled, .disabled, .requiresApproval, .notFound].contains(status))
     }

    @Test func notFoundInsideApplicationsIsPlainOff() {
        #expect(LoginItem.classify(.notFound, inApplications: true) == .disabled)
        #expect(LoginItem.classify(.notRegistered, inApplications: true) == .disabled)
        #expect(LoginItem.classify(.notFound, inApplications: false) == .notFound)
        #expect(LoginItem.classify(.enabled, inApplications: false) == .enabled)
        #expect(LoginItem.classify(.requiresApproval, inApplications: true) == .requiresApproval)
    }

    @Test func applicationsFolderIsSystemOrUserAtAnyDepth() {
        let home = URL(filePath: "/home/example", directoryHint: .isDirectory)
        #expect(LoginItem.isInApplicationsFolder(URL(filePath: "/Applications/Obscura.app"), home: home))
        #expect(LoginItem.isInApplicationsFolder(URL(filePath: "/Applications/Utilities/Obscura.app"), home: home))
        #expect(LoginItem.isInApplicationsFolder(URL(filePath: "/home/example/Applications/Obscura.app"), home: home))
        #expect(!LoginItem.isInApplicationsFolder(URL(filePath: "/private/tmp/build/Debug/Obscura.app"), home: home))
        #expect(!LoginItem.isInApplicationsFolder(URL(filePath: "/ApplicationsOld/Obscura.app"), home: home))
        #expect(!LoginItem.isInApplicationsFolder(URL(filePath: "/home/example/Downloads/Obscura.app"), home: home))
    }
}

@Suite struct ImportSourceTests {
    @Test func submitEmitsImportedFiles() async {
        let source = ImportSource()
        var it = source.events.makeAsyncIterator()
        let a = URL(filePath: "/tmp/a.png"), b = URL(filePath: "/tmp/b.png")
        source.submit([a, b])
        let first = await nextEvent(&it)
        let second = await nextEvent(&it)
        #expect(first?.fileURL == a && first?.origin == .imported)
        #expect(second?.fileURL == b)
    }
}
