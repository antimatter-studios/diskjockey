import SwiftUI
import DiskJockeyLibrary

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
            let newMount = MountPoint(
                id: UUID(),
                name: "",
                type: .webdav,
                url: "",
                username: "",
                password: ""
                // hostname and shareName are optional with nil defaults
            )
            _form = State(initialValue: newMount)
            _mountTypeSelection = State(initialValue: "")
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isEditing ? "Mount Details" : "Add New Mount").font(.headline)
            
            Picker("Type", selection: $mountTypeSelection) {
                Text("Select Mount Type").tag("")
                ForEach(pluginTypes, id: \.self) { type in
                    Text(type).tag(type)
                }
            }
            .pickerStyle(MenuPickerStyle())
            
            TextField("Name", text: $form.name)
            TextField("URL", text: $form.url)
            TextField("Username", text: $form.username)
            SecureField("Password", text: $form.password)
            
            if mountTypeSelection == MountType.samba.rawValue {
                TextField("Hostname", text: Binding(
                    get: { form.hostname ?? "" },
                    set: { form.hostname = $0.isEmpty ? nil : $0 }
                ))
                TextField("Share Name", text: Binding(
                    get: { form.shareName ?? "" },
                    set: { form.shareName = $0.isEmpty ? nil : $0 }
                ))
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

