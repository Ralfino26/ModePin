import Foundation
import os

/// Logs to the unified log and to ~/Library/Logs/ModePin.log, so "what did
/// it do last night" can be answered without Console.app.
public enum Log {
    public static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/ModePin.log")

    private static let logger = Logger(subsystem: ModePin.bundleIdentifier, category: "general")
    private static let queue = DispatchQueue(label: "ModePin.log")
    private static let maxBytes = 1_000_000

    public static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        append("INFO ", message)
    }

    public static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        append("ERROR", message)
    }

    private static func append(_ level: String, _ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(level) \(message)\n"
        queue.async {
            let fm = FileManager.default
            if let size = try? fm.attributesOfItem(atPath: fileURL.path)[.size] as? Int, size > maxBytes {
                let old = fileURL.appendingPathExtension("1")
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: fileURL, to: old)
            }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? Data(line.utf8).write(to: fileURL)
            }
        }
    }

    /// Waits for pending writes; the CLI calls this before exiting.
    public static func flush() { queue.sync {} }
}
