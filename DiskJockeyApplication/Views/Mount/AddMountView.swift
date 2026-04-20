//
// AddMountView.swift — single entry point for creating a direct mount
// for any of the eight supported network protocols. Every submission
// hands off to `DirectMountRegistry`; no backend involvement.
//
// For OAuth-based providers (Google Drive, OneDrive, Dropbox) the form
// currently asks the user to paste a pre-obtained refresh token. The
// browser-based OAuth dance is planned — see
// `docs/oauth-flow-plan.md` — and will replace those TextFields with a
// "Sign in" button when implemented.
//

import SwiftUI
import DiskJockeyLibrary

struct AddMountView: View {
    @ObservedObject var directMountRegistry: DirectMountRegistry
    @Environment(\.dismiss) private var dismiss

    // Picker
    @State private var scheme: DirectMountScheme = .sftp

    // Common
    @State private var name: String = ""

    // Host-based protocols (ftp, sftp, smb)
    @State private var host: String = ""
    @State private var port: String = ""
    @State private var user: String = ""
    @State private var password: String = ""
    @State private var remotePath: String = "/"

    // FTP-specific
    @State private var ftps: Bool = false

    // SFTP-specific
    @State private var sftpUseAgent: Bool = false

    // SMB-specific
    @State private var smbShare: String = ""

    // WebDAV
    @State private var webdavURL: String = ""
    @State private var webdavPathPrefix: String = "/"

    // OAuth-based (gdrive, onedrive)
    @State private var oauthClientID: String = ""
    @State private var oauthClientSecret: String = ""
    @State private var oauthRefreshToken: String = ""

    // Dropbox (long-lived access token for now)
    @State private var dropboxAccessToken: String = ""

    // S3
    @State private var s3Endpoint: String = ""
    @State private var s3Bucket: String = ""
    @State private var s3Region: String = "us-east-1"
    @State private var s3AccessKeyID: String = ""
    @State private var s3SecretKey: String = ""
    @State private var s3Prefix: String = ""
    @State private var s3Secure: Bool = true
    @State private var s3PathStyle: Bool = false

    @State private var isCreating = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("New Mount")
                    .font(.headline)
                Spacer()
            }
            .padding()

            Divider()

            Form {
                Picker("Type", selection: $scheme) {
                    ForEach(DirectMountScheme.allCases, id: \.self) { s in
                        Text(s.displayName).tag(s)
                    }
                }

                TextField("Name", text: $name, prompt: Text("My Server"))

                schemeFields

                if let error = errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button(action: submit) {
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

    // MARK: - Scheme-specific field groups

    @ViewBuilder
    private var schemeFields: some View {
        switch scheme {
        case .ftp:      ftpFields
        case .sftp:     sftpFields
        case .smb:      smbFields
        case .webdav:   webdavFields
        case .dropbox:  dropboxFields
        case .gdrive:   gdriveFields
        case .onedrive: onedriveFields
        case .s3:       s3Fields
        }
    }

    @ViewBuilder
    private var ftpFields: some View {
        TextField("Host", text: $host, prompt: Text("ftp.example.com"))
        TextField("Port", text: $port, prompt: Text("21"))
        TextField("Remote Path", text: $remotePath, prompt: Text("/"))
        Toggle("Use FTPS (AUTH TLS)", isOn: $ftps)
        Section("Authentication") {
            TextField("Username", text: $user, prompt: Text("user"))
            SecureField("Password", text: $password, prompt: Text("password"))
        }
    }

    @ViewBuilder
    private var sftpFields: some View {
        TextField("Host", text: $host, prompt: Text("ssh.example.com"))
        TextField("Port", text: $port, prompt: Text("22"))
        TextField("Remote Path", text: $remotePath, prompt: Text("/"))
        Toggle("Use SSH Agent", isOn: $sftpUseAgent)
        Section("Authentication") {
            TextField("Username", text: $user, prompt: Text("user"))
            SecureField("Password", text: $password, prompt: Text("password"))
                .disabled(sftpUseAgent)
        }
    }

    @ViewBuilder
    private var smbFields: some View {
        TextField("Host", text: $host, prompt: Text("nas.local"))
        TextField("Port", text: $port, prompt: Text("445"))
        TextField("Share", text: $smbShare, prompt: Text("shared"))
        TextField("Remote Path", text: $remotePath, prompt: Text("/"))
        Section("Authentication") {
            TextField("Username", text: $user, prompt: Text("user"))
            SecureField("Password", text: $password, prompt: Text("password"))
        }
    }

    @ViewBuilder
    private var webdavFields: some View {
        TextField("URL", text: $webdavURL, prompt: Text("https://dav.example.com/"))
        TextField("Path Prefix", text: $webdavPathPrefix, prompt: Text("/"))
        Section("Authentication") {
            TextField("Username", text: $user, prompt: Text("user"))
            SecureField("Password", text: $password, prompt: Text("password"))
        }
    }

    @ViewBuilder
    private var dropboxFields: some View {
        Section {
            SecureField("Access Token", text: $dropboxAccessToken,
                        prompt: Text("sl.B…"))
        } footer: {
            Text("Generate a long-lived token at https://www.dropbox.com/developers/apps. OAuth sign-in is coming — see docs/oauth-flow-plan.md.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var gdriveFields: some View {
        Section {
            TextField("Client ID", text: $oauthClientID,
                      prompt: Text("xxx.apps.googleusercontent.com"))
            TextField("Client Secret", text: $oauthClientSecret,
                      prompt: Text("GOCSPX-…"))
            SecureField("Refresh Token", text: $oauthRefreshToken,
                        prompt: Text("1//0e…"))
        } footer: {
            Text("Obtain credentials per docs/google-drive-registration.md. Browser OAuth flow is planned — see docs/oauth-flow-plan.md.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var onedriveFields: some View {
        Section {
            TextField("Client ID", text: $oauthClientID,
                      prompt: Text("Azure app registration ID"))
            SecureField("Client Secret (optional)", text: $oauthClientSecret,
                        prompt: Text("leave empty for PKCE public client"))
            SecureField("Refresh Token", text: $oauthRefreshToken,
                        prompt: Text("M.R3_BAY.CX…"))
        } footer: {
            Text("Obtain credentials per docs/microsoft-onedrive-registration.md. Browser OAuth flow is planned — see docs/oauth-flow-plan.md.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var s3Fields: some View {
        Section("Bucket") {
            TextField("Endpoint", text: $s3Endpoint,
                      prompt: Text("s3.amazonaws.com"))
            TextField("Bucket", text: $s3Bucket, prompt: Text("my-bucket"))
            TextField("Region", text: $s3Region, prompt: Text("us-east-1"))
            TextField("Prefix", text: $s3Prefix,
                      prompt: Text("optional/sub/path"))
        }
        Section("Credentials") {
            TextField("Access Key ID", text: $s3AccessKeyID,
                      prompt: Text("AKIA…"))
            SecureField("Secret Access Key", text: $s3SecretKey,
                        prompt: Text("secret"))
        }
        Section("Options") {
            Toggle("Use TLS (HTTPS)", isOn: $s3Secure)
            Toggle("Force Path-Style Addressing", isOn: $s3PathStyle)
                .help("Needed for MinIO and most self-hosted S3 endpoints")
        }
    }

    // MARK: - Validation

    private var isFormValid: Bool {
        guard !name.isEmpty else { return false }
        switch scheme {
        case .ftp:
            return !host.isEmpty && !user.isEmpty && !password.isEmpty
        case .sftp:
            return !host.isEmpty && !user.isEmpty
                && (sftpUseAgent || !password.isEmpty)
        case .smb:
            return !host.isEmpty && !smbShare.isEmpty
                && !user.isEmpty && !password.isEmpty
        case .webdav:
            return !webdavURL.isEmpty && !user.isEmpty && !password.isEmpty
        case .dropbox:
            return !dropboxAccessToken.isEmpty
        case .gdrive:
            return !oauthClientID.isEmpty && !oauthClientSecret.isEmpty
                && !oauthRefreshToken.isEmpty
        case .onedrive:
            return !oauthClientID.isEmpty && !oauthRefreshToken.isEmpty
        case .s3:
            return !s3Endpoint.isEmpty && !s3Bucket.isEmpty
                && !s3AccessKeyID.isEmpty && !s3SecretKey.isEmpty
        }
    }

    // MARK: - Submit

    private func submit() {
        isCreating = true
        errorMessage = nil

        let trimmedRoot = remotePath.isEmpty ? "/" : remotePath
        let schemeSnapshot = scheme
        let nameSnapshot = name

        Task {
            do {
                let mount: DirectMount
                switch schemeSnapshot {
                case .ftp:
                    mount = try await directMountRegistry.createFTPMount(
                        name: nameSnapshot,
                        host: host,
                        port: Int(port) ?? 21,
                        user: user,
                        password: password,
                        rootPath: trimmedRoot,
                        ftps: ftps
                    )
                case .sftp:
                    mount = try await directMountRegistry.createSFTPMount(
                        name: nameSnapshot,
                        host: host,
                        port: Int(port) ?? 22,
                        user: user,
                        password: password,
                        rootPath: trimmedRoot,
                        useSSHAgent: sftpUseAgent
                    )
                case .smb:
                    mount = try await directMountRegistry.createSMBMount(
                        name: nameSnapshot,
                        host: host,
                        port: Int(port) ?? 445,
                        share: smbShare,
                        user: user,
                        password: password,
                        rootPath: trimmedRoot
                    )
                case .webdav:
                    mount = try await directMountRegistry.createWebDAVMount(
                        name: nameSnapshot,
                        url: webdavURL,
                        user: user,
                        password: password,
                        pathPrefix: webdavPathPrefix.isEmpty ? "/" : webdavPathPrefix
                    )
                case .dropbox:
                    mount = try await directMountRegistry.createDropboxMount(
                        name: nameSnapshot,
                        accessToken: dropboxAccessToken
                    )
                case .gdrive:
                    mount = try await directMountRegistry.createGDriveMount(
                        name: nameSnapshot,
                        clientID: oauthClientID,
                        clientSecret: oauthClientSecret,
                        refreshToken: oauthRefreshToken
                    )
                case .onedrive:
                    mount = try await directMountRegistry.createOneDriveMount(
                        name: nameSnapshot,
                        clientID: oauthClientID,
                        clientSecret: oauthClientSecret,
                        refreshToken: oauthRefreshToken
                    )
                case .s3:
                    mount = try await directMountRegistry.createS3Mount(
                        name: nameSnapshot,
                        endpoint: s3Endpoint,
                        bucket: s3Bucket,
                        region: s3Region.isEmpty ? "us-east-1" : s3Region,
                        accessKeyID: s3AccessKeyID,
                        secretAccessKey: s3SecretKey,
                        prefix: s3Prefix,
                        secure: s3Secure,
                        usePathStyle: s3PathStyle
                    )
                }
                AppLog.shared.info("add-mount created id=\(mount.domainID) scheme=\(mount.config.scheme.rawValue)")
                dismiss()
            } catch {
                AppLog.shared.error("add-mount FAILED: \("\(error)")")
                errorMessage = error.localizedDescription
            }
            isCreating = false
        }
    }
}
