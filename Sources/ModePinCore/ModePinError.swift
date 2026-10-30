import Foundation

public enum ModePinError: LocalizedError, Equatable {
    case noModes
    case tooManyModes(Int)
    case duplicateMode(DisplayMode)
    case modeNotFound(DisplayMode)
    case unsupportedEDID
    case unreadableEDID(String)
    case noDisplay
    case displayNotFound(String)
    case ambiguousDisplay([String])
    case notConfigured(String)
    case ioKit(String, Int32)

    public var errorDescription: String? {
        switch self {
        case .noModes: "No modes to add."
        case .tooManyModes(let max): "A display can have at most \(max) added modes."
        case .duplicateMode(let mode): "\(mode) is already added."
        case .modeNotFound(let mode): "\(mode) isn't one of the added modes."
        case .unsupportedEDID: "This display's EDID can't be extended."
        case .unreadableEDID(let name): "Couldn't read the EDID of \(name)."
        case .noDisplay: "No external display is connected."
        case .displayNotFound(let query): "No connected display matches \"\(query)\"."
        case .ambiguousDisplay(let names): "Several displays are connected (\(names.joined(separator: ", "))). Pick one with --display."
        case .notConfigured(let name): "\(name) has no added modes."
        case .ioKit(let action, let code): "\(action) failed (IOReturn 0x\(String(UInt32(bitPattern: code), radix: 16)))."
        }
    }
}
