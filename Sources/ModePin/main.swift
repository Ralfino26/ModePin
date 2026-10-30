import AppKit
import ModePinCore

// With arguments the binary is a command-line tool; without, the menu bar app.
// (Finder used to pass -psn_…; Xcode passes -NS… defaults. Neither is a command.)
let arguments = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-psn_") && !$0.hasPrefix("-NS") }

if let command = arguments.first {
    let status = CLI.run(command: command, arguments: Array(arguments.dropFirst()))
    Log.flush()
    exit(status)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
