import SwiftUI

struct MountView: View {
    @EnvironmentObject var mountModel: MountModel
    @EnvironmentObject var pluginModel: PluginModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 1. Title "Mount" - pinned to the top
            Text("Mount")
                .font(.title2)
                .bold()
                .padding(.bottom, 4)
            
            // 2. Listbox with white background
            ZStack(alignment: .leading) {
                // Mount list container
                VStack(alignment: .leading, spacing: 0) {
                    // 3 & 4. Show mounts if not empty with names
                    if mountModel.mounts.isEmpty {
                        Text("No mounts available")
                            .foregroundColor(.secondary)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .center)
                    } else {
                        // List of mounts
                        List {
                            ForEach(mountModel.mounts) { mount in
                                // 5. Make mounts clickable
                                Button(action: {
                                    // 6. Open mount form view on click
                                    mountModel.selectedMount = mount
                                }) {
                                    Text(mount.name.isEmpty ? mount.url : mount.name)
                                        .foregroundColor(.primary)
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                        }
                        .listStyle(PlainListStyle())
                    }
                }
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
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
