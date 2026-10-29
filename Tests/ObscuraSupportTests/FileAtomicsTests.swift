import Foundation
import Testing
@testable import ObscuraSupport

@Suite struct FileAtomicsTests {
    @Test func privateWriteSetsModes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("obscura-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("a/b.bin")
        try FileAtomics.write(Data([1, 2, 3]), to: file, mode: .privateToUser)
        let fileMode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as! Int
        let dirMode = try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)[.posixPermissions] as! Int
        #expect(fileMode & 0o777 == 0o600)
        #expect(dirMode & 0o777 == 0o700)
        #expect(try Data(contentsOf: file) == Data([1, 2, 3]))
    }

    @Test func replaceKeepsTargetAndSwapsBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("obscura-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("shot.png")
        try Data("old".utf8).write(to: target)
        try FileAtomics.replace(contentsOf: target, with: Data("new".utf8))
        #expect(try String(decoding: Data(contentsOf: target), as: UTF8.self) == "new")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".obscura-") }
        #expect(leftovers.isEmpty)
    }

    @Test func manualClockAdvances() {
        let clock = ManualClock()
        let t0 = clock.now()
        clock.advance(by: 90)
        #expect(clock.now().timeIntervalSince(t0) == 90)
    }
}
