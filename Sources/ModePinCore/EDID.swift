import Foundation

/// A display's EDID: a 128-byte base block followed by extension blocks.
public struct EDID: Equatable, Sendable {
    public static let blockSize = 128
    static let header: [UInt8] = [0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00]

    /// Only the blocks the base block declares. macOS sometimes reports
    /// trailing bytes after them; those never take part in comparisons.
    public let bytes: [UInt8]

    public init?(_ data: some Collection<UInt8>) {
        let raw = Array(data)
        guard raw.count >= Self.blockSize, raw.starts(with: Self.header) else { return nil }
        let declared = Self.blockSize * (1 + Int(raw[126]))
        guard raw.count >= declared else { return nil }
        bytes = Array(raw.prefix(declared))
    }

    public var data: Data { Data(bytes) }
    public var extensionCount: Int { Int(bytes[126]) }

    public func block(_ index: Int) -> ArraySlice<UInt8> {
        bytes[index * Self.blockSize ..< (index + 1) * Self.blockSize]
    }

    public var hasValidChecksums: Bool {
        (0...extensionCount).allSatisfy { block($0).reduce(0) { $0 &+ $1 } == 0 }
    }

    /// Three-letter PNP manufacturer ID, e.g. "SAM".
    public var manufacturer: String {
        let value = UInt16(bytes[8]) << 8 | UInt16(bytes[9])
        let letters: [UInt16] = [(value >> 10) & 0x1F, (value >> 5) & 0x1F, value & 0x1F]
        return String(letters.map { Character(UnicodeScalar(UInt8($0) + 64)) })
    }

    public var productCode: UInt16 { UInt16(bytes[10]) | UInt16(bytes[11]) << 8 }

    /// The monitor name from the 0xFC display descriptor.
    public var name: String? { descriptorText(tag: 0xFC) }

    /// Highest pixel clock the connection advertises (range limits descriptor), in MHz.
    public var maxPixelClockMHz: Int? {
        descriptor(tag: 0xFD).map { Int($0[9]) * 10 }.flatMap { $0 > 0 ? $0 : nil }
    }

    /// The 18-byte display descriptor with this tag, indexed from 0.
    private func descriptor(tag: UInt8) -> [UInt8]? {
        for offset in stride(from: 54, through: 108, by: 18)
        where bytes[offset] == 0 && bytes[offset + 1] == 0 && bytes[offset + 3] == tag {
            return Array(bytes[offset ..< offset + 18])
        }
        return nil
    }

    private func descriptorText(tag: UInt8) -> String? {
        guard let d = descriptor(tag: tag) else { return nil }
        let text = d.dropFirst(5).prefix { $0 != 0x0A && $0 != 0 }
        let string = String(decoding: text, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        return string.isEmpty ? nil : string
    }

    /// Fixes the checksum byte of every block.
    static func checksummed(_ raw: [UInt8]) -> [UInt8] {
        var out = raw
        for start in stride(from: 0, to: out.count, by: blockSize) {
            let sum = out[start ..< start + blockSize - 1].reduce(UInt8(0)) { $0 &+ $1 }
            out[start + blockSize - 1] = 0 &- sum
        }
        return out
    }
}
