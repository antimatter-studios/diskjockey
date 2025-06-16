import SwiftUI

struct QuitPanelView: View {
    @State private var isQuitting = false
    @State private var shutdownMessage = "Preparing to shut down remote disks and save data..."
    
    var body: some View {
        VStack(alignment: .center, spacing: 20) {
            Text("Quit Disk Jockey")
                .font(.title2)
                .bold()
                .padding(.top, 16)
            Text("Before quitting, all remote disks will be unmounted and data will be saved. Please wait for the shutdown process to complete.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
            if isQuitting {
                ProgressView(shutdownMessage)
                    .padding(.vertical)
            } else {
                Button(action: beginShutdown) {
                    Label("Quit and Unmount All", systemImage: "power")
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)
            }
        }
        .frame(maxWidth: 400)
        .padding()
    }
    
    private func beginShutdown() {
        isQuitting = true
        shutdownMessage = "Unmounting remote disks..."
        // Simulate shutdown process (replace with real logic)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            shutdownMessage = "Saving data..."
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                NSApp.terminate(nil)
            }
        }
    }
}
