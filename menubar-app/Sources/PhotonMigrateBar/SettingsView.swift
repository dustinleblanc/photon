import SwiftUI

/// Real, activatable window -- unlike the MenuBarExtra popover, this can
/// safely hold text fields without the window disappearing when a field
/// takes focus.
struct SettingsView: View {
    @EnvironmentObject var state: AppState

    @State private var username: String = ""
    @State private var password: String = ""
    @State private var totp: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Proton Account")
                .font(.headline)

            if state.hasSession {
                Text("Signed in as \(state.storedUsername)")
                    .foregroundStyle(.secondary)
                Button("Sign Out") {
                    state.signOut()
                }
            } else {
                Text("Sign in once -- Photon Migrate will silently refresh the session afterward, without asking for your password or 2FA code again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                TextField("Username or email", text: $username)
                SecureField("Password", text: $password)
                TextField("2FA code (if enabled)", text: $totp)

                if let error = state.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Spacer()
                    Button {
                        Task { await state.login(username: username, password: password, totp: totp) }
                    } label: {
                        if state.isBusy {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Sign In")
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(state.isBusy || username.isEmpty || password.isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            username = state.storedUsername
        }
        .sheet(item: $state.pendingHVChallenge) { challenge in
            HumanVerificationView(
                challenge: challenge,
                onSolved: { proof in
                    Task { await state.solveHumanVerification(proof) }
                },
                onCancel: {
                    state.cancelHumanVerification()
                }
            )
        }
    }
}
