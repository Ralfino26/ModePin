import Foundation
import ModePinCore

enum CLI {
    static let usage = """
        ModePin \(ModePin.version): add resolutions a display connection doesn't offer.

        Usage: modepin <command> [--display <name>]

          status                 Show connected displays and their added modes (default)
          add <WxH@Hz>           Add a mode, e.g. modepin add 5120x1440@60
          remove <WxH@Hz>        Remove an added mode
          prefer <WxH@Hz|none>   Mode to switch to after connecting (default: first added)
          enable | disable       Switch a display's added modes on or off
          forget                 Restore the display's own EDID and delete its settings
          apply                  Apply all settings now (the app does this automatically)
          dump [file]            Write the display's current EDID to a file, or as hex
          install-agent          Start ModePin now and at every login
          uninstall-agent        Stop ModePin and don't start it at login
          version

        --display picks a display by (part of) its name when several are connected.
        """

    static func run(command: String, arguments: [String]) -> Int32 {
        var arguments = arguments
        let displayQuery = takeOption("--display", from: &arguments)
        let engine = Engine()

        do {
            switch command {
            case "status", "list":
                printStatus(engine.status())

            case "add", "remove":
                guard let text = arguments.first, let mode = DisplayMode(parsing: text) else {
                    return fail("Give a mode like 5120x1440@60.")
                }
                let report = try pickDisplay(engine.status(), query: displayQuery)
                if command == "add" {
                    try engine.addMode(mode, to: report)
                    print("Added \(mode) to \(report.name).")
                    warnAboutBandwidth(mode, report)
                } else {
                    try engine.removeMode(mode, from: report)
                    print("Removed \(mode) from \(report.name).")
                }
                applyIfAppIsNotRunning(engine)

            case "prefer":
                guard let text = arguments.first else { return fail("Give a mode like 5120x1440@60, or none.") }
                let mode = DisplayMode(parsing: text)
                guard mode != nil || text == "none" else { return fail("Give a mode like 5120x1440@60, or none.") }
                let report = try pickDisplay(engine.status(), query: displayQuery)
                try engine.setPreferredMode(mode, for: report)
                print(mode.map { "\(report.name) switches to \($0) after connecting." } ?? "\(report.name) keeps the resolution macOS picks.")

            case "enable", "disable":
                let report = try pickDisplay(engine.status(), query: displayQuery)
                try engine.setEnabled(command == "enable", for: report)
                print("\(command == "enable" ? "Enabled" : "Disabled") added modes for \(report.name).")
                applyIfAppIsNotRunning(engine)

            case "forget":
                let report = try pickDisplay(engine.status(), query: displayQuery)
                try engine.forget(report)
                print("Restored \(report.name)'s own EDID and removed its settings.")

            case "apply":
                printStatus(engine.enforce())

            case "dump":
                let report = try pickDisplay(engine.status(), query: displayQuery)
                guard let edid = report.edid else { throw ModePinError.unreadableEDID(report.name) }
                if let path = arguments.first {
                    try edid.data.write(to: URL(fileURLWithPath: path))
                    print("Wrote \(edid.bytes.count) bytes to \(path).")
                } else {
                    for row in stride(from: 0, to: edid.bytes.count, by: 16) {
                        print(edid.bytes[row ..< row + 16].map { String(format: "%02X", $0) }.joined(separator: " "))
                    }
                }

            case "install-agent":
                try LoginItem.install()
                print("ModePin is running and will start at every login.")

            case "uninstall-agent":
                try LoginItem.uninstall()
                print("ModePin stopped and won't start at login.")

            case "version", "--version":
                print(ModePin.version)

            case "help", "--help", "-h":
                print(usage)

            default:
                return fail("Unknown command \"\(command)\".\n\n\(usage)")
            }
        } catch {
            return fail(error.localizedDescription)
        }
        return 0
    }

    // MARK: Helpers

    private static func takeOption(_ name: String, from arguments: inout [String]) -> String? {
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
        let value = arguments[index + 1]
        arguments.removeSubrange(index ... index + 1)
        return value
    }

    private static func pickDisplay(_ reports: [DisplayReport], query: String?) throws -> DisplayReport {
        guard !reports.isEmpty else { throw ModePinError.noDisplay }
        guard let query else {
            guard reports.count == 1 else { throw ModePinError.ambiguousDisplay(reports.map(\.name)) }
            return reports[0]
        }
        let matches = reports.filter { $0.name.localizedCaseInsensitiveContains(query) }
        guard let first = matches.first else { throw ModePinError.displayNotFound(query) }
        guard matches.count == 1 else { throw ModePinError.ambiguousDisplay(matches.map(\.name)) }
        return first
    }

    /// The running app reacts to the change itself; otherwise apply it here.
    private static func applyIfAppIsNotRunning(_ engine: Engine) {
        guard LoginItem.otherInstances().isEmpty else { return }
        for report in engine.enforce() where report.action != .none {
            print("\(report.name): \(report.action == .applied ? "applied" : "restored the original EDID").")
        }
    }

    private static func warnAboutBandwidth(_ mode: DisplayMode, _ report: DisplayReport) {
        let needed = mode.reducedBlankingTiming.pixelClockMHz
        if let limit = report.originalEDID?.maxPixelClockMHz, needed > Double(limit) {
            print("Warning: \(mode) needs \(Int(needed)) MHz but this connection reports a \(limit) MHz limit, so it probably won't work.")
        }
    }

    private static func printStatus(_ reports: [DisplayReport]) {
        guard !reports.isEmpty else {
            print("No external displays connected.")
            return
        }
        for report in reports {
            print(report.name)
            print("  State: \(describe(report.state))")
            if let edid = report.originalEDID {
                let limit = edid.maxPixelClockMHz.map { ", link limit \($0) MHz" } ?? ""
                print("  EDID:  \(edid.manufacturer) \(String(format: "%04X", edid.productCode)), \(edid.bytes.count) bytes\(limit)")
            }
            for mode in report.profile?.modes ?? [] {
                let preferred = mode == report.profile?.preferredMode ? " (selected after connecting)" : ""
                print("  Added: \(mode)\(preferred)")
            }
        }
    }

    static func describe(_ state: DisplayReport.State) -> String {
        switch state {
        case .unmanaged: "no added modes"
        case .off: "off"
        case .active: "active"
        case .pending: "waiting to apply"
        case .failed(let message): "failed: \(message)"
        case .unreadable: "EDID unreadable"
        }
    }

    private static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data("modepin: \(message)\n".utf8))
        return 1
    }
}
