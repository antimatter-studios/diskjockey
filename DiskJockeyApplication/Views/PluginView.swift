import SwiftUI
import DiskJockeyLibrary

public struct PluginView: View {
    // MARK: - Properties
    
    @StateObject private var viewModel: PluginViewModel
    @State private var isRefreshing = false

    init(repository: PluginRepository) {
        _viewModel = StateObject(wrappedValue: PluginViewModel(repository: repository))
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
                    "Error Loading Plugins",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error.localizedDescription)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.plugins.isEmpty {
                ContentUnavailableView(
                    "No Plugins",
                    systemImage: "puzzlepiece.extension",
                    description: Text("No plugins are currently available")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(viewModel.plugins, id: \.id) { plugin in
                    HStack {
                        Image(systemName: "puzzlepiece.extension.fill")
                            .foregroundColor(.accentColor)
                            .frame(width: 24, height: 24)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text(plugin.name)
                                .font(.headline)
                            Text(plugin.description)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("v\(plugin.version)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("Plugins")
        .task {
            // Only load if we don't have any plugins yet
            if viewModel.plugins.isEmpty {
                await viewModel.loadPlugins()
            }
        }
    }
    
    // MARK: - Private Methods
    
    private func refresh() {
        Task {
            isRefreshing = true
            defer { isRefreshing = false }
            await viewModel.loadPlugins()
        }
    }
}

