import Foundation

@MainActor
final class AppState: ObservableObject {
    @Published var counts: StatusCounts = .empty
    @Published var isBusy = false
    @Published var lastError: String?
    @Published var lastLog: String = ""
    @Published var storedUsername: String = Keychain.loadString(account: KeychainAccount.username) ?? ""
    @Published var pendingHVChallenge: HVChallenge?

    @Published var isUploading = false
    @Published var uploadProgress: UploadProgress?

    private var uploadProcess: Process?

    // Held only in memory, only for the duration of a login attempt that
    // needs human verification, so the retry (after the user solves the
    // challenge) can resubmit the same credentials. Never persisted.
    private var pendingCredentials: (username: String, password: String, totp: String)?

    init() {
        // Without this the menu bar label would show a stale 0 until the
        // popover was opened for the first time (which is what used to
        // trigger the only status refresh).
        Task { await refreshStatus() }
    }

    /// A stored item is not enough -- one written by an older version of
    /// this app can't unlock the keyring, and treating it as signed in
    /// leaves the app stuck with no way to re-authenticate.
    var hasSession: Bool {
        PhotonRunner.storedSession() != nil
    }

    func refreshStatus() async {
        do {
            counts = try await PhotonRunner.status()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func login(username: String, password: String, totp: String) async {
        await performLogin(username: username, password: password, totp: totp, hv: nil)
    }

    /// Called after the user solves the webview challenge; resubmits the
    /// original credentials with the solved proof attached, same as
    /// Proton's own apps retry their auth request.
    func solveHumanVerification(_ proof: HVProof) async {
        guard let creds = pendingCredentials else { return }
        pendingHVChallenge = nil
        await performLogin(username: creds.username, password: creds.password, totp: creds.totp, hv: proof)
    }

    func cancelHumanVerification() {
        pendingHVChallenge = nil
        pendingCredentials = nil
        isBusy = false
    }

    private func performLogin(username: String, password: String, totp: String, hv: HVProof?) async {
        isBusy = true
        defer { isBusy = false }
        do {
            let outcome = try await PhotonRunner.login(username: username, password: password, totp: totp, hv: hv)
            switch outcome.status {
            case "hv_required":
                guard let token = outcome.hvToken, let methods = outcome.hvMethods else {
                    lastError = "Proton requested verification but didn't provide a usable challenge."
                    return
                }
                pendingCredentials = (username, password, totp)
                pendingHVChallenge = HVChallenge(token: token, methods: methods)
                lastError = nil
            case "ok":
                guard let session = outcome.session else {
                    lastError = "Login reported success but returned no session."
                    return
                }
                // Credentials live in the Keychain; the password itself is
                // never stored, only the resumable session it produced.
                let data = try JSONEncoder().encode(session)
                Keychain.save(account: KeychainAccount.session, data: data)
                Keychain.save(account: KeychainAccount.username, string: username)
                storedUsername = username
                pendingCredentials = nil
                lastError = nil
                await refreshStatus()
            default:
                lastError = "Unexpected login response: \(outcome.status)"
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func startUpload(limit: Int? = nil) async {
        guard !isUploading else { return }
        isUploading = true
        uploadProgress = UploadProgress()
        lastError = nil

        // Counters are updated from the upload's own output rather than by
        // re-querying the database per file: the batch process is writing to
        // that database continuously, and polling it would mean a subprocess
        // per refresh. refreshStatus() at the end reconciles any drift.
        let base = counts

        defer {
            isUploading = false
            uploadProcess = nil
        }

        do {
            try await PhotonRunner.uploadBatch(
                limit: limit,
                onStart: { [weak self] process in
                    Task { @MainActor in self?.uploadProcess = process }
                },
                onProgress: { [weak self] progress in
                    Task { @MainActor in
                        guard let self else { return }
                        self.uploadProgress = progress
                        self.counts = StatusCounts(
                            pending: max(0, base.pending - progress.completed),
                            uploaded: base.uploaded + progress.uploaded,
                            skippedDuplicate: base.skippedDuplicate + progress.skipped,
                            failed: base.failed + progress.failed
                        )
                    }
                }
            )
        } catch {
            lastError = error.localizedDescription
        }

        await refreshStatus()
    }

    func cancelUpload() {
        uploadProcess?.terminate()
        uploadProcess = nil
    }

    /// Resets failed assets back to pending so "Upload Pending" picks them up
    /// again. The Go side has a `retry-failed` command; we run it the same way
    /// as `status` -- a short, session-free invocation that just touches the
    /// DB -- then refresh counts so the dropdown reflects the change.
    func retryFailed() async {
        guard hasSession else {
            lastError = "Not signed in yet -- open Settings and sign in first."
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            try await PhotonRunner.retryFailed()
            lastError = nil
            await refreshStatus()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func reconcile() async {
        guard hasSession else {
            lastError = "Not signed in yet -- open Settings and sign in first."
            return
        }

        isBusy = true
        defer { isBusy = false }
        do {
            lastLog = try await PhotonRunner.reconcile()
            lastError = nil
            await refreshStatus()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func signOut() {
        Keychain.delete(account: KeychainAccount.session)
    }
}
