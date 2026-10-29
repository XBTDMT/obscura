import CoreGraphics
import Foundation
import ObscuraCapture
import ObscuraDetect
import ObscuraJournal
import ObscuraOCR
import ObscuraPrefs
import ObscuraRender
import ObscuraSupport
import Testing
@testable import ObscuraEngine

@Suite struct ShieldEngineScanTests {
    @Test func keyLineIsRedactedAndJournaled() async throws {
        let h = try Harness()
        defer { h.tearDown() }
        let original = Fixture.pngData()
        let outcome = await h.scan(original)
        guard case .redacted(let entryID, let count, _) = outcome else { Issue.record("expected redacted, got \(outcome)"); return }
        #expect(count == 1)

        let entry = try await h.journal.entry(entryID)
        #expect(entry.findings.count == 1)
        #expect(entry.findings[0].detectorIDs.contains("payments.stripe.secretkey"), "union merge keeps every contributing id: \(entry.findings[0].detectorIDs)")
        #expect(try await h.journal.originalData(entryID) == original)
        let cleanData = try await h.journal.cleanData(entryID)
        #expect(cleanData != original)

        // The clean image differs from the original only inside the (padded) finding rect.
        let before = try Fixture.decode(original), after = try Fixture.decode(cleanData)
        let rect = entry.findings[0].rect
        let padded = Redactor.paddedRect(for: PlacedFinding(rect: rect, textHeight: Fixture.keyLine.rect.height, label: ""),
                                         style: StyleBridge.spec(from: entry.style), imageSize: CGSize(width: before.width, height: before.height))!
        let diffs = Fixture.differingPixels(before, after)
        #expect(!diffs.isEmpty)
        #expect(diffs.allSatisfy { padded.insetBy(dx: -1, dy: -1).contains($0) }, "a pixel outside the box changed")
        #expect(diffs.contains { rect.contains($0) }, "nothing inside the finding rect changed")
        // The key line is covered; the plain line is not.
        #expect(!diffs.contains { Fixture.plainLine.rect.insetBy(dx: 4, dy: 4).contains($0) })

        let week = try await h.journal.weekStats()
        #expect(week.last?.caught == 1 && week.last?.secrets == 1)
        let status = await h.engine.currentStatus()
        #expect(status.lastCatch?.entryID == entryID && status.lastCatch?.findings == 1)
        #expect(status.protection == .protected)
    }

    /// Redman 2026-10-27: a real day read checked 8, caught 9. Only the clean short-circuit counted `checked`, so every
    /// redacted image (a file, an import, the setup demo, a clipboard copy) raised `caught` and left `checked` alone.
    @Test func everyCaughtImageIsCountedAsCheckedSoCaughtNeverExceedsChecked() async throws {
        let h = try Harness()
        defer { h.tearDown() }
        for source in [EntrySource.file, .imported, .demo, .clipboard] {
            let outcome = await h.engine.scan(imageData: Fixture.pngData(), source: source, displayName: "Test shot", filePath: nil, origin: nil)
            #expect(outcome.isRedacted, "\(source): \(outcome)")
        }
        let caughtDay = try #require(try await h.journal.weekStats().last)
        #expect(caughtDay.caught == 4 && caughtDay.secrets == 4)
        #expect(caughtDay.checked == 4, "each caught image was checked")
        #expect(caughtDay.caught <= caughtDay.checked)

        // A clean image adds a check and no catch.
        let clean = try Harness(recognizer: StubTextRecognizer(lines: [Fixture.plainLine]))
        defer { clean.tearDown() }
        #expect(await clean.scan().isClean)
        #expect(await clean.engine.scan(imageData: Fixture.pngData(), source: .demo, displayName: "Test shot", filePath: nil, origin: nil).isClean)
        let cleanDay = try #require(try await clean.journal.weekStats().last)
        #expect(cleanDay.checked == 2 && cleanDay.caught == 0)
    }

    @Test func cleanImageLeavesNoEntryAndCountsChecked() async throws {
        let h = try Harness(recognizer: StubTextRecognizer(lines: [Fixture.plainLine]))
        defer { h.tearDown() }
        let outcome = await h.scan()
        #expect(outcome.isClean)
        #expect(try await h.journal.entries(matching: .live).isEmpty)
        #expect(try await h.journal.weekStats().last?.checked == 1)
    }

    @Test func decodeFailureIsSkippedAndRecorded() async throws {
        let h = try Harness()
        defer { h.tearDown() }
        let outcome = await h.scan(Fixture.corruptPNG)
        #expect(outcome.skipReason == .decodeFailed)
        #expect(try await h.journal.weekStats().last?.skipped["decodeFailed"] == 1)
    }

    @Test func nonImageBytesAreNotAnImage() async throws {
        let h = try Harness()
        defer { h.tearDown() }
        let outcome = await h.scan(Data("just text".utf8))
        // CGImageSource cannot identify the container: ImageCodec says notAnImage, which the engine files as a decode failure
        // (the bytes claimed to be a screenshot and were not); an unsupported-but-real container is notAnImage.
        #expect(outcome.skipReason == .decodeFailed)
    }

    @Test func ocrTimeoutIsSkipped() async throws {
        let h = try Harness(recognizer: ScriptedRecognizer(error: .timeout))
        defer { h.tearDown() }
        #expect(await h.scan().skipReason == .ocrTimeout)
        #expect(try await h.journal.weekStats().last?.skipped["ocrTimeout"] == 1)
    }

    @Test func ocrFailureIsSkipped() async throws {
        let h = try Harness(recognizer: ScriptedRecognizer(error: .failed(underlying: CocoaError(.fileReadUnknown))))
        defer { h.tearDown() }
        #expect(await h.scan().skipReason == .ocrFailed)
    }

    @Test func pausedEngineSkipsEverything() async throws {
        let h = try Harness()
        defer { h.tearDown() }
        await h.engine.pause()
        #expect(await h.scan().skipReason == .protectionPaused)
        #expect(await h.engine.currentStatus().protection == .paused)
        await h.engine.resume()
        #expect(await h.scan().isRedacted)
    }

    @Test func settingsPauseIsHonoured() async throws {
        var s = Settings.default
        s.protectionPaused = true
        let h = try Harness(settings: s)
        defer { h.tearDown() }
        #expect(await h.scan().skipReason == .protectionPaused)
    }
}

@Suite struct ShieldEngineWriteBackTests {
    @Test func replaceModeOverwritesTheFile() async throws {
        let dir = try Fixture.tempDirectory("replace")
        defer { try? FileManager.default.removeItem(at: dir) }
        let h = try Harness()
        defer { h.tearDown() }
        let file = dir.appendingPathComponent("Shot.png")
        let original = Fixture.pngData()
        try original.write(to: file)
        let outcome = await h.scan(original, name: "Shot.png", filePath: file, origin: .screenshotFolder)
        guard case .redacted(let entryID, _, _) = outcome else { Issue.record("\(outcome)"); return }
        let onDisk = try Data(contentsOf: file)
        #expect(onDisk != original)
        #expect(onDisk == (try await h.journal.cleanData(entryID)))
        let entry = try await h.journal.entry(entryID)
        #expect(entry.filePath == file.path && entry.cleanCopyPath == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["Shot.png"])
    }

    @Test func keepBothWritesTheSibling() async throws {
        let dir = try Fixture.tempDirectory("keepboth")
        defer { try? FileManager.default.removeItem(at: dir) }
        var s = Settings.default
        s.fileHandling = .keepBoth
        let h = try Harness(settings: s)
        defer { h.tearDown() }
        let file = dir.appendingPathComponent("Shot.png")
        let original = Fixture.pngData()
        try original.write(to: file)
        let outcome = await h.scan(original, name: "Shot.png", filePath: file, origin: .screenshotFolder)
        guard case .redacted(let entryID, _, _) = outcome else { Issue.record("\(outcome)"); return }
        #expect(try Data(contentsOf: file) == original, "keepBoth must not touch the original")
        let sibling = dir.appendingPathComponent("Shot (clean).png")
        #expect(try Data(contentsOf: sibling) == (try await h.journal.cleanData(entryID)))
        #expect(try await h.journal.entry(entryID).cleanCopyPath == sibling.path)
    }

    @Test func importedFilesAreNeverWritten() async throws {
        let dir = try Fixture.tempDirectory("import")
        defer { try? FileManager.default.removeItem(at: dir) }
        let h = try Harness()
        defer { h.tearDown() }
        let file = dir.appendingPathComponent("Import.png")
        let original = Fixture.pngData()
        try original.write(to: file)
        #expect(await h.scan(original, name: "Import.png", filePath: file, origin: .imported).isRedacted)
        #expect(try Data(contentsOf: file) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["Import.png"])
    }

    @Test func cleanSiblingKeepsCompatibleExtensionOnly() {
        let png = ShieldEngine.cleanSibling(of: URL(fileURLWithPath: "/x/Shot.PNG"), output: .png)
        #expect(png.lastPathComponent == "Shot (clean).PNG")
        let jpg = ShieldEngine.cleanSibling(of: URL(fileURLWithPath: "/x/Photo.jpeg"), output: .jpeg)
        #expect(jpg.lastPathComponent == "Photo (clean).jpeg")
        let tiff = ShieldEngine.cleanSibling(of: URL(fileURLWithPath: "/x/Scan.tiff"), output: .png)
        #expect(tiff.lastPathComponent == "Scan (clean).png", "a PNG body never hides under a .tiff name")
    }

    @Test func restoreOriginalPutsTheBytesBack() async throws {
        let dir = try Fixture.tempDirectory("restore")
        defer { try? FileManager.default.removeItem(at: dir) }
        let h = try Harness()
        defer { h.tearDown() }
        let file = dir.appendingPathComponent("Shot.png")
        let original = Fixture.pngData()
        try original.write(to: file)
        guard case .redacted(let entryID, _, _) = await h.scan(original, name: "Shot.png", filePath: file, origin: .screenshotFolder) else {
            Issue.record("not redacted"); return
        }
        #expect(try Data(contentsOf: file) != original)
        try await h.engine.restoreOriginal(entryID)
        #expect(try Data(contentsOf: file) == original)
    }
}

@Suite struct ShieldEngineRerenderTests {
    /// Two secrets on two lines; disabling one must leave its rect untouched after the re-render.
    static let twoKeys = [
        OCRLine(index: 0, text: "a=\(Fixture.fakeKey)", rect: CGRect(x: 20, y: 15, width: 400, height: 26)),
        OCRLine(index: 1, text: "b=sk_live_hxgA0cdG1ByO0aWgZI1lDAbJA1n6AA", rect: CGRect(x: 20, y: 75, width: 400, height: 26)),
    ]

    @Test func disablingAFindingLeavesItsRectUntouched() async throws {
        let h = try Harness(recognizer: StubTextRecognizer(lines: Self.twoKeys))
        defer { h.tearDown() }
        let original = Fixture.pngData()
        guard case .redacted(let entryID, let count, _) = await h.scan(original) else { Issue.record("not redacted"); return }
        #expect(count == 2)
        var entry = try await h.journal.entry(entryID)
        let second = try #require(entry.findings.first { $0.lineIndex == 1 })
        let first = try #require(entry.findings.first { $0.lineIndex == 0 })

        try await h.engine.setFinding(second.id, enabled: false, in: entryID)
        entry = try await h.journal.entry(entryID)
        #expect(entry.revision == 2)
        #expect(entry.enabledFindings.map { $0.id } == [first.id])

        let before = try Fixture.decode(original), after = try Fixture.decode(try await h.journal.cleanData(entryID))
        let diffs = Fixture.differingPixels(before, after)
        #expect(!diffs.isEmpty)
        #expect(!diffs.contains { second.rect.contains($0) }, "the disabled finding's rect changed")
        #expect(diffs.contains { first.rect.contains($0) })
    }

    @Test func rerenderWithStyleStoresItAndFollowsTheFile() async throws {
        let dir = try Fixture.tempDirectory("rerender")
        defer { try? FileManager.default.removeItem(at: dir) }
        let h = try Harness()
        defer { h.tearDown() }
        let file = dir.appendingPathComponent("Shot.png")
        let original = Fixture.pngData()
        try original.write(to: file)
        guard case .redacted(let entryID, _, _) = await h.scan(original, name: "Shot.png", filePath: file, origin: .screenshotFolder) else {
            Issue.record("not redacted"); return
        }
        let firstClean = try Data(contentsOf: file)
        var style = StyleSpec.defaultStyle
        style.kind = .mosaic
        try await h.engine.rerender(entryID, style: style)
        let entry = try await h.journal.entry(entryID)
        #expect(entry.style.kind == .mosaic && entry.revision == 2)
        let secondClean = try Data(contentsOf: file)
        #expect(secondClean != firstClean && secondClean != original)
        #expect(secondClean == (try await h.journal.cleanData(entryID)))
    }

    @Test func rerenderUnknownEntryThrows() async throws {
        let h = try Harness()
        defer { h.tearDown() }
        await #expect(throws: EngineError.entryNotFound(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)) {
            try await h.engine.rerender(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, style: nil)
        }
    }
}

@Suite struct ShieldEngineCatalogueTests {
    @Test func customRuleAndOverrideArePickedUpOnCatalogueChanged() async throws {
        let lines = [
            OCRLine(index: 0, text: "the launch code is kumquat-sunrise-42", rect: CGRect(x: 10, y: 10, width: 400, height: 24)),
            OCRLine(index: 1, text: "token zz-abcdefghijklmnop ok", rect: CGRect(x: 10, y: 50, width: 400, height: 24)),
        ]
        let h = try Harness(recognizer: StubTextRecognizer(lines: lines))
        defer { h.tearDown() }
        #expect(await h.scan().isClean, "nothing in the built-in catalogue should match these lines")

        let ruleID = "custom." + UUID().uuidString
        try await h.journal.upsertRule(RuleRecord(id: ruleID, action: .blackOut, kind: .exactText, value: "kumquat-sunrise-42",
                                                  name: "Launch code", createdAt: h.clock.now(), sortOrder: 0))
        let specs = try JSONEncoder().encode([PatternSpec.prefix("zz-", n: 8)])
        try await h.journal.setOverride("ai.openai.apikey", specsJSON: String(decoding: specs, as: UTF8.self))
        // Not yet recompiled: the scan still runs on the old catalogue.
        #expect(await h.scan().isClean)

        await h.engine.catalogueChanged()
        guard case .redacted(let entryID, let count, _) = await h.scan() else { Issue.record("not redacted"); return }
        #expect(count == 2)
        let ids = try await h.journal.entry(entryID).findings.map { $0.detectorIDs[0] }.sorted()
        #expect(ids == [ruleID, "ai.openai.apikey"].sorted())
    }

    @Test func ruleThatDoesNotCompileBecomesAProblem() async throws {
        let h = try Harness()
        defer { h.tearDown() }
        try await h.journal.upsertRule(RuleRecord(action: .blackOut, kind: .regex, value: "(unclosed", createdAt: h.clock.now(), sortOrder: 0))
        await h.engine.catalogueChanged()
        let status = await h.engine.currentStatus()
        #expect(status.problems.contains { $0.kind == .ruleCompile })
        #expect(await h.scan().isRedacted, "a bad user rule never stops the built-ins")
        guard case .partlyProtected(let reasons) = status.protection else {
            Issue.record("a rule that does not compile lowers protection, got \(status.protection)"); return
        }
        #expect(reasons.contains("protection.rulesSkipped"))
    }

    /// Fail-open #3: an edited Stripe pattern that does not compile used to remove the Stripe detector, so the key stayed
    /// visible while the status said Protected. Now the built-in patterns cover it, the problem has its own key, and the
    /// status is partly protected.
    @Test func anOverrideThatDoesNotCompileFallsBackToTheBuiltInAndLowersProtection() async throws {
        let h = try Harness()
        defer { h.tearDown() }
        let specs = try JSONEncoder().encode([PatternSpec.regex("(unclosed")])
        try await h.journal.setOverride("payments.stripe.secretkey", specsJSON: String(decoding: specs, as: UTF8.self))
        await h.engine.catalogueChanged()

        guard case .redacted(let entryID, let count, _) = await h.scan() else { Issue.record("the built-in patterns must still cover the key"); return }
        #expect(count == 1)
        #expect(try await h.journal.entry(entryID).findings.map { $0.detectorIDs[0] } == ["payments.stripe.secretkey"])

        let status = await h.engine.currentStatus()
        let problem = try #require(status.problems.first { $0.kind == .ruleCompile })
        #expect(problem.messageKey == "problem.override.compile")
        #expect(problem.detail?.hasPrefix("payments.stripe.secretkey:") == true)
        guard case .partlyProtected(let reasons) = status.protection else {
            Issue.record("an override on its built-in fallback is not plain Protected, got \(status.protection)"); return
        }
        #expect(reasons == ["protection.rulesSkipped"])
    }

    @Test func styleBridgeRoundTrips() {
        let spec = StyleSpec(kind: .blur, color: RGBA(r: 0.25, g: 0.5, b: 0.75, a: 1), roundness: 0.3, padding: 0.2, labelMode: .kind)
        let record = StyleBridge.record(from: spec)
        #expect(record.kind == .blur && record.labelMode == .kind && record.color == "0.25,0.5,0.75,1")
        #expect(StyleBridge.spec(from: record) == spec)
        #expect(StyleBridge.rgba(from: "garbage") == RGBA(r: 0, g: 0, b: 0, a: 1))
        #expect(StyleBridge.spec(from: .builtInDefault).kind == .solid)
    }

    @Test func maintenanceTickPrunesByRetention() async throws {
        var s = Settings.default
        s.journalRetention = .oneHour
        let h = try Harness(settings: s)
        defer { h.tearDown() }
        #expect(await h.scan().isRedacted)
        h.clock.advance(by: 2 * 3600)
        await h.engine.maintenanceTick()
        #expect(try await h.journal.entries(matching: .live).isEmpty)
    }
}

/// Real FSEvents on a temp folder, like the Capture tests.
@Suite(.serialized) struct ShieldEngineRunLoopTests {
    @Test func burstOfTwentyFilesAllEndInAnOutcome() async throws {
        let dir = try Fixture.tempDirectory("burst")
        defer { try? FileManager.default.removeItem(at: dir) }
        // The settings own the watched folders (the engine applies them at start and on every change), so the test
        // folder is an extra folder and the real screenshot folder is switched off.
        var settings = Settings.default
        settings.guardsScreenshotFolder = false
        settings.extraFolders = [dir.path]
        let watcher = FolderWatcher(roots: ShieldEngine.watchedRoots(from: settings, approvals: [try #require(FolderApproval.current(dir, at: Date()))]))
        let h = try Harness(settings: settings, sources: [watcher], folderWatcher: watcher)
        defer { h.tearDown() }
        let outcomes = h.engine.outcomes
        let runner = Task { await h.engine.run() }
        defer { runner.cancel() }
        // The watcher opens before the warm-up (run()'s order), so this waits for a condition, not a fixed time.
        let started = ContinuousClock.now
        while !(await watcher.isRunning), ContinuousClock.now - started < .seconds(10) { try await Task.sleep(for: .milliseconds(20)) }
        #expect(await watcher.isRunning)

        let png = Fixture.pngData()
        for i in 0..<20 {
            let temp = dir.appendingPathComponent(".shot-\(i).tmp")
            try png.write(to: temp)
            try FileManager.default.moveItem(at: temp, to: dir.appendingPathComponent("Shot \(i).png"))
        }
        let reports = await collect(outcomes, count: 20, timeout: .seconds(20))
        #expect(reports.count == 20, "every image must end in exactly one outcome")
        let labels = reports.map { $0.outcome.statLabel }
        #expect(reports.allSatisfy { $0.outcome.isRedacted }, "\(labels)")
        #expect(Set(reports.compactMap { $0.key }).count == 20)
        let liveCount = try await h.journal.entries(matching: .live).count
        #expect(liveCount == 20)
        // Replace mode wrote every file back without triggering a second scan of our own write.
        try await Task.sleep(for: .milliseconds(600))
        let extra = await collect(outcomes, count: 1, timeout: .milliseconds(300))
        #expect(extra.isEmpty, "our own write-back must not re-enter the pipeline")
        await watcher.stop()
    }

    @Test func repeatedKeyCancelsTheOlderScan() async throws {
        let h = try Harness(recognizer: ScriptedRecognizer(lines: [Fixture.keyLine], delay: .milliseconds(400)))
        defer { h.tearDown() }
        let dir = try Fixture.tempDirectory("cancel")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("Same.png")
        try Fixture.pngData().write(to: file)
        let outcomes = h.engine.outcomes
        await h.engine.submit(.file(file, origin: .imported))
        try await Task.sleep(for: .milliseconds(50))
        await h.engine.submit(.file(file, origin: .imported))
        let reports = await collect(outcomes, count: 2, timeout: .seconds(5))
        #expect(reports.count == 2)
        #expect(reports.filter { $0.outcome.skipReason == .cancelled }.count == 1)
        #expect(reports.filter { $0.outcome.isRedacted }.count == 1)
        #expect(try await h.journal.entries(matching: .live).count == 1, "the cancelled scan wrote nothing")
        #expect(await h.engine.currentStatus().inFlight == 0)
    }

    @Test func nonImageFileEventIsSkippedNotDropped() async throws {
        let h = try Harness()
        defer { h.tearDown() }
        let dir = try Fixture.tempDirectory("txt")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: file)
        let outcomes = h.engine.outcomes
        await h.engine.submit(.file(file, origin: .screenshotFolder))
        let reports = await collect(outcomes, count: 1, timeout: .seconds(2))
        #expect(reports.first?.outcome.skipReason == .notAnImage)
    }

    @Test func statusStreamReplaysLatestToNewConsumers() async throws {
        let h = try Harness()
        defer { h.tearDown() }
        await h.engine.pause()
        var it = h.engine.status.makeAsyncIterator()
        let first = await it.next()
        #expect(first?.protection == .paused)
    }
}
