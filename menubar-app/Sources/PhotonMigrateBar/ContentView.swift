import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Photon Migrate")
                .font(.headline)

            if state.hasSession {
                StatusGrid(counts: state.counts)

                if let error = state.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if state.isUploading, let progress = state.uploadProgress {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: progress.fraction)
                        HStack {
                            Text(progress.total > 0 ? "\(progress.completed) of \(progress.total)" : "Preparing…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Stop") { state.cancelUpload() }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                        Text(progress.lastMessage)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack {
                    Button {
                        Task { await state.startUpload() }
                    } label: {
                        Text("Upload Pending")
                    }
                    .disabled(state.isUploading || state.isBusy || state.counts.pending == 0)

                    Button {
                        Task { await state.reconcile() }
                    } label: {
                        if state.isBusy {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Reconcile")
                        }
                    }
                    .disabled(state.isBusy || state.isUploading)

                    Button {
                        Task { await state.retryFailed() }
                    } label: {
                        Text("Retry Failed")
                    }
                    .disabled(state.isBusy || state.isUploading || state.counts.failed == 0)
                }

                HStack {
                    Spacer()
                    Button("Sign Out") {
                        state.signOut()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .font(.caption)
                }
            } else {
                Text("Not signed in to Proton.")
                    .foregroundStyle(.secondary)
                Button("Sign In…") {
                    SettingsWindowController.shared.show(state: state)
                }
            }

            Divider()

            Button("Open Log File") {
                NSWorkspace.shared.open(AppLog.fileURL)
            }
            .buttonStyle(.plain)

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .frame(width: 260)
        .task {
            await state.refreshStatus()
        }
    }
}

struct StatusGrid: View {
    let counts: StatusCounts

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            GridRow {
                Text("Pending").foregroundStyle(.secondary)
                Text("\(counts.pending)")
            }
            GridRow {
                Text("Uploaded").foregroundStyle(.secondary)
                Text("\(counts.uploaded)")
            }
            GridRow {
                Text("Already on Proton").foregroundStyle(.secondary)
                Text("\(counts.skippedDuplicate)")
            }
            GridRow {
                Text("Failed").foregroundStyle(.secondary)
                Text("\(counts.failed)")
                    .foregroundStyle(counts.failed > 0 ? .red : .primary)
            }
        }
        .font(.system(.body, design: .monospaced))
    }
}
