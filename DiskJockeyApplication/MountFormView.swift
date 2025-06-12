import SwiftUI

struct MountFormView: View {
    @EnvironmentObject var mountModel: MountModel
    var isEditing: Bool
    var mount: MountPoint? = nil
    var pluginTypes: [String]
    var onSave: () -> Void = {}
    var onCancel: () -> Void = {}
    @State private var form: MountPoint
    @State private var mountTypeSelection: String = ""
    @State private var showDeleteAlert = false
    
    // Initialize the form with default values
    init(isEditing: Bool, mount: MountPoint? = nil, pluginTypes: [String], onSave: @escaping () -> Void = {}, onCancel: @escaping () -> Void = {}) {
        self.isEditing = isEditing
        self.mount = mount
        self.pluginTypes = pluginTypes
        self.onSave = onSave
        self.onCancel = onCancel
        
        // Initialize form with either the provided mount or default values
        if let mount = mount {
            _form = State(initialValue: mount)
            _mountTypeSelection = State(initialValue: mount.type.rawValue)
        } else {
            _form = State(initialValue: MountPoint(
                id: UUID(), 
                name: "", 
                type: .webdav, 
                url: "", 
                username: "", 
                password: "", 
                hostname: nil, 
                shareName: nil))
            _mountTypeSelection = State(initialValue: "")
        }
    }
    
    @ViewBuilder
    private func fieldView(field: FormField) -> some View {
        if field.isOptional, let keyPath = field.optionalKeyPath {
            let binding = Binding<String>(
                get: { form[keyPath: keyPath] ?? "" },
                set: { form[keyPath: keyPath] = $0 }
            )
            if field.isSecure {
                SecureField(field.label, text: binding)
            } else {
                TextField(field.label, text: binding)
            }
        } else if let keyPath = field.stringKeyPath {
            let binding = Binding<String>(
                get: { form[keyPath: keyPath] },
                set: { form[keyPath: keyPath] = $0 }
            )
            if field.isSecure {
                SecureField(field.label, text: binding)
            } else {
                TextField(field.label, text: binding)
            }
        }
    }

    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isEditing, let mount = mount {
                Text("Mount Details").font(.headline)
            } else {
                Text("Add New Mount").font(.headline)
            }
            
            Picker("Type", selection: $mountTypeSelection) {
                Text("Select Mount Type").tag("")
                ForEach(pluginTypes, id: \.self) { type in
                    Text(type).tag(type)
                }
            }
            .pickerStyle(MenuPickerStyle())
            
            ForEach(MountFormSchema.fields(for: mountTypeSelection)) { field in
                fieldView(field: field)
            }
            
            HStack {
                if isEditing {
                    Button(action: { showDeleteAlert = true }) {
                        Label("Delete", systemImage: "trash")
                            .foregroundColor(.red)
                    }
                    .alert(isPresented: $showDeleteAlert) {
                        Alert(
                            title: Text("Delete Mount?"), 
                            message: Text("Are you sure you want to delete this mount?"), 
                            primaryButton: .destructive(Text("Delete")) {
                                if let mount = mount {
                                    mountModel.mounts.removeAll { $0.id == mount.id }
                                    mountModel.selectedMount = nil
                                    onSave()
                                }
                            }, 
                            secondaryButton: .cancel()
                        )
                    }
                }
                
                Spacer()
                
                HStack(spacing: 12) {
                    Button(action: {
                        onCancel()
                    }) {
                        Text("Cancel")
                    }
                    .buttonStyle(.bordered)
                    
                    Button(action: {
                        // Only update form.type if a valid type is selected
                        if let validType = MountType(rawValue: mountTypeSelection) {
                            form.type = validType
                        }
                        
                        if isEditing, let mount = mount {
                            if let idx = mountModel.mounts.firstIndex(where: { $0.id == mount.id }) {
                                mountModel.mounts[idx] = form
                            }
                            mountModel.selectedMount = form
                            onSave()
                        } else {
                            mountModel.mounts.append(form)
                            onSave()
                        }
                    }) {
                        Label(isEditing ? "Save" : "Add", systemImage: "externaldrive")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(mountTypeSelection.isEmpty)
                }
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(.windowBackgroundColor)))
        .shadow(radius: 1)
    }
}

