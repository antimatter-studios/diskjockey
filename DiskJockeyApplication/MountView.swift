import SwiftUI

struct MountView: View {
    @EnvironmentObject var mountModel: MountModel
    @EnvironmentObject var pluginModel: PluginModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 1. Title "Mount" - pinned to the top
            Text("Mount")
                .font(.title2)
                .bold()
                .padding(.bottom, 4)
            
            // 2. Listbox with white background
            ZStack(alignment: .bottomTrailing) {
                // Mount list container
                VStack(alignment: .leading, spacing: 0) {
                    // 3 & 4. Show mounts if not empty with names
                    if mountModel.mounts.isEmpty {
                        Text("No mounts available")
                            .foregroundColor(.secondary)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .center)
                    } else {
                        // Use ScrollView for scrollable content
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(mountModel.mounts) { mount in
                                    // 5. Make mounts clickable
                                    Button(action: {
                                        // 6. Open mount form view on click
                                        mountModel.selectedMount = mount
                                    }) {
                                        HStack {
                                            Text(mount.name.isEmpty ? mount.url : mount.name)
                                                .foregroundColor(.primary)
                                            Spacer()
                                        }
                                        .padding(.vertical, 8)
                                        .padding(.horizontal, 12)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(mountModel.selectedMount?.id == mount.id ? Color.gray.opacity(0.2) : Color.clear)
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                    
                                    if mount.id != mountModel.mounts.last?.id {
                                        Divider()
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .background(Color.white)
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )
                
                // 7. Add Mount button in bottom right
                Button(action: { 
                    mountModel.selectedMount = nil
                    mountModel.isAdding = true
                }) {
                    Label("Add Mount", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .padding(8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            // Mount form area
            if mountModel.isAdding {
                MountFormView(
                    isEditing: false,
                    pluginTypes: pluginModel.plugins.map { $0.name },
                    onSave: {
                        mountModel.isAdding = false
                    },
                    onCancel: { 
                        mountModel.isAdding = false 
                    }
                )
                .padding(.top, 12)
            } else if let selected = mountModel.selectedMount {
                MountFormView(
                    isEditing: true,
                    mount: selected,
                    pluginTypes: pluginModel.plugins.map { $0.name },
                    onSave: {
                        // Keep the selection after saving
                    },
                    onCancel: {
                        mountModel.selectedMount = nil
                    }
                )
                .padding(.top, 12)
            }
            
            Spacer() // Push everything to the top
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top) // Force top alignment
    }
}
