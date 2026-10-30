import Foundation

/// Adds modes to an EDID by appending a DisplayID extension block.
///
/// Classic EDID timing descriptors can't describe anything wider than 4095
/// pixels, so extra modes go into a DisplayID 1.2 block with "Type I"
/// detailed timings, which macOS reads alongside the original blocks.
public enum EDIDBuilder {
    /// How many 20-byte timings fit in one 128-byte DisplayID block.
    public static let maxModes = 5

    static let extensionTag: UInt8 = 0x70
    static let displayIDVersion: UInt8 = 0x12
    static let typeITimingTag: UInt8 = 0x03

    public static func adding(_ modes: [DisplayMode], to original: EDID) throws -> EDID {
        guard !modes.isEmpty else { throw ModePinError.noModes }
        guard modes.count <= maxModes else { throw ModePinError.tooManyModes(maxModes) }
        guard original.extensionCount < 254 else { throw ModePinError.unsupportedEDID }

        var base = original.bytes
        base[126] += 1

        let timings = modes.flatMap { typeITiming($0.reducedBlankingTiming, aspect: aspectCode($0)) }
        var section: [UInt8] = [displayIDVersion, UInt8(3 + timings.count), 0x00, 0x00,
                                typeITimingTag, 0x00, UInt8(timings.count)]
        section += timings
        section.append(0 &- section.reduce(0) { $0 &+ $1 })

        var block = [extensionTag] + section
        block += [UInt8](repeating: 0, count: EDID.blockSize - block.count)

        let raw = EDID.checksummed(base + block)
        guard let edid = EDID(raw) else { throw ModePinError.unsupportedEDID }
        return edid
    }

    /// If `edid` ends with a block built by `adding(_:to:)`, the EDID without it.
    public static func removingAddedModes(from edid: EDID) -> EDID? {
        guard edid.extensionCount > 0 else { return nil }
        let last = edid.block(edid.extensionCount)
        // [tag, version, length, product type, ext count, block tag, block rev, block length, …]
        let b = Array(last)
        guard b[0] == extensionTag, b[1] == displayIDVersion, b[3] == 0, b[5] == typeITimingTag,
              b[6] == 0, b[7] > 0, b[7] % 20 == 0, Int(b[2]) == 3 + Int(b[7]) else { return nil }
        var raw = Array(edid.bytes.dropLast(EDID.blockSize))
        raw[126] -= 1
        return EDID(EDID.checksummed(raw))
    }

    /// DisplayID 1.x Type I detailed timing (20 bytes, every field stored minus one).
    static func typeITiming(_ t: Timing, aspect: UInt8) -> [UInt8] {
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] }
        let clock = t.pixelClock10kHz - 1
        return [UInt8(clock & 0xFF), UInt8(clock >> 8 & 0xFF), UInt8(clock >> 16 & 0xFF), aspect]
            + le16(t.hActive - 1) + le16(t.hBlank - 1)
            + le16((t.hFrontPorch - 1) | (t.hSyncPositive ? 0x8000 : 0)) + le16(t.hSync - 1)
            + le16(t.vActive - 1) + le16(t.vBlank - 1)
            + le16((t.vFrontPorch - 1) | (t.vSyncPositive ? 0x8000 : 0)) + le16(t.vSync - 1)
    }

    /// DisplayID aspect ratio code; 8 means "not one of the listed ratios".
    static func aspectCode(_ mode: DisplayMode) -> UInt8 {
        let ratios: [(Int, Int, UInt8)] = [(1, 1, 0), (5, 4, 1), (4, 3, 2), (15, 9, 3), (16, 9, 4),
                                           (16, 10, 5), (64, 27, 6), (256, 135, 7)]
        return ratios.first { mode.width * $0.1 == mode.height * $0.0 }?.2 ?? 8
    }
}
