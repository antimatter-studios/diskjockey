import SwiftUI
import DiskJockeyLibrary
import Combine

struct MountView: View {
    // MARK: - Properties
    
    @EnvironmentObject private var mountRepository: MountRepository
    @EnvironmentObject private var diskTypeRepository: DiskTypeRepository
    @State private var isAddingMount = false
    
    // MARK: - Body
    
    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Button(action: { isAddingMount = true }) {
                    Label("Add Mount", systemImage: "plus")
                }
                
                Spacer()
                
                Button(action: refreshMounts) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(mountRepository.isLoading)
            }
            .padding()
            
            Divider()
            
            // Content
            if isAddingMount {
                AddMountView(onCancel: { isAddingMount = false })
                    .environmentObject(mountRepository)
                    .environmentObject(diskTypeRepository)
            } else if mountRepository.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if mountRepository.mounts.isEmpty {
                ContentUnavailableView(
                    "No Mounts",
                    systemImage: "externaldrive.badge.plus",
                    description: Text("Add a mount to get started")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ListMountView()
                    .environmentObject(mountRepository)
            }
        }
        .navigationTitle("Mounts")
        .onAppear {
            refreshMounts()
        }
    }
    
    // MARK: - Private Methods
    
    private func refreshMounts() {
        Task {
            await mountRepository.fetchMounts()
        }
    }
}

//#Preview {
//    MountView()
//}
