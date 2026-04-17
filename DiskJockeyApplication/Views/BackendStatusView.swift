import SwiftUI
import DiskJockeyLibrary

struct BackendStatusView: View {
    @ObservedObject var container: AppContainer

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()
        }
    }

    private var statusColor: Color {
        switch container.connectionState {
        case .connected:
            return .green
        case .connecting:
            return .orange
        case .disconnected:
            return .red
        case .failed:
            return .red
        }
    }

    private var statusText: String {
        switch container.connectionState {
        case .connected(let info):
            return "Backend connected (\(info.host):\(info.port))"
        case .connecting:
            return "Connecting..."
        case .disconnected:
            return "Backend disconnected"
        case .failed:
            return "Connection failed"
        }
    }
}
