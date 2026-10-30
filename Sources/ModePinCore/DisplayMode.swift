import Foundation

/// A resolution and refresh rate, e.g. 5120×1440 @ 60 Hz.
public struct DisplayMode: Codable, Hashable, Sendable, CustomStringConvertible {
    public var width: Int
    public var height: Int
    public var refresh: Int

    public init(width: Int, height: Int, refresh: Int) {
        self.width = width
        self.height = height
        self.refresh = refresh
    }

    /// Parses "5120x1440@60", "5120×1440 @ 60Hz" or "5120x1440" (60 Hz).
    public init?(parsing text: String) {
        let cleaned = text.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "×", with: "x")
            .replacingOccurrences(of: "hz", with: "")
        let parts = cleaned.split(separator: "@", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count) else { return nil }
        let size = parts[0].split(separator: "x", omittingEmptySubsequences: false)
        guard size.count == 2, let w = Int(size[0]), let h = Int(size[1]) else { return nil }
        let hz = parts.count == 2 ? Int(parts[1]) : 60
        guard let hz, (320...16384).contains(w), (200...16384).contains(h), (24...500).contains(hz) else { return nil }
        self.init(width: w, height: h, refresh: hz)
    }

    public var description: String { "\(width)×\(height) @ \(refresh) Hz" }
    public var argument: String { "\(width)x\(height)@\(refresh)" }
}

/// Detailed video timing, in pixels and lines.
public struct Timing: Equatable, Sendable {
    public var hActive, hBlank, hFrontPorch, hSync: Int
    public var vActive, vBlank, vFrontPorch, vSync: Int
    /// Pixel clock in units of 10 kHz, as stored in EDID / DisplayID.
    public var pixelClock10kHz: Int
    public var hSyncPositive: Bool
    public var vSyncPositive: Bool

    public var hTotal: Int { hActive + hBlank }
    public var vTotal: Int { vActive + vBlank }
    public var pixelClockMHz: Double { Double(pixelClock10kHz) / 100 }
    public var refreshRate: Double { Double(pixelClock10kHz) * 10_000 / Double(hTotal * vTotal) }
}

extension DisplayMode {
    /// VESA CVT 1.2 reduced-blanking (v1) timing: the low-bandwidth timing
    /// that monitors and macOS accept for modes without a predefined timing.
    public var reducedBlankingTiming: Timing {
        let minVBlankMicroseconds = 460.0
        let vFrontPorch = 3, minVBackPorch = 6
        let hBlank = 160, hSync = 32, hFrontPorch = 48
        let hActive = width - width % 8

        let hPeriodEstimate = (1_000_000 / Double(refresh) - minVBlankMicroseconds) / Double(height)
        let vSync = Self.cvtVSync(width: width, height: height)
        let vBlank = max(Int(minVBlankMicroseconds / hPeriodEstimate) + 1, vFrontPorch + vSync + minVBackPorch)

        // The clock is rounded down to a 0.25 MHz step, as the standard does.
        let hz = Double(refresh) * Double((hActive + hBlank) * (height + vBlank))
        let clock10kHz = Int(hz / 250_000) * 25

        return Timing(hActive: hActive, hBlank: hBlank, hFrontPorch: hFrontPorch, hSync: hSync,
                      vActive: height, vBlank: vBlank, vFrontPorch: vFrontPorch, vSync: vSync,
                      pixelClock10kHz: clock10kHz, hSyncPositive: true, vSyncPositive: false)
    }

    /// CVT encodes the aspect ratio in the vertical sync width.
    static func cvtVSync(width: Int, height: Int) -> Int {
        func near(_ w: Int, _ h: Int) -> Bool { abs(width * h - height * w) * 100 < height * w }
        if near(4, 3) { return 4 }
        if near(16, 9) { return 5 }
        if near(16, 10) { return 6 }
        if near(5, 4) || near(15, 9) { return 7 }
        return 10
    }
}
