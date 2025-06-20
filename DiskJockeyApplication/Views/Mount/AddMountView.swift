import SwiftUI
import DiskJockeyLibrary

struct AddMountView: View {
    var onCancel: (() -> Void)? = nil
    @EnvironmentObject private var diskTypeRepository: DiskTypeRepository
    @EnvironmentObject private var mountRepository: MountRepository
    @Environment(\.dismiss) private var dismiss
    
    // Local state for form
    @State private var selectedDiskTypeIndex: Int = 0
    @State private var name: String = ""
    @State private var url: String = ""
    @State private var port: String = ""
    @State private var isCreating = false
    @State private var error: String? = nil
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Disk type dropdown
            Picker("Mount Type", selection: $selectedDiskTypeIndex) {
                ForEach(diskTypeRepository.diskTypes.indices, id: \ .self) { idx in
                    Text(diskTypeRepository.diskTypes[idx].name).tag(idx)
                }
            }
            .pickerStyle(MenuPickerStyle())
            .padding(.top)
            
            // Show form for selected type
            Group {
                if let diskType = DiskTypeEnum(rawValue: diskTypeRepository.diskTypes[safe: selectedDiskTypeIndex]?.name ?? "") {
                    mountFormView(for: diskType)
                }    
            }
            Spacer()
            HStack {
                Button("Cancel") {
                    if let onCancel = onCancel {
                        onCancel()
                    } else {
                        dismiss()
                    }
                }
                Spacer()
                Button(action: {
                    error = nil
                    isCreating = true
                    let diskTypeObj = diskTypeRepository.diskTypes[safe: selectedDiskTypeIndex]
                    let diskType = diskTypeObj?.name ?? ""
                    // Compose mount object (minimal for demo)
                    let mount = Mount(
                        id: UUID(),
                        diskType: DiskTypeEnum(rawValue: diskType) ?? .localdirectory,
                        name: name,
                        path: url,
                        remotePath: "",
                        isMounted: false,
                        lastAccessed: nil,
                        metadata: [:]
                    )
                    Task {
                        do {
                            try await mountRepository.addMount(mount)
                            isCreating = false
                            if let onCancel = onCancel {
                                onCancel()
                            } else {
                                dismiss()
                            }
                        } catch {
                            self.error = error.localizedDescription
                            isCreating = false
                        }
                    }
                }) {
                    HStack {
                        if isCreating {
                            ProgressView().scaleEffect(0.7)
                        }
                        Text("Create Mount")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isCreating || name.isEmpty || url.isEmpty)
            
            }
            if let error = error {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
                    .padding(.top, 4)
            }
        }
        .padding()
        .navigationTitle("Add Mount")
    }
    
    @ViewBuilder
    private func mountFormView(for diskType: DiskTypeEnum) -> some View {
        switch diskType {
        case .localdirectory:
            LocalDirectoryMountForm(name: $name, url: $url, port: $port)
        case .dropbox:
            DropboxMountForm(name: $name, url: $url, port: $port)
        case .webdav:
            WebDAVMountForm(name: $name, url: $url, port: $port)
        case .ftp:
            FTPMountForm(name: $name, url: $url, port: $port)
        case .sftp:
            SFTPMountForm(name: $name, url: $url, port: $port)
        case .samba:
            SambaMountForm(name: $name, url: $url, port: $port)
        }
    }
}

// MARK: - DiskType-specific forms (simple for now)

struct DropboxMountForm: View {
    @Binding var name: String
    @Binding var url: String
    @Binding var port: String
    var body: some View {
        VStack(alignment: .leading) {
            Text("Dropbox Mount").font(.headline)
            TextField("Name", text: $name)
            TextField("URL", text: $url)
            TextField("Port", text: $port)
        }
    }
}

struct WebDAVMountForm: View {
    @Binding var name: String
    @Binding var url: String
    @Binding var port: String
    var body: some View {
        VStack(alignment: .leading) {
            Text("WebDAV Mount").font(.headline)
            TextField("Name", text: $name)
            TextField("URL", text: $url)
            TextField("Port", text: $port)
        }
    }
}

struct FTPMountForm: View {
    @Binding var name: String
    @Binding var url: String
    @Binding var port: String
    var body: some View {
        VStack(alignment: .leading) {
            Text("FTP Mount").font(.headline)
            TextField("Name", text: $name)
            TextField("URL", text: $url)
            TextField("Port", text: $port)
        }
    }
}

struct SFTPMountForm: View {
    @Binding var name: String
    @Binding var url: String
    @Binding var port: String
    var body: some View {
        VStack(alignment: .leading) {
            Text("SFTP Mount").font(.headline)
            TextField("Name", text: $name)
            TextField("URL", text: $url)
            TextField("Port", text: $port)
        }
    }
}

struct SambaMountForm: View {
    @Binding var name: String
    @Binding var url: String
    @Binding var port: String
    var body: some View {
        VStack(alignment: .leading) {
            Text("Samba Mount").font(.headline)
            TextField("Name", text: $name)
            TextField("URL", text: $url)
            TextField("Port", text: $port)
        }
    }
}

struct LocalDirectoryMountForm: View {
    @Binding var name: String
    @Binding var url: String
    @Binding var port: String
    var body: some View {
        VStack(alignment: .leading) {
            Text("Local Directory Mount").font(.headline)
            TextField("Name", text: $name)
            TextField("URL", text: $url)
            TextField("Port", text: $port)
        }
    }
}

// Safe array index extension
extension Collection {
    subscript(safe index: Index) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}
