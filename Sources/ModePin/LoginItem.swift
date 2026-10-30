import AppKit
import ModePinCore

/// Starts ModePin at login through a per-user LaunchAgent, which also
/// relaunches it if it ever crashes. Quitting from the menu (exit code 0)
/// is respected until the next login.
enum LoginItem {
    static let label = ModePin.bundleIdentifier

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    /// The real app binary, even when run through a symlink such as /opt/homebrew/bin/modepin.
    static var executablePath: String {
        URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
    }

    /// Writes the LaunchAgent. It takes effect at the next login.
    static func enable() throws {
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executablePath],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
            "ThrottleInterval": 5,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: plistURL, options: .atomic)
    }

    /// Removes the LaunchAgent without stopping the running app.
    static func disable() throws {
        if isEnabled { try FileManager.default.removeItem(at: plistURL) }
    }

    /// Enables the agent and (re)starts the app under launchd right now,
    /// replacing any instance that is already running.
    static func install() throws {
        try enable()
        _ = launchctl("bootout", "gui/\(getuid())/\(label)")
        stopRunningInstances()
        guard launchctl("bootstrap", "gui/\(getuid())", plistURL.path) == 0 else {
            throw NSError(domain: label, code: 1, userInfo: [NSLocalizedDescriptionKey: "launchctl bootstrap failed"])
        }
    }

    /// Stops the app and removes the agent.
    static func uninstall() throws {
        _ = launchctl("bootout", "gui/\(getuid())/\(label)")
        stopRunningInstances()
        try disable()
    }

    static func otherInstances() -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: ModePin.bundleIdentifier)
            .filter { $0.processIdentifier != getpid() }
    }

    private static func stopRunningInstances() {
        DistributedNotificationCenter.default().postNotificationName(
            ModePin.quitNotification, object: nil, userInfo: nil, deliverImmediately: true)
        let deadline = Date().addingTimeInterval(3)
        while !otherInstances().isEmpty, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        otherInstances().forEach { $0.forceTerminate() }
    }

    @discardableResult
    private static func launchctl(_ arguments: String...) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
