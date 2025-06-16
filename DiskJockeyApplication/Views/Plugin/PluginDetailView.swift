import SwiftUI
import DiskJockeyLibrary

/// A view that displays detailed information about a remote disk type
struct PluginDetailView: View {
    // MARK: - Properties
    
    let plugin: Plugin
    @Environment(\.dismiss) private var dismiss
    
    // MARK: - Body
    
    var body: some View {
        Form {
            // Plugin Info Section
            Section("Disk Type Information") {
                InfoRow(label: "Name", value: plugin.name)
                InfoRow(label: "Version", value: plugin.version)
                InfoRow(label: "ID", value: plugin.id)
            }
            
            // Description Section
            if !plugin.description.isEmpty {
                Section("Description") {
                    Text(plugin.description)
                        .padding(.vertical, 4)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(plugin.name)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }
    }
}

// MARK: - InfoRow

private struct InfoRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
        }
    }
}
