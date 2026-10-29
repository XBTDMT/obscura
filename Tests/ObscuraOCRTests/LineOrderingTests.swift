import CoreGraphics
import Testing
@testable import ObscuraOCR

@Suite struct LineOrderingTests {
    @Test func twoColumnsReadRowByRow() {
        let lines = [
            line(0, "L1", x: 10, y: 10, w: 100, h: 20),
            line(1, "L2", x: 10, y: 40, w: 100, h: 20),
            line(2, "R1", x: 300, y: 12, w: 100, h: 20),
            line(3, "R2", x: 300, y: 41, w: 100, h: 20),
        ]
        let ordered = LineOrdering.readingOrder(lines.shuffled())
        #expect(ordered.map(\.text) == ["L1", "R1", "L2", "R2"])
        #expect(ordered.map(\.index) == [0, 1, 2, 3])
    }

    @Test func wrappedLinesStayTopToBottom() {
        let lines = [
            line(0, "third", x: 10, y: 70, w: 400, h: 20),
            line(1, "first", x: 10, y: 10, w: 400, h: 20),
            line(2, "second", x: 10, y: 40, w: 380, h: 20),
        ]
        #expect(LineOrdering.readingOrder(lines).map(\.text) == ["first", "second", "third"])
    }

    @Test func toleranceIsHalfLineHeight() {
        // midY 20 vs 29: 9 px apart, half of height 20 is 10 → same row, ordered by minX.
        let near = [line(0, "b", x: 200, y: 10, w: 50, h: 20), line(1, "a", x: 10, y: 19, w: 50, h: 20)]
        #expect(LineOrdering.readingOrder(near).map(\.text) == ["a", "b"])
        // midY 20 vs 31: 11 px apart → separate rows, top first even though its minX is larger.
        let far = [line(0, "b", x: 200, y: 10, w: 50, h: 20), line(1, "a", x: 10, y: 21, w: 50, h: 20)]
        #expect(LineOrdering.readingOrder(far).map(\.text) == ["b", "a"])
    }

    @Test func indexIsReassignedAndEmptyIsFine() {
        #expect(LineOrdering.readingOrder([]).isEmpty)
        let single = LineOrdering.readingOrder([line(7, "x", x: 0, y: 0, w: 1, h: 1)])
        #expect(single.first?.index == 0)
    }
}
