import SwiftUI
import DiskJockeyLibrary
import Combine

struct MountView: View {
    // MARK: - Properties
    
    @EnvironmentObject private var mountRepository: MountRepository
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
            if mountRepository.isLoading {
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
                List(mountRepository.mounts, id: \.id) { mount in
                    MountRow(mount: mount)
                }
            }
        }
        .navigationTitle("Mounts")
        .sheet(isPresented: $isAddingMount) {
            AddMountView()
        }
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

// MARK: - MountRow

struct MountRow: View {
    let mount: Mount
    @State private var isHovering = false
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(mount.name)
                    .font(.headline)
                
                if !mount.path.isEmpty {
                    Text(mount.path)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            statusBadge
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
    
    private var statusBadge: some View {
        Group {
            if mount.isMounted {
                Text("Mounted")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.green.opacity(0.2)))
                    .foregroundColor(.green)
            } else {
                Text("Not Mounted")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.red.opacity(0.2)))
                    .foregroundColor(.red)
            }
        }
    }
}

// MARK: - AddMountView

struct AddMountView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var path: String = ""
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Add New Mount")
                .font(.title2)
                .fontWeight(.bold)
            
            Form {
                TextField("Name", text: $name)
                TextField("Path", text: $path)
            }
            .formStyle(.grouped)
            .frame(width: 400)
            
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                
                Spacer()
                
                Button("Add") {
                    // TODO: Implement add mount
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty || path.isEmpty)
            }
        }
        .padding()
        .frame(width: 450)
    }
}

