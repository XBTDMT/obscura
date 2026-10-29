import CoreGraphics
import Foundation
import Testing
@testable import ObscuraOCR

@Suite struct WidenToTokenTests {
    let text = "TOKEN=abc123xyz789 next"

    @Test func midTokenRangeGrowsToTheValueNotOverTheKeyName() {
        let r = BoxMapper.widenToToken(NSRange(location: 6, length: 6), in: text)   // "abc123" → "abc123xyz789", never "TOKEN="
        #expect(r == NSRange(location: 6, length: 12))
    }

    @Test func wholeTokenIsUnchanged() {
        #expect(BoxMapper.widenToToken(NSRange(location: 19, length: 4), in: text) == NSRange(location: 19, length: 4))
    }

    @Test func rangeTouchingWhitespaceStopsThere() {
        #expect(BoxMapper.widenToToken(NSRange(location: 18, length: 0), in: text) == NSRange(location: 6, length: 12))
    }

    @Test func outOfBoundsAndEmptyText() {
        #expect(BoxMapper.widenToToken(NSRange(location: 50, length: 3), in: text) == NSRange(location: 19, length: 4))
        #expect(BoxMapper.widenToToken(NSRange(location: 0, length: 3), in: "") == NSRange(location: 0, length: 0))
    }

    @Test func quotesAndColonsFrameAValue() {
        let quoted = "api_key: \"sk_abc123\","
        // "abc" inside the quotes widens to the quoted value only.
        #expect(BoxMapper.widenToToken(NSRange(location: 13, length: 3), in: quoted) == NSRange(location: 10, length: 9))
    }

    @Test func colonsInsideTheMatchStay() {
        let url = "DATABASE_URL=postgres://app:pass@db.example.com/app"
        let match = NSRange(location: 13, length: 38)   // the whole URL, with its own colons
        #expect(BoxMapper.widenToToken(match, in: url) == match)
    }

    @Test func aPasswordInAURLStopsAtTheAtSign() {
        let url = "DATABASE_URL=postgres://app:UJ3S7t8X@db.example.internal:5432/app"
        let password = NSRange(location: 28, length: 4)   // inside "UJ3S7t8X"
        #expect(BoxMapper.widenToToken(password, in: url) == NSRange(location: 28, length: 8))
    }

    @Test func tabsAndNonBreakingSpaceSplit() {
        #expect(BoxMapper.widenToToken(NSRange(location: 3, length: 1), in: "ab\tcd\u{00A0}ef") == NSRange(location: 3, length: 2))
    }
}

@Suite struct BoxMapperRectTests {
    // 20 characters across 200 px → 10 px per character.
    let lineRect = CGRect(x: 100, y: 50, width: 200, height: 20)
    let text = "aaaaaaaaa bbbbbbbbbb"   // 9 + space + 10

    @Test func providerBoxAccepted() {
        let box = CGRect(x: 205, y: 52, width: 95, height: 16)
        let l = OCRLine(index: 0, text: text, rect: lineRect, candidate: FixedBoxes(box: box))
        let r = BoxMapper.rect(forUTF16Range: NSRange(location: 12, length: 3), in: l)
        // Widened to the 10-char token; glyph 9.5 px; pad 4.75 each side; clipped to line −2 (x ≤ 302).
        #expect(abs(r.minX - 200.25) < 0.01)
        #expect(abs(r.maxX - 302) < 0.01)
        #expect(r.minY == 52 && r.height == 16)
    }

    @Test func wholeWordBoxIsNarrowedToTheValue() {
        // As measured live: Vision answers a part of a word with the whole word's box, and in KEY=value the word is
        // the whole line. 14 characters across 140 px → 10 px each; the value starts at character 4.
        let line = CGRect(x: 100, y: 50, width: 140, height: 20)
        let l = OCRLine(index: 0, text: "KEY=abcdefghij", rect: line, candidate: FixedBoxes(box: line))
        let r = BoxMapper.rect(forUTF16Range: NSRange(location: 4, length: 10), in: l)
        // Value 140..240, glyph 10 → pad 5 → 135..245, clipped to the line −2 → 135..242. The key name stays visible.
        #expect(abs(r.minX - 135) < 0.01 && abs(r.maxX - 242) < 0.01)
    }

    @Test func providerBoxTooNarrowFallsBack() {
        let l = OCRLine(index: 0, text: text, rect: lineRect, candidate: FixedBoxes(box: CGRect(x: 200, y: 50, width: 1, height: 20)))
        let r = BoxMapper.rect(forUTF16Range: NSRange(location: 10, length: 10), in: l)
        // Proportional: x 200..300, glyph 10 → pad 5 → 195..302 (clip at 302).
        #expect(abs(r.minX - 195) < 0.01 && abs(r.maxX - 302) < 0.01)
    }

    @Test func providerBoxOffTheLineFallsBack() {
        let l = OCRLine(index: 0, text: text, rect: lineRect, candidate: FixedBoxes(box: CGRect(x: 200, y: 400, width: 90, height: 20)))
        let r = BoxMapper.rect(forUTF16Range: NSRange(location: 10, length: 10), in: l)
        #expect(abs(r.minX - 195) < 0.01 && abs(r.maxX - 302) < 0.01)
    }

    @Test func nilProviderUsesProportional() {
        let l = OCRLine(index: 0, text: text, rect: lineRect, candidate: FixedBoxes(box: nil))
        let r = BoxMapper.rect(forUTF16Range: NSRange(location: 0, length: 9), in: l)
        // 100..190, pad 5 → 98 (clip) .. 195.
        #expect(abs(r.minX - 98) < 0.01 && abs(r.maxX - 195) < 0.01)
    }

    @Test func paddingParameterAddsOnAllSides() {
        let l = OCRLine(index: 0, text: text, rect: lineRect)
        let r = BoxMapper.rect(forUTF16Range: NSRange(location: 10, length: 10), in: l, padding: 2)
        #expect(abs(r.minX - 193) < 0.01 && abs(r.maxX - 302) < 0.01)
        #expect(abs(r.minY - 48) < 0.01 && abs(r.maxY - 72) < 0.01)
    }

    @Test func emptyRangeUsesHeightGlyphEstimate() {
        let l = OCRLine(index: 0, text: "", rect: lineRect)
        let r = BoxMapper.rect(forUTF16Range: NSRange(location: 0, length: 0), in: l)
        // glyph = 20 × 0.25 = 5 → half is 2.5 each side around x=100 → 97.5 clipped to 98, width 4.5.
        #expect(abs(r.minX - 98) < 0.01 && abs(r.maxX - 102.5) < 0.01)
    }
}
