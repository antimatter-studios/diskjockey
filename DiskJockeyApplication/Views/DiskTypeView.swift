import SwiftUI
import DiskJockeyLibrary

public struct DiskTypeView: View {
    // MARK: - Properties
    
    @StateObject private var viewModel: DiskTypeViewModel
    @State private var isRefreshing = false

    init(repository: DiskTypeRepository) {
        _viewModel = StateObject(wrappedValue: DiskTypeViewModel(repository: repository))
    }
        
    // MARK: - Body
    
    public var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Button(action: refresh) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(isRefreshing || viewModel.isLoading)
                
                Spacer()
                
                if viewModel.isLoading || isRefreshing {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 20, height: 20)
                }
            }
            .padding()
            
            Divider()
            
            // Content
            if let error = viewModel.error {
                ContentUnavailableView(
                    "Error Loading Disk Types",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error.localizedDescription)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.diskTypes.isEmpty {
                ContentUnavailableView(
                    "No Disk Types",
                    systemImage: "puzzlepiece.extension",
                    description: Text("No Disk Types are currently available")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(viewModel.diskTypes, id: \.id) { diskType in
                    HStack {
                        Image(systemName: "puzzlepiece.extension.fill")
                            .foregroundColor(.accentColor)
                            .frame(width: 24, height: 24)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text(diskType.name)
                                .font(.headline)
                            Text(diskType.description)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("v\(diskType.version)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("Disk Types")
        .task {
            // Only load if we don't have any diskTypes yet
            if viewModel.diskTypes.isEmpty {
                await viewModel.loadDiskTypes()
            }
        }
    }
    
    // MARK: - Private Methods
    
    private func refresh() {
        Task {
            isRefreshing = true
            defer { isRefreshing = false }
            await viewModel.loadDiskTypes()
        }
    }
}

