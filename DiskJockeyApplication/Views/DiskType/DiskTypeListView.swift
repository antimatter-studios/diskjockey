import SwiftUI
import DiskJockeyLibrary

/// A view that displays a list of available remote disk types
struct DiskTypeListView: View {
    // MARK: - Properties
    
    @StateObject private var viewModel: DiskTypeViewModel
    @State private var selectedDiskTypeId: String?
    
    // MARK: - Body
    
    var body: some View {
        NavigationSplitView {
            List(selection: $selectedDiskTypeId) {
                ForEach(viewModel.diskTypes, id: \.id) { diskType in
                    DiskTypeRow(diskType: diskType)
                        .contentShape(Rectangle())
                        .tag(diskType.id)
                }
            }
            .searchable(text: .constant(""), prompt: "Search remote disk types...")
            .navigationTitle("Remote Disk Types")
            .overlay {
                if viewModel.isLoading && viewModel.diskTypes.isEmpty {
                    ProgressView("Loading...")
                } else if viewModel.diskTypes.isEmpty {
                    ContentUnavailableView(
                        "No Remote Disk Types",
                        systemImage: "externaldrive",
                        description: Text("No remote disk types are currently available")
                    )
                }
            }
        } detail: {
            if let selectedId = selectedDiskTypeId, 
               let diskType = viewModel.diskTypes.first(where: { $0.id == selectedId }) {
                DiskTypeDetailView(diskType: diskType)
            } else {
                ContentUnavailableView(
                    "Select a Disk Type",
                    systemImage: "externaldrive",
                    description: Text("Select a remote disk type to view its details")
                )
            }
        }
        
        #if os(macOS)
        .frame(minWidth: 800, minHeight: 600)
        #endif
    }
}

// MARK: - DiskTypeRow

/// A single row in the disk type list
struct DiskTypeRow: View {
    let diskType: DiskType
    @State private var isHovering = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(diskType.name)
                        .font(.headline)
                    
                    if !diskType.description.isEmpty {
                        Text(diskType.description)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                }
                
                Spacer()
                
                Text("v\(diskType.version)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .background(isHovering ? Color(nsColor: .controlBackgroundColor) : .clear)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.1)) {
                isHovering = hovering
            }
        }
    }
}
