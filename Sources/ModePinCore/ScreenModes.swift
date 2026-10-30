import CoreGraphics
import Foundation

/// Selects a resolution on the macOS display that an EDID belongs to.
public enum ScreenModes {
    public enum Result: Equatable {
        case switched
        case alreadyCurrent
        /// The display isn't online yet, or doesn't list the mode yet; it may
        /// still be renegotiating after the override.
        case notReady
        case failed(Int32)
    }

    public static func select(_ mode: DisplayMode, on edid: EDID) -> Result {
        guard let display = onlineDisplay(for: edid) else { return .notReady }

        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        let all = CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode] ?? []
        // The 1× (non-HiDPI) mode with this size and refresh rate.
        let candidates = all.filter {
            $0.pixelWidth == mode.width && $0.pixelHeight == mode.height && $0.width == mode.width
                && Int($0.refreshRate.rounded()) == mode.refresh && $0.isUsableForDesktopGUI()
        }
        guard let target = candidates.first else { return .notReady }

        if let current = CGDisplayCopyDisplayMode(display), candidates.contains(where: { $0.ioDisplayModeID == current.ioDisplayModeID }) {
            return .alreadyCurrent
        }

        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return .failed(-1) }
        let result = CGConfigureDisplayWithDisplayMode(config, display, target, nil)
        guard result == .success else {
            CGCancelDisplayConfiguration(config)
            return .failed(result.rawValue)
        }
        let completed = CGCompleteDisplayConfiguration(config, .permanently)
        return completed == .success ? .switched : .failed(completed.rawValue)
    }

    /// Matches on vendor, model and serial, which macOS takes from the EDID.
    static func onlineDisplay(for edid: EDID) -> CGDirectDisplayID? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).first {
            CGDisplayIsBuiltin($0) == 0
                && CGDisplayVendorNumber($0) == edid.vendorNumber
                && CGDisplayModelNumber($0) == UInt32(edid.productCode)
                && CGDisplaySerialNumber($0) == edid.serialNumber
        }
    }
}

extension EDID {
    /// The manufacturer ID as macOS reports it (CGDisplayVendorNumber).
    var vendorNumber: UInt32 { UInt32(bytes[8]) << 8 | UInt32(bytes[9]) }

    var serialNumber: UInt32 {
        UInt32(bytes[12]) | UInt32(bytes[13]) << 8 | UInt32(bytes[14]) << 16 | UInt32(bytes[15]) << 24
    }
}
