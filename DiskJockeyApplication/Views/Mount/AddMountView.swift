import SwiftUI
import DiskJockeyLibrary

struct AddMountView: View {
    @ObservedObject var diskTypeRepository: DiskTypeRepository
    @ObservedObject var mountRepository: MountRepository
    @Environment(\.dismiss) private var dismiss

    @State private var selectedDiskType: DiskTypeEnum = .sftp
    @State private var name: String = ""
    @State private var host: String = ""
    @State private var port: String = ""
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var remotePath: String = ""
    @State private var shareName: String = ""
    @State private var localPath: String = ""

    @State private var isCreating = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                Text("New Mount")
                    .font(.headline)
                Spacer()
            }
            .padding()

            Divider()

            // Form
            Form {
                // Mount type picker
                Picker("Type", selection: $selectedDiskType) {
                    ForEach(availableDiskTypes, id: \.self) { diskType in
                        Label(diskType.displayName, systemImage: diskType.systemImage)
                            .tag(diskType)
                    }
                }

                TextField("Name", text: $name, prompt: Text("My Server"))

                // Type-specific fields
                switch selectedDiskType {
                case .localdirectory:
                    localDirectoryFields
                case .sftp, .ftp, .webdav, .samba:
                    networkFields
                case .dropbox:
                    networkFields
                }

                if let error = errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }
            .formStyle(.grouped)

            Divider()

            // Buttons
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(action: createMount) {
                    if isCreating {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: 16, height: 16)
                    } else {
                        Text("Add Mount")
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!isFormValid || isCreating)
            }
            .padding()
        }
    }

    // MARK: - Field groups

    @ViewBuilder
    private var localDirectoryFields: some View {
        TextField("Path", text: $localPath, prompt: Text("/Users/me/shared"))
    }

    @ViewBuilder
    private var networkFields: some View {
        TextField("Host", text: $host, prompt: Text(hostPlaceholder))

        TextField("Port", text: $port, prompt: Text(defaultPortString))

        if selectedDiskType == .samba {
            TextField("Share Name", text: $shareName, prompt: Text("shared"))
        }

        TextField("Remote Path", text: $remotePath, prompt: Text("/"))

        Section("Authentication") {
            TextField("Username", text: $username, prompt: Text("user"))
            SecureField("Password", text: $password, prompt: Text("password"))
        }
    }

    // MARK: - Helpers

    private var availableDiskTypes: [DiskTypeEnum] {
        // Show types that the backend reports, falling back to known types
        if diskTypeRepository.diskTypes.isEmpty {
            return [.localdirectory, .sftp, .ftp, .webdav, .samba, .dropbox]
        }
        return diskTypeRepository.diskTypes.compactMap { DiskTypeEnum(rawValue: $0.name) }
    }

    private var hostPlaceholder: String {
        switch selectedDiskType {
        case .sftp: return "ssh.example.com"
        case .ftp: return "ftp.example.com"
        case .webdav: return "dav.example.com"
        case .samba: return "nas.local"
        case .dropbox: return "dropbox.com"
        default: return "host.example.com"
        }
    }

    private var defaultPortString: String {
        switch selectedDiskType {
        case .sftp: return "22"
        case .ftp: return "21"
        case .webdav: return "443"
        case .samba: return "445"
        default: return ""
        }
    }

    private var isFormValid: Bool {
        guard !name.isEmpty else { return false }

        switch selectedDiskType {
        case .localdirectory:
            return !localPath.isEmpty
        default:
            return !host.isEmpty
        }
    }

    // MARK: - Create

    private func createMount() {
        isCreating = true
        errorMessage = nil

        // Build path and config from form fields
        var path = ""
        var config: [String: String] = [:]

        switch selectedDiskType {
        case .localdirectory:
            path = localPath
        default:
            let effectivePort = port.isEmpty ? defaultPortString : port
            path = "\(host):\(effectivePort)"
            if !username.isEmpty { config["username"] = username }
            if !password.isEmpty { config["password"] = password }
            if !remotePath.isEmpty { config["remotePath"] = remotePath }
            if !shareName.isEmpty { config["shareName"] = shareName }
        }

        let mount = Mount(
            id: UUID(),
            diskType: selectedDiskType,
            name: name,
            path: path,
            remotePath: remotePath,
            isMounted: false,
            lastAccessed: nil,
            metadata: config
        )

        Task {
            do {
                try await mountRepository.addMount(mount)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isCreating = false
        }
    }
}

// Safe array index extension
extension Collection {
    subscript(safe index: Index) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}
