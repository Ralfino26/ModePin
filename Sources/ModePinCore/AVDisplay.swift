import CIOAVService
import Foundation
import IOKit

/// An external display as seen by the Display Coprocessor (DCPAVServiceProxy).
public final class AVDisplay {
    public static let serviceClass = "DCPAVServiceProxy"

    public let registryID: UInt64
    private let service: IOAVService

    private init(registryID: UInt64, service: IOAVService) {
        self.registryID = registryID
        self.service = service
    }

    /// Every connected external display. The built-in panel is skipped.
    public static func connected() -> [AVDisplay] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(serviceClass), &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var displays: [AVDisplay] = []
        var entry = IOIteratorNext(iterator)
        while entry != IO_OBJECT_NULL {
            if let display = AVDisplay(entry: entry) { displays.append(display) }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
        return displays
    }

    private convenience init?(entry: io_service_t) {
        let location = IORegistryEntrySearchCFProperty(entry, kIOServicePlane, "Location" as CFString,
                                                       kCFAllocatorDefault, IOOptionBits(kIORegistryIterateRecursively))
        guard location as? String != "Embedded",
              let service = IOAVServiceCreateWithService(kCFAllocatorDefault, entry) else { return nil }
        var id: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(entry, &id)
        self.init(registryID: id, service: service)
    }

    /// The EDID the display is using right now, virtual or not.
    public func currentEDID() -> EDID? {
        var data: Unmanaged<CFData>?
        guard IOAVServiceCopyEDID(service, &data) == kIOReturnSuccess,
              let bytes = data?.takeRetainedValue() as Data? else { return nil }
        return EDID(bytes)
    }

    /// Replaces the display's EDID until it is disconnected. macOS then
    /// renegotiates the link, so the screen blanks for a second or two.
    public func setVirtualEDID(_ edid: EDID) throws {
        let result = IOAVServiceSetVirtualEDIDMode(service, 1, edid.data as CFData)
        guard result == kIOReturnSuccess else { throw ModePinError.ioKit("Applying the EDID", result) }
    }

    /// Goes back to the display's own EDID.
    public func clearVirtualEDID() throws {
        let result = IOAVServiceSetVirtualEDIDMode(service, 0, nil)
        guard result == kIOReturnSuccess else { throw ModePinError.ioKit("Restoring the EDID", result) }
    }
}
