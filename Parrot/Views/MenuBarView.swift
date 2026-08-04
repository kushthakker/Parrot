import SwiftUI

/// Content of the menu-bar extra, rendered as a NATIVE menu
/// (.menuBarExtraStyle(.menu) in ParrotApp): Texts become disabled status
/// lines, Buttons become menu items. Status reflects the moment the menu
/// opens — that's standard menu behavior.
struct MenuBarView: View {
    @Environment(RecordingManager.self) private var recordingManager
    @Environment(ProfileStore.self) private var profileStore
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if recordingManager.isRecording {
            Text("Recording — \(recordingManager.formattedElapsedTime)")

            Button(recordingManager.isStopping ? "Finalizing…" : "Stop Recording") {
                Task { await recordingManager.stopRecording() }
            }
            .disabled(recordingManager.isStopping)
        } else {
            Text(recordingManager.transcriptionEngine.isReady
                 ? "Ready — \(profileStore.activeProfile?.name ?? "Default")"
                 : "Loading model…")

            Button("Start Recording") {
                Task {
                    do {
                        // Same preflight as the dashboard button — without it
                        // this path silently failed when Screen Recording
                        // permission was missing.
                        try await recordingManager.preflightPermissionsAndStart(modelContext: modelContext)
                    } catch {
                        NSApp.activate(ignoringOtherApps: true)
                        let alert = NSAlert()
                        alert.messageText = "Couldn't start recording"
                        alert.informativeText = error.localizedDescription
                        alert.runModal()
                    }
                }
            }
            .disabled(!recordingManager.transcriptionEngine.isReady)
        }

        Divider()

        Button("Open Parrot") {
            // Shows the Dock icon too; it retracts when the window closes.
            DockVisibility.openMain(using: { openWindow(id: "main") })
        }

        Divider()

        Button("Quit Parrot") {
            NSApplication.shared.terminate(nil)
        }
    }
}
