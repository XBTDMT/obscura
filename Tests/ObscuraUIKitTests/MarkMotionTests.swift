import Foundation
import Testing
import ObscuraPrefs
@testable import ObscuraUIKit

/// G-21 "motion": every action is a pure timeline, ≤ 0.6 s (the checking loop aside), never more than two repeats,
/// one final frame under Reduce Motion, and it ends on the state's resting look.
@Suite struct MarkMotionTests {
    static let oneShots = MarkMotion.allCases
    static let pieceCounts = Set(MenuBarMarkID.allCases.map(\.designedPieceCount)).union([1])

    @Test func everyActionIsAtMostSixTenthsOfASecond() {
        for motion in Self.oneShots {
            for pieces in Self.pieceCounts {
                let d = MarkTimeline.duration(motion, pieces: pieces)
                #expect(d > 0 && d <= MarkTimeline.maximumDuration + 1e-9, "\(motion) with \(pieces) pieces lasts \(d) s")
            }
        }
        // The ruled lengths, from the gallery.
        #expect(MarkTimeline.duration(.copyClean, pieces: 1) == 0.3)
        #expect(MarkTimeline.duration(.coverLifts, pieces: 1) == 0.25)
        #expect(MarkTimeline.duration(.pauseCrossFade, pieces: 1) == 0.3)
        #expect(MarkTimeline.duration(.needsYouPop, pieces: 1) == 0.3)
        #expect(MarkTimeline.duration(.updateFade, pieces: 1) == 0.15)
        #expect(abs(MarkTimeline.duration(.clipboardCleaned, pieces: 1) - 0.55) < 1e-9)
        // The snap: 180 ms a piece, staggered by min(30 ms, 270 ms / pieces), then the 0.15 s dot.
        #expect(abs(MarkTimeline.duration(.caught, pieces: 10) - (0.18 + 0.27 + 0.15)) < 1e-9)
        #expect(abs(MarkTimeline.duration(.caught, pieces: 1) - (0.18 + 0.03 + 0.15)) < 1e-9)
    }

    @Test func framesAreSixtyASecondEndingOnTheEnd() {
        for motion in Self.oneShots {
            for pieces in Self.pieceCounts {
                let d = MarkTimeline.duration(motion, pieces: pieces)
                let times = MarkTimeline.frameTimes(motion, pieces: pieces, reduceMotion: false)
                #expect(times.count == Int((d * 60 - 1e-6).rounded(.up)), "\(motion)")
                #expect(times.last == d)
                #expect(zip(times, times.dropFirst()).allSatisfy { $0 < $1 }, "\(motion) frames move forward")
                #expect(times.count <= 36, "≤ 0.6 s at 60 fps")
            }
        }
    }

    @Test func reduceMotionIsOneFinalFrame() {
        for motion in Self.oneShots {
            for pieces in Self.pieceCounts {
                let times = MarkTimeline.frameTimes(motion, pieces: pieces, reduceMotion: true)
                #expect(times == [MarkTimeline.duration(motion, pieces: pieces)], "\(motion)")
                let last = MarkTimeline.pose(motion, pieces: pieces, at: times[0])
                #expect(last == MarkTimeline.finalPose(motion, pieces: pieces))
            }
        }
    }

    @Test func everyActionEndsOnTheRestingLook() {
        for pieces in Self.pieceCounts {
            for motion in Self.oneShots {
                let end = MarkTimeline.finalPose(motion, pieces: pieces)
                switch motion {
                case .coverLifts: #expect(end == .lifted)
                case .dotFadeOut:
                    var gone = MarkPose(); gone.dotOpacity = 0
                    #expect(end == gone)
                default: #expect(end == MarkPose(), "\(motion) ends at rest: \(end)")
                }
                // Played over a lifted cover, every action but the lift's return ends lifted.
                let lifted = MarkTimeline.finalPose(motion, pieces: pieces, lifted: true)
                if motion == .coverReturns { #expect(lifted == MarkPose()) }
                else if motion == .dotFadeOut { #expect(lifted.designedDX == MarkTimeline.liftOffset) }
                else { #expect(lifted == .lifted, "\(motion) over the lifted cover") }
            }
        }
    }

    @Test func caughtSnapsEveryPieceThenShowsTheDot() {
        let pieces = MenuBarMarkID.pixelatedHalf.designedPieceCount
        #expect(pieces == 10)
        let start = MarkTimeline.pose(.caught, pieces: pieces, at: 0)
        #expect(start.pieces?.count == pieces)
        #expect(start.pieces?.allSatisfy { $0.opacity == 0 && $0.scale == 1.9 } == true, "every piece waits large and invisible")
        #expect(start.dotOpacity == 0)
        let lead = MarkTimeline.snapLead(pieces: pieces)
        let settled = MarkTimeline.pose(.caught, pieces: pieces, at: lead)
        #expect(settled.pieces == nil, "all shut by the lead")
        #expect(settled.dotOpacity == 0, "the green dot comes after the snap")
        #expect(MarkTimeline.pose(.caught, pieces: pieces, at: lead + 0.075).dotOpacity > 0.3)
        // The first piece closes before the last starts moving.
        let mid = MarkTimeline.pose(.caught, pieces: pieces, at: 0.2)
        #expect(mid.pieces!.first!.opacity == 1 && mid.pieces!.last!.opacity < 1)
    }

    @Test func theWipeCrossesTheMarkAndTheCoverComesBackFresh() {
        let start = MarkTimeline.pose(.clipboardCleaned, pieces: 1, at: 0)
        #expect(start.wipeX == 0 && abs(start.designedOpacity - 0.2) < 1e-9 && start.dotOpacity == 0)
        let mid = MarkTimeline.pose(.clipboardCleaned, pieces: 1, at: 0.2)
        #expect(mid.wipeX! > 4 && mid.wipeX! < 14)
        let after = MarkTimeline.pose(.clipboardCleaned, pieces: 1, at: 0.41)
        #expect(after.wipeX == nil && after.designedOpacity == 1)
    }

    @Test func thePulseSwellsOnceAndTheLiftStaysLifted() {
        let samples = stride(from: 0.0, through: 0.3, by: 0.01).map { MarkTimeline.pose(.copyClean, pieces: 1, at: $0).markScale }
        let peak = samples.max()!
        #expect(abs(peak - 1.1) < 0.01)
        let i = samples.firstIndex(of: peak)!
        #expect(zip(samples[..<i], samples[1...i]).allSatisfy { $0 <= $1 } && zip(samples[i...], samples[(i + 1)...]).allSatisfy { $0 >= $1 },
                "one swell: up then down, no second repeat")
        #expect(MarkTimeline.finalPose(.coverLifts, pieces: 1).designedDX == 1.3)
        #expect(MarkTimeline.finalPose(.coverLifts, pieces: 1).designedDY == -1.3)
        #expect(MarkTimeline.finalPose(.coverLifts, pieces: 1).designedOpacity == 0.5)
    }

    @Test func thePopOvershootsOnceAndSettles() {
        let scales = stride(from: 0.0, through: 0.3, by: 0.005).map { MarkTimeline.pose(.needsYouPop, pieces: 1, at: $0).dotScale }
        #expect(scales.first == 0 && scales.last == 1)
        #expect(abs(scales.max()! - 1.25) < 0.02)
        #expect(scales.filter { $0 > 1.2 }.count < scales.count / 2)
    }

    @Test func theScanLineLoopsDownAndUp() {
        #expect(MarkTimeline.scanPeriod == 1.1)
        #expect(MarkTimeline.scanFrames == 66)
        #expect(abs(MarkTimeline.scanY(at: 0) - 2.4) < 1e-9)
        #expect(abs(MarkTimeline.scanY(at: 0.55) - 13.6) < 1e-6)
        #expect(abs(MarkTimeline.scanY(at: 1.1) - 2.4) < 1e-6)
        #expect(abs(MarkTimeline.scanY(at: 0.2) - MarkTimeline.scanY(at: 0.9)) < 1e-6, "the way back mirrors the way down")
        #expect(abs(MarkTimeline.scanY(frame: 33) - 13.6) < 1e-6)
        #expect(MarkTimeline.scanRest == 8)
    }

    @Test func theEasingsMatchCSS() {
        for f in [Easing.easeOut, Easing.easeIn, Easing.easeInOut, Easing.snap] {
            #expect(f(0) == 0 && f(1) == 1)
        }
        #expect(abs(Easing.easeInOut(0.5) - 0.5) < 1e-6)
        #expect(Easing.easeOut(0.25) > 0.25 && Easing.easeIn(0.25) < 0.25)
        #expect((0...100).map { Easing.snap(Double($0) / 100) }.max()! > 1.0, "the snap overshoots")
    }

    // MARK: Previews in the picker

    @Test func aHoveredPreviewPlaysTheStatesMotionAndRestsWithout() {
        let still = MarkPreview.frame(mark: .shutter, style: .warm, state: .protected, elapsed: nil, reduceMotion: false)
        #expect(still.pose == MarkPose())
        let hovered = MarkPreview.frame(mark: .shutter, style: .warm, state: .protected, elapsed: 0.05, reduceMotion: false)
        #expect(hovered.pose.pieces != nil, "protected plays the snap on its own look")
        #expect(hovered.state == .protected)
        let reduced = MarkPreview.frame(mark: .shutter, style: .warm, state: .protected, elapsed: 0.05, reduceMotion: true)
        #expect(reduced.pose == MarkPose(), "Reduce Motion: the preview stands still")
        let checking = MarkPreview.frame(mark: .twoTone, style: .warm, state: .checking, elapsed: 0.55, reduceMotion: false)
        #expect(abs(checking.pose.scanY! - 13.6) < 1e-6)
        let classic = MarkPreview.frame(mark: .classic, style: .warm, state: .checking, elapsed: 0.55, reduceMotion: false)
        #expect(abs(classic.sweep - 0.5) < 1e-9, "the Classic ring keeps its sweep")
        let paused = MarkPreview.frame(mark: .orbit, style: .warm, state: .paused, elapsed: 0.1, reduceMotion: false)
        #expect(paused.crossFrom == .protected && paused.pose.crossFade != nil)
        #expect(MarkPreview.motion(for: .needsAttention, mark: .yinYang) == .needsYouPop)
        #expect(MarkPreview.motion(for: .waiting, mark: .yinYang) == .updateFade)
        #expect(MarkPreview.motion(for: .protected, mark: .classic) == nil)
    }
}
