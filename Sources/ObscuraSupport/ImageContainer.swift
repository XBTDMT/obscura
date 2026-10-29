// ObscuraSupport — is an image file whole? (fail-open #5). ImageIO cannot say: a non-incremental CGImageSource reports
// `kCGImageStatusComplete` for a PNG cut in half, a JPEG without its end marker and a GIF missing frames, and decodes the
// part that is there (measured on macOS 27.2, 2026-10-27). A file read while it is still being written would be judged
// on its top part. So the container itself is walked, structure only (lengths, offsets, end markers): never pixel data,
// never metadata values.
public import Foundation

public enum ImageContainer {
    public enum Completeness: Sendable, Hashable {
        /// Every structure the container declares lies inside the bytes and its end is present.
        case complete
        /// The bytes stop before the container says it ends: still being written, or cut short.
        case truncated
        /// Not one of the containers walked here; nothing is claimed either way.
        case unrecognized
        /// It starts as one of them but its structure does not parse (a damaged file, or a writer that bends the format).
        /// Nothing is claimed either way: whether it decodes is ImageIO's call.
        case malformed
    }

    /// Walks PNG, JPEG, GIF, TIFF (classic and BigTIFF), the ISO base media file format (HEIC, HEIF, AVIF), BMP and
    /// WebP. Bytes after a container's end (appended data) do not make it incomplete.
    ///
    /// The walk is linear in the bytes, whatever they declare (security scan F1, F3): the bytes are read in place, never
    /// copied, and a TIFF's entries and values are counted against a budget that a file whose structures do not overlap
    /// never reaches (`tiffWorkBudget`). A file that would need more is malformed.
    public static func completeness(of data: Data) -> Completeness {
        walk(data, shouldStop: { false }).result ?? .malformed
    }

    /// `completeness(of:)` that stops early when `shouldStop` turns true (checked every `stopCheckInterval` units of
    /// work); nil when it stopped. For a caller that may be cancelled while a large file is walked.
    public static func completeness(of data: Data, stopWhen shouldStop: () -> Bool) -> Completeness? {
        walk(data, shouldStop: shouldStop).result
    }

    /// Units of work between two `shouldStop` checks.
    static let stopCheckInterval = 1 << 16

    /// The walk and the units of work it did (TIFF entries and values; chunks, segments and boxes of the others).
    /// Internal so tests can prove the work stays linear in the bytes.
    static func walk(_ data: Data, shouldStop: () -> Bool) -> (result: Completeness?, work: Int) {
        withoutActuallyEscaping(shouldStop) { shouldStop in
            data.withUnsafeBytes { buffer in
                let meter = Meter(shouldStop: shouldStop)
                let result = dispatch(Reader(buffer, meter: meter))
                return (meter.stopped ? nil : result, meter.work)
            }
        }
    }

    private static func dispatch(_ reader: Reader) -> Completeness {
        if reader.matches(0, [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return png(reader) }
        if reader.matches(0, [0xFF, 0xD8]) { return jpeg(reader) }
        if reader.matches(0, Array("GIF87a".utf8)) || reader.matches(0, Array("GIF89a".utf8)) { return gif(reader) }
        if reader.matches(0, [0x49, 0x49]) || reader.matches(0, [0x4D, 0x4D]) {
            if let result = tiff(reader) { return result }
        }
        if reader.matches(4, Array("ftyp".utf8)) { return isoBox(reader) }
        if reader.matches(0, Array("BM".utf8)) { return bmp(reader) }
        if reader.matches(0, Array("RIFF".utf8)) && reader.matches(8, Array("WEBP".utf8)) { return webp(reader) }
        return .unrecognized
    }

    // MARK: PNG — IHDR first, then chunks of length, type, data, CRC up to IEND. A chunk type that is not four ASCII
    // letters means the lengths no longer line up: malformed, not unfinished.

    private static func png(_ r: Reader) -> Completeness {
        var offset = 8
        var first = true
        while let length = r.u32be(offset), r.has(offset + 8) {
            guard r.tick() else { return .malformed }
            let type = r.slice(offset + 4, 4)
            guard type.allSatisfy({ (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0) }) else { return .malformed }
            if first {
                guard type == Array("IHDR".utf8), length == 13 else { return .malformed }
                first = false
            }
            let end = offset + 12 + Int(length)
            guard r.has(end) else { return .truncated }
            if type == Array("IEND".utf8) { return .complete }
            offset = end
        }
        return .truncated
    }

    // MARK: JPEG — marker segments; entropy-coded data after each SOS; complete at EOI.

    private static func jpeg(_ r: Reader) -> Completeness {
        var offset = 2
        while offset < r.count {
            guard r.tick() else { return .malformed }
            // Find the next marker: 0xFF, then any fill 0xFF bytes, then the marker code.
            guard r.byte(offset) == 0xFF else {
                // Stray bytes between segments (some encoders write them): skip to the next 0xFF, as decoders do.
                guard let next = r.firstIndex(of: 0xFF, from: offset) else { return .truncated }
                offset = next
                continue
            }
            var m = offset + 1
            while r.byte(m) == 0xFF { m += 1 }
            guard let code = r.byte(m) else { return .truncated }
            offset = m + 1
            switch code {
            case 0xD9: return .complete                       // EOI
            case 0x01, 0xD0...0xD7: continue                   // TEM, RSTn: no length
            case 0x00: continue                                // a stuffed byte out of place; keep looking
            default:
                guard let length = r.u16be(offset), length >= 2 else { return .truncated }
                let end = offset + Int(length)
                guard r.has(end) else { return .truncated }
                offset = end
                if code == 0xDA {                              // SOS: entropy-coded data until a real marker
                    guard let marker = entropyEnd(r, from: offset) else { return .truncated }
                    offset = marker
                }
            }
        }
        return .truncated
    }

    /// The index of the first 0xFF that starts a marker (not a stuffed 0xFF00 and not a restart marker) at or after `from`.
    private static func entropyEnd(_ r: Reader, from: Int) -> Int? {
        var i = from
        while let ff = r.firstIndex(of: 0xFF, from: i) {
            guard r.tick() else { return nil }
            guard let next = r.byte(ff + 1) else { return nil }
            if next == 0x00 || (0xD0...0xD7).contains(next) || next == 0xFF { i = ff + 1; continue }
            return ff
        }
        return nil
    }

    // MARK: GIF — header, colour table, then blocks to the trailer (0x3B).

    private static func gif(_ r: Reader) -> Completeness {
        guard let packed = r.byte(10) else { return .truncated }
        var offset = 13 + (packed & 0x80 != 0 ? 3 << (Int(packed & 0x07) + 1) : 0)
        while true {
            guard r.tick() else { return .malformed }
            guard let introducer = r.byte(offset) else { return .truncated }
            switch introducer {
            case 0x3B:
                return .complete
            case 0x21:                                         // extension: label, then sub-blocks
                guard let next = subBlocksEnd(r, from: offset + 2) else { return .truncated }
                offset = next
            case 0x2C:                                         // image: descriptor, local table, LZW size, sub-blocks
                guard let local = r.byte(offset + 9) else { return .truncated }
                let table = local & 0x80 != 0 ? 3 << (Int(local & 0x07) + 1) : 0
                guard let next = subBlocksEnd(r, from: offset + 10 + table + 1) else { return .truncated }
                offset = next
            default:
                return .malformed                              // the block stream stops making sense
            }
        }
    }

    private static func subBlocksEnd(_ r: Reader, from: Int) -> Int? {
        var offset = from
        while true {
            guard r.tick() else { return nil }
            guard let size = r.byte(offset) else { return nil }
            offset += 1
            if size == 0 { return offset }
            offset += Int(size)
            guard r.has(offset) else { return nil }
        }
    }

    // MARK: TIFF — every IFD (the page chain, and the EXIF, GPS, interoperability and sub-IFDs they point at), every
    // value stored outside its entry (ICC profile, XMP, tables) and every strip or tile lies inside the bytes.

    /// Bytes per value of each TIFF field type (TIFF 6.0 §2, BigTIFF's 16–18); nil for a type this walk does not know.
    private static func tiffTypeSize(_ type: UInt16) -> Int? {
        switch type {
        case 1, 2, 6, 7: return 1
        case 3, 8: return 2
        case 4, 9, 11, 13: return 4
        case 5, 10, 12, 16, 17, 18: return 8
        default: return nil
        }
    }

    /// The most IFDs one file may hold (the page chain and every IFD those point at), counted as they are queued.
    static let tiffMaxIFDs = 4096
    /// The tags whose values the walk reads: strip and tile offsets and byte counts, and the IFD pointers.
    private static let tiffOffsetTags: Set<UInt16> = [273, 324], tiffLengthTags: Set<UInt16> = [279, 325]
    private static let tiffPointerTags: Set<UInt16> = [330, 34665, 34853, 40965]   // SubIFDs, EXIF, GPS, interoperability

    /// Units of work (one per IFD entry, one per value read) a TIFF walk may spend. Every entry takes 12 bytes (20 in
    /// BigTIFF) and every value read at least 2, inline values at most two per classic entry or four per BigTIFF entry,
    /// so a file whose IFDs and value arrays do not overlap spends at most half its byte count. Only structures laid over
    /// the same bytes again and again (the hostile files of F1 and F3) reach the budget.
    static func tiffWorkBudget(byteCount: Int) -> Int { byteCount / 2 + 4096 }

    private static func tiff(_ r: Reader) -> Completeness? {
        let little = r.byte(0) == 0x49
        guard r.byte(1) == r.byte(0), let magic = r.u16(2, little: little) else { return nil }
        let big: Bool
        switch magic {
        case 42: big = false
        case 43: big = true
        default: return nil
        }
        // Offsets and counts are 4 bytes in classic TIFF and 8 in BigTIFF; the IFD entry count is 2 bytes or 8.
        func offset(_ at: Int) -> Int? { big ? r.int64(at, little: little) : r.u32(at, little: little).map(Int.init) }
        guard let first = offset(big ? 8 : 4) else { return .truncated }
        let budget = tiffWorkBudget(byteCount: r.count)
        // Every IFD offset ever queued: one met twice is a loop or a shared IFD, and the queue never holds more than
        // `tiffMaxIFDs` (the bound applies as offsets are added, not as they are taken).
        var queued: Set<Int> = []
        var pending: [Int] = []
        func enqueue(_ ifd: Int) -> Bool {
            guard ifd != 0 else { return true }
            guard queued.insert(ifd).inserted, queued.count <= tiffMaxIFDs else { return false }
            pending.append(ifd)
            return true
        }
        guard enqueue(first) else { return .malformed }
        while let ifd = pending.popLast() {
            let countSize = big ? 8 : 2, entrySize = big ? 20 : 12, offsetSize = big ? 8 : 4, inline = big ? 8 : 4
            let declared = big ? r.int64(ifd, little: little) : r.u16(ifd, little: little).map(Int.init)
            guard let count = declared else { return .truncated }
            guard count <= 1 << 20 else { return .malformed }
            let entries = ifd + countSize
            let nextAt = entries + count * entrySize
            guard r.fits(nextAt, offsetSize) else { return .truncated }
            guard r.spend(count, within: budget) else { return .malformed }
            var offsets: TIFFValues?, lengths: TIFFValues?
            var seen: Set<UInt16> = []
            for i in 0..<count {
                let e = entries + i * entrySize
                guard let tag = r.u16(e, little: little), let type = r.u16(e + 2, little: little), let n = offset(e + 4) else { return .truncated }
                guard let size = tiffTypeSize(type) else { continue }
                guard n >= 0, n <= 1 << 30 else { return .malformed }
                if n * size > inline {
                    guard let at = offset(e + (big ? 12 : 8)) else { return .truncated }
                    guard r.fits(at, n * size) else { return .truncated }
                }
                let isOffsets = tiffOffsetTags.contains(tag), isLengths = tiffLengthTags.contains(tag)
                guard isOffsets || isLengths || tiffPointerTags.contains(tag) else { continue }
                // A tag appears once in an IFD (TIFF 6.0 §2): a repeat is how F3's file multiplies its work.
                guard seen.insert(tag).inserted else { return .malformed }
                guard let values = tiffValues(r, entry: e, type: type, count: n, big: big, little: little) else { continue }
                guard r.spend(values.count, within: budget) else { return .malformed }
                if isOffsets {
                    offsets = values
                } else if isLengths {
                    lengths = values
                } else {
                    for k in 0..<values.count {
                        guard let value = values[k] else { return .truncated }
                        guard enqueue(value) else { return .malformed }
                    }
                }
            }
            if let offsets, let lengths {
                // Paired in place: the values were paid for when their entries were met.
                for k in 0..<min(offsets.count, lengths.count) {
                    guard let start = offsets[k], let length = lengths[k] else { return .truncated }
                    if !r.fits(start, length) { return .truncated }
                }
            }
            guard let next = offset(nextAt) else { return .truncated }
            guard enqueue(next) else { return .malformed }
        }
        return .complete
    }

    /// The SHORT, LONG, IFD, LONG8 or IFD8 values of one IFD entry, read in place (never copied out).
    private struct TIFFValues {
        let reader: Reader
        let start: Int
        let count: Int
        let size: Int
        let little: Bool
        subscript(_ i: Int) -> Int? {
            let p = start + i * size
            switch size {
            case 2: return reader.u16(p, little: little).map(Int.init)
            case 4: return reader.u32(p, little: little).map(Int.init)
            default: return reader.int64(p, little: little)
            }
        }
    }

    /// The values of one IFD entry, inline or at their offset; nil when they lie outside the bytes or the type is not
    /// SHORT, LONG, IFD, LONG8 or IFD8.
    private static func tiffValues(_ r: Reader, entry: Int, type: UInt16, count: Int, big: Bool, little: Bool) -> TIFFValues? {
        let size: Int
        switch type {
        case 3: size = 2
        case 4, 13: size = 4
        case 16, 18: size = 8
        default: return nil
        }
        guard count >= 0, count <= 1 << 24 else { return nil }
        let inline = big ? 8 : 4
        let valueField = entry + (big ? 12 : 8)
        let start: Int
        if count * size <= inline {
            start = valueField
        } else {
            let at = big ? r.int64(valueField, little: little) : r.u32(valueField, little: little).map(Int.init)
            guard let at else { return nil }
            start = at
        }
        guard r.fits(start, count * size) else { return nil }
        return TIFFValues(reader: r, start: start, count: count, size: size, little: little)
    }

    // MARK: ISO base media (HEIC, HEIF, AVIF) — top-level boxes laid end to end, each inside the bytes, and both the
    // item description (meta) and the coded data (mdat) present: a file cut exactly between two boxes has no partial
    // box, but it lacks one of the two.

    private static func isoBox(_ r: Reader) -> Completeness {
        var offset = 0
        var seen: Set<String> = []
        while offset < r.count {
            guard r.tick() else { return .malformed }
            guard let size32 = r.u32be(offset), r.has(offset + 8) else { return .truncated }
            seen.insert(String(decoding: r.slice(offset + 4, 4), as: UTF8.self))
            var size = Int(size32)
            if size32 == 1 {
                guard let large = r.int64(offset + 8, little: false) else { return .truncated }
                size = large
            } else if size32 == 0 {
                size = r.count - offset                        // the last box runs to the end of the file
            }
            guard size >= 8, r.fits(offset, size) else { return .truncated }
            offset += size
        }
        return seen.isSuperset(of: ["ftyp", "meta", "mdat"]) ? .complete : .truncated
    }

    // MARK: BMP — the declared file size, or the pixel rows the header describes.

    private static func bmp(_ r: Reader) -> Completeness {
        guard let declared = r.u32(2, little: true), let pixels = r.u32(10, little: true) else { return .truncated }
        if declared > 0 { return r.has(Int(declared)) ? .complete : .truncated }
        guard let width = r.u32(18, little: true), let height = r.u32(22, little: true),
              let bpp = r.u16(28, little: true), let compression = r.u32(30, little: true) else { return .truncated }
        guard compression == 0 || compression == 3 else { return r.fits(Int(pixels), 1) ? .complete : .truncated }
        let rows = Int(Int32(bitPattern: height).magnitude)
        let rowBytes = (Int(Int32(bitPattern: width).magnitude) * Int(bpp) + 31) / 32 * 4
        let (needed, overflow) = rows.multipliedReportingOverflow(by: rowBytes)
        return !overflow && r.fits(Int(pixels), needed) ? .complete : .truncated
    }

    // MARK: WebP — the RIFF size.

    private static func webp(_ r: Reader) -> Completeness {
        guard let size = r.u32(4, little: true) else { return .truncated }
        return r.has(Int(size) + 8) ? .complete : .truncated
    }

    /// Counts the walk's work and asks the caller, every `stopCheckInterval` units, whether to stop.
    private final class Meter {
        let shouldStop: () -> Bool
        var work = 0
        var stopped = false
        private var nextCheck = stopCheckInterval
        init(shouldStop: @escaping () -> Bool) { self.shouldStop = shouldStop }

        /// Adds `units`; false once the walk must end (the caller stopped it).
        func spend(_ units: Int) -> Bool {
            guard !stopped else { return false }
            work += units
            if work >= nextCheck {
                nextCheck = work + stopCheckInterval
                if shouldStop() { stopped = true }
            }
            return !stopped
        }
    }

    /// Bounds-checked reads over the bytes, in place. Every accessor returns nil past the end instead of trapping.
    /// Lives only inside `walk`'s `withUnsafeBytes`.
    private struct Reader {
        let bytes: UnsafeRawBufferPointer
        let meter: Meter
        init(_ bytes: UnsafeRawBufferPointer, meter: Meter) {
            self.bytes = bytes
            self.meter = meter
        }
        var count: Int { bytes.count }
        /// One unit of work; false once the walk must end.
        func tick() -> Bool { meter.spend(1) }
        /// `units` of work; false once the walk must end or its total passes `budget`.
        func spend(_ units: Int, within budget: Int) -> Bool { meter.spend(units) && meter.work <= budget }
        /// True when the first `end` bytes exist (an exclusive end offset inside the data).
        func has(_ end: Int) -> Bool { end >= 0 && end <= bytes.count }
        func byte(_ i: Int) -> UInt8? { i >= 0 && i < bytes.count ? bytes[i] : nil }
        func matches(_ at: Int, _ pattern: [UInt8]) -> Bool {
            guard fits(at, pattern.count) else { return false }
            return pattern.indices.allSatisfy { bytes[at + $0] == pattern[$0] }
        }
        /// True when `length` bytes from `start` lie inside the data; never overflows, whatever the two values.
        func fits(_ start: Int, _ length: Int) -> Bool {
            start >= 0 && length >= 0 && start <= bytes.count && length <= bytes.count - start
        }
        /// An unsigned 64-bit value that is also a valid Int; nil past the end or when it would not fit.
        func int64(_ i: Int, little: Bool) -> Int? { u64(i, little: little).flatMap { Int(exactly: $0) } }
        func slice(_ at: Int, _ length: Int) -> [UInt8] {
            guard fits(at, length) else { return [] }
            return Array(bytes[at..<at + length])
        }
        func firstIndex(of value: UInt8, from: Int) -> Int? {
            guard from < bytes.count else { return nil }
            return bytes[max(0, from)...].firstIndex(of: value)
        }
        func u16be(_ i: Int) -> UInt16? { u16(i, little: false) }
        func u32be(_ i: Int) -> UInt32? { u32(i, little: false) }
        func u16(_ i: Int, little: Bool) -> UInt16? {
            guard let a = byte(i), let b = byte(i + 1) else { return nil }
            return little ? UInt16(b) << 8 | UInt16(a) : UInt16(a) << 8 | UInt16(b)
        }
        func u32(_ i: Int, little: Bool) -> UInt32? {
            guard let a = u16(i, little: little), let b = u16(i + 2, little: little) else { return nil }
            return little ? UInt32(b) << 16 | UInt32(a) : UInt32(a) << 16 | UInt32(b)
        }
        func u64(_ i: Int, little: Bool) -> UInt64? {
            guard let a = u32(i, little: little), let b = u32(i + 4, little: little) else { return nil }
            return little ? UInt64(b) << 32 | UInt64(a) : UInt64(a) << 32 | UInt64(b)
        }
    }
}
