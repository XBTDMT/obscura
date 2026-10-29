import AppKit
import Foundation
import Testing
@testable import ObscuraUIKit

/// The menu bar mark's checking gate (S-9) and the dot's fade frames (S-11).
@Suite struct MarkCheckingGateTests {
    func step(_ gate: inout MarkCheckingGate, _ busy: Bool, _ t: TimeInterval) -> Bool { gate.update(busy: busy, at: t) }

    @Test func aWarmScanNeverShowsChecking() {
        var gate = MarkCheckingGate()
        #expect(!step(&gate, true, 10))
        #expect(gate.nextWakeup() == 10 + MarkTiming.checkingReveal)
        #expect(!step(&gate, false, 10.1), "a ~0.1 s scan ends before the reveal")
        #expect(gate.nextWakeup() == nil)
        #expect(!gate.showsChecking)
    }

    @Test func aSlowCheckShowsAfterTheRevealAndStaysItsMinimum() {
        var gate = MarkCheckingGate()
        gate.update(busy: true, at: 0)
        #expect(!step(&gate, true, 0.29))
        #expect(step(&gate, true, 0.3))
        #expect(gate.nextWakeup() == nil, "nothing to wake for while busy and shown")
        #expect(step(&gate, false, 0.4), "ended 0.1 s after showing: it stays")
        #expect(gate.nextWakeup() == 0.3 + MarkTiming.checkingMinimum)
        #expect(step(&gate, false, 0.84))
        #expect(!step(&gate, false, 0.85))
    }

    @Test func aLongCheckEndsAsSoonAsItIsDone() {
        var gate = MarkCheckingGate()
        gate.update(busy: true, at: 0)
        gate.update(busy: true, at: 0.3)
        #expect(!step(&gate, false, 5), "shown well past its minimum")
    }

    @Test func aNewCheckDuringTheMinimumKeepsShowing() {
        var gate = MarkCheckingGate()
        gate.update(busy: true, at: 0)
        gate.update(busy: true, at: 0.3)
        gate.update(busy: false, at: 0.4)
        #expect(step(&gate, true, 0.5), "a new check while the minimum runs keeps the arc turning")
        #expect(step(&gate, false, 0.6))
        #expect(!step(&gate, false, 0.85))
    }

    @Test func burstsOfWarmScansNeverShowIt() {
        var gate = MarkCheckingGate()
        for i in 0..<10 {
            let t = Double(i)
            #expect(!step(&gate, true, t))
            #expect(!step(&gate, false, t + 0.12))
        }
    }

    @Test func theTimingsComeFromTheDesign() {
        #expect(MarkTiming.checkingReveal == 0.3, "the thumbnail's checking reveal (NOTES.md)")
        #expect(MarkTiming.caughtSeconds == 4, "menubar.html: green dot for about 4 s")
        #expect(MarkTiming.sweepPeriod == 1.1, "system.html o-sp 1.1s")
        #expect(MarkTiming.checkingMinimum == MarkTiming.sweepPeriod / 2)
    }
}

@Suite @MainActor struct MarkDotFadeTests {
    @Test func theDotFadesByOpacity() throws {
        func alphaAtDot(_ opacity: Double) throws -> CGFloat {
            let image = ObscuraMarkDrawing.menuBarImage(.caught, dotOpacity: opacity, scale: 2)
            let tiff = try #require(image.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data: tiff))
            // Inside the caught dot (lower right, 4.8/16 of the mark from its centre), just outside the ring.
            // Typed in two steps: as one literal expression, Xcode 26's type checker gives up on it.
            let points: Double = 9 + 18 * 4.8 / 16 + 1.2
            let p = Int(points * 2)
            return try #require(bitmap.colorAt(x: p, y: p)).alphaComponent
        }
        let full = try alphaAtDot(1), half = try alphaAtDot(0.5), none = try alphaAtDot(0)
        #expect(full > 0.9)
        #expect(half > 0.2 && half < 0.8)
        #expect(none < 0.1)
    }

    @Test func onlyDotChangesOnTheFullRingCanFade() {
        #expect(MarkState.protected.hasFullRing && !MarkState.protected.hasDot)
        #expect(MarkState.caught.hasFullRing && MarkState.caught.hasDot)
        #expect(!MarkState.checking.hasFullRing)
        #expect(!MarkState.paused.hasFullRing)
        #expect(!MarkState.partlyProtected.hasFullRing)
    }
}
