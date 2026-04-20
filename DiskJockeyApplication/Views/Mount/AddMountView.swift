import SwiftUI
import DiskJockeyLibrary

struct AddMountView: View {
    @ObservedObject var diskTypeRepository: DiskTypeRepository
    @ObservedObject var mountRepository: MountRepository
    @ObservedObject var directMountRegistry: DirectMountRegistry
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
    @State private var ftps: Bool = false

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
                case .ftpDirect:
                    directFTPFields
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

    /// Form for the direct-linked FTP driver. Same fields as
    /// `networkFields` but numeric port input and an FTPS toggle,
    /// and submission routes through `DirectMountRegistry` instead of
    /// the backend.
    @ViewBuilder
    private var directFTPFields: some View {
        TextField("Host", text: $host, prompt: Text("ftp.example.com"))

        TextField("Port", value: portBinding, format: .number.grouping(.never))
            .help("Default 21")

        TextField("Remote Path", text: $remotePath, prompt: Text("/"))

        Toggle("Use FTPS (AUTH TLS)", isOn: $ftps)

        Section("Authentication") {
            TextField("Username", text: $username, prompt: Text("user"))
            SecureField("Password", text: $password, prompt: Text("password"))
        }
    }

    /// Binding that exposes the `port` string as an optional Int for
    /// the numeric `TextField` — empty string becomes nil, which we
    /// render as 21 at submit time.
    private var portBinding: Binding<Int?> {
        Binding(
            get: { Int(port) },
            set: { newValue in
                if let v = newValue { port = String(v) } else { port = "" }
            }
        )
    }

    // MARK: - Helpers

    private var availableDiskTypes: [DiskTypeEnum] {
        // Always expose .ftpDirect — it doesn't need the backend to
        // advertise it. Backend-routed types fall back to a known set
        // when the backend hasn't reported yet.
        var backendTypes: [DiskTypeEnum]
        if diskTypeRepository.diskTypes.isEmpty {
            backendTypes = [.localdirectory, .sftp, .ftp, .webdav, .samba, .dropbox]
        } else {
            backendTypes = diskTypeRepository.diskTypes.compactMap {
                DiskTypeEnum(rawValue: $0.name)
            }
        }
        // Insert .ftpDirect right after any existing .ftp entry so it
        // reads naturally in the picker.
        if !backendTypes.contains(.ftpDirect) {
            if let ftpIdx = backendTypes.firstIndex(of: .ftp) {
                backendTypes.insert(.ftpDirect, at: ftpIdx + 1)
            } else {
                backendTypes.append(.ftpDirect)
            }
        }
        return backendTypes
    }

    private var hostPlaceholder: String {
        switch selectedDiskType {
        case .sftp: return "ssh.example.com"
        case .ftp: return "ftp.example.com"
        case .ftpDirect: return "ftp.example.com"
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
        case .ftpDirect: return "21"
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
        case .ftpDirect:
            // Host + user + password are required for direct FTP;
            // port/path/ftps have sane defaults.
            return !host.isEmpty && !username.isEmpty && !password.isEmpty
        default:
            return !host.isEmpty
        }
    }

    // MARK: - Create

    private func createMount() {
        isCreating = true
        errorMessage = nil

        if selectedDiskType == .ftpDirect {
            createDirectFTPMount()
            return
        }

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

    /// Direct-FTP branch: goes through `DirectMountRegistry`, does NOT
    /// require the backend to be connected.
    private func createDirectFTPMount() {
        let effectivePort = Int(port) ?? 21
        let effectiveRoot = remotePath.isEmpty ? "/" : remotePath
        let mountName = name
        let hostValue = host
        let userValue = username
        let passValue = password
        let ftpsValue = ftps
        AppLog.shared.info("direct-FTP submit name=\(mountName) host=\(hostValue):\(effectivePort) user=\(userValue) root=\(effectiveRoot) ftps=\(ftpsValue ? "yes" : "no")")

        Task {
            do {
                let mount = try await directMountRegistry.createFTPMount(
                    name: mountName,
                    host: hostValue,
                    port: effectivePort,
                    user: userValue,
                    password: passValue,
                    rootPath: effectiveRoot,
                    ftps: ftpsValue
                )
                AppLog.shared.info("direct-FTP created successfully id=\(mount.domainID); dismissing")
                dismiss()
            } catch {
                AppLog.shared.error("direct-FTP FAILED: \("\(error)")")
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
