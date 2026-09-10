import Foundation

// Runs the `photon-migrate` Go binary as a subprocess and parses its output.
// All the real logic (Proton auth, the status DB, reconciliation) lives in
// that binary -- this is intentionally a thin wrapper.
enum PhotonRunner {
    /// Where the `photon-migrate` binary lives, in preference order:
    ///
    ///  1. `PHOTON_MIGRATE_BIN`, for pointing a build at a local rebuild
    ///  2. the app bundle's Resources, which is how it ships
    ///  3. the development checkout, so `swift run` works from a source tree
    ///
    /// The Go side resolves `photos-helper` the same way -- relative to
    /// itself -- so both land in Contents/Resources together and neither
    /// needs to know an absolute path.
    static let binaryPath: URL = {
        if let override = ProcessInfo.processInfo.environment["PHOTON_MIGRATE_BIN"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        if let bundled = Bundle.main.url(forResource: "photon-migrate", withExtension: nil) {
            return bundled
        }
        // Walk upward from this source file's location to find the repo root
        // (has go.mod), then look for the Go binary in the expected build location.
        let sourceDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var dir = sourceDir
        for _ in 0..<10 {
            let goMod = dir.appendingPathComponent("go.mod")
            if FileManager.default.fileExists(atPath: goMod.path) {
                let candidate = dir.appendingPathComponent("go-uploader/photon-migrate")
                if FileManager.default.fileExists(atPath: candidate.path) {
                    return candidate
                }
                break
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        // Last resort: hope it's on PATH
        return URL(fileURLWithPath: "photon-migrate")
    }()

    struct Result {
        let stdout: String
        let stderr: String
        let exitCode: Int32
    }

    enum RunnerError: LocalizedError {
        case nonZeroExit(Result)
        case decodeFailure(String)

        var errorDescription: String? {
            switch self {
            case .nonZeroExit(let result):
                return "photon-migrate exited \(result.exitCode): \(result.stderr)"
            case .decodeFailure(let raw):
                return "failed to parse output: \(raw)"
            }
        }
    }

    /// Accumulates piped bytes and emits whole lines. The pipe handlers fire
    /// on a background queue, hence the lock.
    private final class LineBuffer {
        private let lock = NSLock()
        private var pending = ""

        func take(_ chunk: Data, _ emit: (String) -> Void) {
            guard let text = String(data: chunk, encoding: .utf8), !text.isEmpty else { return }
            lock.lock()
            pending += text
            var lines = pending.components(separatedBy: "\n")
            pending = lines.removeLast() // trailing partial line
            lock.unlock()
            for line in lines where !line.isEmpty {
                emit(line)
            }
        }

        func flush(_ emit: (String) -> Void) {
            lock.lock()
            let rest = pending
            pending = ""
            lock.unlock()
            if !rest.isEmpty { emit(rest) }
        }
    }

    /// Runs a long-lived command, delivering output line by line as it
    /// arrives instead of buffering until exit. `onStart` hands back the
    /// Process so the caller can cancel it.
    static func runStreaming(
        _ args: [String],
        env extraEnv: [String: String] = [:],
        onStart: @escaping (Process) -> Void,
        onLine: @escaping (String, Bool) -> Void
    ) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = binaryPath
            process.arguments = args

            var env = ProcessInfo.processInfo.environment
            for (k, v) in sessionEnv() { env[k] = v }
            for (k, v) in extraEnv { env[k] = v }
            process.environment = env

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let outBuffer = LineBuffer()
            let errBuffer = LineBuffer()

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                outBuffer.take(handle.availableData) { onLine($0, false) }
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                errBuffer.take(handle.availableData) { onLine($0, true) }
            }

            process.terminationHandler = { proc in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                outBuffer.flush { onLine($0, false) }
                errBuffer.flush { onLine($0, true) }
                continuation.resume(returning: proc.terminationStatus)
            }

            do {
                try process.run()
                onStart(process)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// The stored session, if there is a *usable* one.
    ///
    /// Validated rather than passed through blind: an item written by an
    /// older version of this app lacks saltedKeyPass, and handing that to
    /// the Go side produces an opaque "private key checksum failure" when
    /// it tries to unlock the keyring with an empty passphrase.
    static func storedSession() -> ProtonSession? {
        guard let data = Keychain.loadData(account: KeychainAccount.session),
              let session = try? JSONDecoder().decode(ProtonSession.self, from: data),
              !session.saltedKeyPass.isEmpty,
              !session.uid.isEmpty,
              !session.refreshToken.isEmpty
        else { return nil }
        return session
    }

    /// The stored session, passed to every command that needs auth. Kept in
    /// the Keychain rather than on disk, and never written to the database.
    static func sessionEnv() -> [String: String] {
        guard let session = storedSession(),
              let data = try? JSONEncoder().encode(session),
              let json = String(data: data, encoding: .utf8)
        else { return [:] }
        return ["PROTON_UPLOAD_SESSION_JSON": json]
    }

    /// Proton rotates tokens when an expired one is refreshed mid-run, and
    /// the caller needs that new value or the next run resumes with stale
    /// credentials. It travels via a private file rather than stdout/stderr:
    /// those streams end up in terminal scrollback, shell history, and this
    /// app's own log file, none of which should ever hold a live token.
    /// A plain CLI invocation that doesn't pass --session-out gets no
    /// exposure at all -- this is opt-in for callers that want it back.
    private static func makeSessionOutPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("photon-migrate-session-\(UUID().uuidString).json")
            .path
    }

    /// Reads whatever the Go side wrote to `path` (if anything -- a run
    /// with no rotation writes nothing) and removes the file unconditionally
    /// afterward, so no copy of the token outlives the one command it was
    /// for.
    private static func consumeSessionOutFile(_ path: String) {
        defer { try? FileManager.default.removeItem(atPath: path) }
        guard let data = FileManager.default.contents(atPath: path),
              (try? JSONDecoder().decode(ProtonSession.self, from: data)) != nil
        else { return }
        Keychain.save(account: KeychainAccount.session, data: data)
    }

    static func run(_ args: [String], env extraEnv: [String: String] = [:]) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = binaryPath
            process.arguments = args

            var env = ProcessInfo.processInfo.environment
            for (k, v) in sessionEnv() { env[k] = v }
            for (k, v) in extraEnv { env[k] = v }
            process.environment = env

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }

            process.terminationHandler = { proc in
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let result = Result(
                    stdout: String(data: stdoutData, encoding: .utf8) ?? "",
                    stderr: String(data: stderrData, encoding: .utf8) ?? "",
                    exitCode: proc.terminationStatus
                )
                AppLog.append(command: args, result: result)
                continuation.resume(returning: result)
            }
        }
    }

    static func status() async throws -> StatusCounts {
        let result = try await run(["status", "--json"])
        guard result.exitCode == 0 else { throw RunnerError.nonZeroExit(result) }
        guard let data = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let counts = try? JSONDecoder().decode(StatusCounts.self, from: data)
        else {
            throw RunnerError.decodeFailure(result.stdout)
        }
        return counts
    }

    /// Resets failed assets to pending so the next "Upload Pending" retries
    /// them. `retry-failed` only touches the status DB, so it needs no session.
    static func retryFailed() async throws {
        let result = try await run(["retry-failed", "--json"])
        guard result.exitCode == 0 else { throw RunnerError.nonZeroExit(result) }
    }

    /// Signs in and returns the session for the caller to store. There is
    /// one session for everything now -- status, reconcile and uploads all
    /// share it.
    static func login(username: String, password: String, totp: String, hv: HVProof? = nil) async throws -> LoginOutcome {
        var env = [
            "PROTON_USERNAME": username,
            "PROTON_PASSWORD": password,
            "PROTON_2FA": totp,
        ]
        if let hv {
            env["PROTON_HV_TOKEN"] = hv.token
            env["PROTON_HV_METHOD"] = hv.method
        }

        let result = try await run(["upload-login"], env: env)
        guard result.exitCode == 0 else { throw RunnerError.nonZeroExit(result) }
        guard let data = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let outcome = try? JSONDecoder().decode(LoginOutcome.self, from: data)
        else {
            throw RunnerError.decodeFailure(result.stdout)
        }
        return outcome
    }

    /// Runs the batch upload, reporting progress as it goes. The stored
    /// session is attached automatically, so no credentials are needed
    /// after the initial sign-in.
    static func uploadBatch(
        limit: Int?,
        onStart: @escaping (Process) -> Void,
        onProgress: @escaping (UploadProgress) -> Void
    ) async throws {
        // --exit-with-parent so a force-quit (where no cleanup handler runs)
        // doesn't leave the batch uploading invisibly in the background.
        var args = ["upload-batch", "--exit-with-parent"]
        if let limit {
            args += ["--limit", String(limit)]
        }
        let sessionPath = makeSessionOutPath()
        args += ["--session-out", sessionPath]
        defer { consumeSessionOutFile(sessionPath) }

        var progress = UploadProgress()
        AppLog.append("$ photon-migrate \(args.joined(separator: " "))")

        let exitCode = try await runStreaming(args, onStart: onStart) { line, isStderr in
            AppLog.append(isStderr ? "stderr: \(line)" : line)
            progress.apply(line: line)
            onProgress(progress)
        }

        guard exitCode == 0 else {
            throw RunnerError.nonZeroExit(Result(stdout: "", stderr: progress.lastMessage, exitCode: exitCode))
        }
    }

    /// Matches pending assets against what is already on Proton. Uses the
    /// stored session like every other command.
    static func reconcile() async throws -> String {
        let sessionPath = makeSessionOutPath()
        defer { consumeSessionOutFile(sessionPath) }

        let result = try await run(["reconcile", "--session-out", sessionPath])
        guard result.exitCode == 0 else { throw RunnerError.nonZeroExit(result) }
        return result.stdout
    }

}
