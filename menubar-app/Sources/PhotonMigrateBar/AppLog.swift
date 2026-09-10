import Foundation

/// Persists every `photon` subprocess invocation to a plain text
/// file under ~/Library/Logs -- the standard macOS location for app logs
/// (readable in Console.app, or with any text editor/`tail`). This exists
/// because the menu bar popover's output isn't copyable, and because a
/// button-triggered action has no other way to hand its output back for
/// inspection.
enum AppLog {
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/PhotonMigrate")
    static let fileURL = directory.appendingPathComponent("photon.log")

    static func append(command: [String], result: PhotonRunner.Result) {
        let formatter = ISO8601DateFormatter()
        let entry = """
        ---- \(formatter.string(from: Date())) ----
        $ photon \(command.joined(separator: " "))
        exit: \(result.exitCode)
        stdout:
        \(redact(result.stdout))
        stderr:
        \(redact(result.stderr))

        """
        write(entry)
    }

    static func append(_ message: String) {
        let formatter = ISO8601DateFormatter()
        write("---- \(formatter.string(from: Date())) ----\n\(message)\n\n")
    }

    /// Strips access/refresh tokens and full SESSION_JSON payloads before
    /// anything touches disk -- the log is for reading command output, not
    /// for persisting long-lived credentials in plaintext.
    private static func redact(_ text: String) -> String {
        var result = text
        for field in ["accessToken", "refreshToken", "saltedKeyPass"] {
            result = result.replacingOccurrences(
                of: #"("\#(field)"\s*:\s*")[^"]*(")"#,
                with: "$1***$2",
                options: .regularExpression
            )
        }
        result = result.replacingOccurrences(
            of: #"SESSION_JSON:\{[^\n]*\}"#,
            with: "SESSION_JSON:<redacted>",
            options: .regularExpression
        )
        return result
    }

    private static func write(_ text: String) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                handle.seekToEndOfFile()
                handle.write(Data(text.utf8))
                try? handle.close()
            } else {
                try text.write(to: fileURL, atomically: true, encoding: .utf8)
            }
        } catch {
            // Logging is best-effort; never let it crash the app.
        }
    }
}
