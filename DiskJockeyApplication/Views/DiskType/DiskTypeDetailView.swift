import SwiftUI
import DiskJockeyLibrary

/// A view that displays detailed information about a remote disk type
struct DiskTypeDetailView: View {
    // MARK: - Properties
    
    let diskType: DiskType
    @Environment(\.dismiss) private var dismiss
    
    // MARK: - Body
    
    var body: some View {
        Form {
            // Disk Type Info Section
            Section("Disk Type Information") {
                InfoRow(label: "Name", value: diskType.name)
                InfoRow(label: "Version", value: diskType.version)
                InfoRow(label: "ID", value: diskType.id)
            }
            
            // Description Section
            if !diskType.description.isEmpty {
                Section("Description") {
                    Text(diskType.description)
                        .padding(.vertical, 4)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(diskType.name)
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
