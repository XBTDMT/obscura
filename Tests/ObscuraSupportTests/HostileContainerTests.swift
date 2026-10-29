// Security scan 2026-10-28, F1 and F3: a TIFF whose entries point at the same bytes again and again made the container
// walk do entries × values work (and queue that many IFD offsets) on a file of a few kilobytes. Every file here is built
// in the test, small, and scaled so the old walk's work is a known multiple of the new budget; the work counter, not
// the clock, is what is checked.
import Foundation
import Testing
@testable import ObscuraSupport

@Suite struct HostileContainerTests {
    /// A classic little-endian TIFF builder: IFDs and value regions placed at known offsets.
    struct TIFF {
        var bytes: [UInt8] = Array("II".utf8) + [42, 0, 8, 0, 0, 0]

        mutating func u16(_ v: Int) { bytes += [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] }
        mutating func u32(_ v: Int) { bytes += [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)] }
        /// One IFD at the current end: `entries` of (tag, type, count, value-or-offset), then the next IFD's offset.
        mutating func ifd(_ entries: [(tag: Int, type: Int, count: Int, value: Int)], next: Int) {
            u16(entries.count)
            for e in entries { u16(e.tag); u16(e.type); u32(e.count); u32(e.value) }
            u32(next)
        }
        static func ifdSize(entries: Int) -> Int { 2 + 12 * entries + 4 }
        var data: Data { Data(bytes) }
    }

    static func walk(_ data: Data) -> (ImageContainer.Completeness?, Int) {
        let (result, work) = ImageContainer.walk(data, shouldStop: { false })
        return (result, work)
    }

    /// F3's file, scaled down: one IFD of 2,000 identical StripOffsets entries, each declaring 2,000 LONGs over the same
    /// 8,000 bytes. The old walk read every entry's values: 4,000,000 reads for a 32 KB file (about 120 × its budget).
    @Test func repeatedStripEntriesInOneIFDAreMalformedNotMultiplied() {
        let entries = 2000, count = 2000
        let region = 8 + TIFF.ifdSize(entries: entries)
        var tiff = TIFF()
        tiff.ifd(Array(repeating: (273, 4, count, region), count: entries), next: 0)
        tiff.bytes += [UInt8](repeating: 0, count: count * 4)
        let budget = ImageContainer.tiffWorkBudget(byteCount: tiff.bytes.count)
        #expect(entries * count > 100 * budget, "the old walk's work is far past the budget")

        let (result, work) = Self.walk(tiff.data)
        #expect(result == .malformed)
        #expect(work <= budget)
    }

    /// The same multiplication spread over a chain of IFDs, one StripOffsets entry each (no tag repeats inside an IFD):
    /// 2,000 IFDs × 4,000 SHORTs over one 8 KB region, 8,000,000 reads in the old walk. The budget ends it.
    @Test func entriesSharingOneRegionAcrossIFDsRunOutOfBudget() {
        let ifds = 2000, count = 4000
        let size = TIFF.ifdSize(entries: 1)
        let region = 8 + ifds * size
        var tiff = TIFF()
        for i in 0..<ifds { tiff.ifd([(273, 3, count, region)], next: i + 1 < ifds ? 8 + (i + 1) * size : 0) }
        tiff.bytes += [UInt8](repeating: 0, count: count * 2)
        let budget = ImageContainer.tiffWorkBudget(byteCount: tiff.bytes.count)
        #expect(ifds * count > 100 * budget)

        let (result, work) = Self.walk(tiff.data)
        #expect(result == .malformed)
        #expect(work <= budget + count)                        // at most the one entry that crossed the budget
    }

    /// F1's file, scaled down: a chain of IFDs whose SubIFDs entries all point at one region of zeros. The old walk
    /// queued every value (zeros included) before its 4,096-IFD guard ran: 2,000 × 4,000 = 8,000,000 queued offsets.
    @Test func subIFDPointersIntoSharedZerosAreCountedAndNeverQueued() {
        let ifds = 2000, count = 4000
        let size = TIFF.ifdSize(entries: 1)
        let region = 8 + ifds * size
        var tiff = TIFF()
        for i in 0..<ifds { tiff.ifd([(330, 3, count, region)], next: i + 1 < ifds ? 8 + (i + 1) * size : 0) }
        tiff.bytes += [UInt8](repeating: 0, count: count * 2)
        let budget = ImageContainer.tiffWorkBudget(byteCount: tiff.bytes.count)

        let (result, work) = Self.walk(tiff.data)
        #expect(result == .malformed)
        #expect(work <= budget + count)
    }

    /// One SubIFDs entry with more distinct offsets than a file may have IFDs: refused as the offsets are queued, so the
    /// queue never grows past `tiffMaxIFDs` (the old walk queued all of them and refused only after 4,096 pops).
    @Test func moreIFDOffsetsThanTheLimitAreRefusedAsTheyAreQueued() {
        let count = ImageContainer.tiffMaxIFDs + 100
        let region = 8 + TIFF.ifdSize(entries: 1)
        var tiff = TIFF()
        tiff.ifd([(330, 4, count, region)], next: 0)
        // Distinct, in-file offsets (every one even and inside the value region), so each would be walked.
        for k in 0..<count { tiff.u32(region + 2 * k) }
        let (result, work) = Self.walk(tiff.data)
        #expect(result == .malformed)
        #expect(work <= ImageContainer.tiffWorkBudget(byteCount: tiff.bytes.count))
    }

    /// A tag met twice in one IFD is malformed, whatever its count (TIFF 6.0 §2: each tag once per IFD).
    @Test func aPointerTagRepeatedInOneIFDIsMalformed() {
        var tiff = TIFF()
        tiff.ifd([(34665, 4, 1, 0), (34665, 4, 1, 0)], next: 0)
        #expect(ImageContainer.completeness(of: tiff.data) == .malformed)
    }

    /// A well-formed hand-built TIFF still reads complete, and a strip past the end still reads truncated: the bounds
    /// change what hostile files cost, not what a real file means.
    @Test func aWellFormedTIFFIsStillJudgedByItsStrips() {
        let strip = 8 + TIFF.ifdSize(entries: 2)
        var tiff = TIFF()
        tiff.ifd([(273, 4, 1, strip), (279, 4, 1, 16)], next: 0)
        tiff.bytes += [UInt8](repeating: 0x7F, count: 16)
        #expect(ImageContainer.completeness(of: tiff.data) == .complete)
        #expect(ImageContainer.completeness(of: tiff.data.prefix(tiff.bytes.count - 1)) == .truncated)
    }

    /// A caller that is cancelled stops a long walk: 80,000 two-byte JPEG markers are more work than one stop interval.
    @Test func aWalkStopsWhenItsCallerSaysSo() {
        let markers = ImageContainer.stopCheckInterval + 14_464
        var jpeg = Data([0xFF, 0xD8])
        for _ in 0..<markers { jpeg.append(contentsOf: [0xFF, 0x01]) }   // TEM: no length, no end
        #expect(ImageContainer.completeness(of: jpeg, stopWhen: { true }) == nil)
        #expect(ImageContainer.completeness(of: jpeg, stopWhen: { false }) == .truncated)
        #expect(ImageContainer.completeness(of: jpeg) == .truncated)
    }
}
