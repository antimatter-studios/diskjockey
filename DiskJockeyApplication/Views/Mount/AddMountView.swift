//
// AddMountView.swift — single entry point for creating a direct mount
// for any of the eight supported network protocols. Every submission
// hands off to `DirectMountRegistry`; no backend involvement.
//
// Dropbox, Google Drive, and OneDrive use the in-app browser OAuth
// flow — the AddMount form shows a "Sign in" button that hands off to
// `OAuthCoordinator`.
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

    // OneDrive — populated by `OAuthCoordinator.authorizeOneDrive()`.
    // `clientID` is snapshotted from `OAuthClientConfig.onedrive` so
    // re-keying the app later doesn't strand existing mounts.
    // `clientSecret` stays empty (PKCE public client). Refresh token
    // goes to the keychain.
    @State private var onedriveClientID: String = ""
    @State private var onedriveRefreshToken: String = ""
    @State private var onedriveIsSigningIn: Bool = false
    @State private var onedriveSignInError: String?

    // Dropbox — populated by `OAuthCoordinator.authorizeDropbox()`
    // when the user clicks "Sign in to Dropbox". `appKey` is sourced
    // from the bundled OAuthClients.json; we copy it onto the mount
    // at create-time so re-keying the app down the road doesn't
    // strand existing mounts. `refreshToken` is the actually-secret
    // bit; it goes to the keychain via `MountKeychain`.
    @State private var dropboxAppKey: String = ""
    @State private var dropboxRefreshToken: String = ""
    @State private var dropboxIsSigningIn: Bool = false
    @State private var dropboxSignInError: String?
    // Protocol-agnostic mount policy — the same toggles apply to
    // every connector since `MountPolicyStore` keys them by domainID,
    // not by protocol. See `MountPolicy` in DiskJockeyLibrary.
    @State private var policyFetchThumbnails: Bool = true
    @State private var policyBackgroundFetch: Bool = true

    // Google Drive — populated by `OAuthCoordinator.authorizeGDrive()`.
    // `clientID` and `clientSecret` are snapshotted from
    // `OAuthClientConfig.gdrive` so re-keying the app later doesn't
    // strand existing mounts. Refresh token goes to the keychain.
    @State private var gdriveClientID: String = ""
    @State private var gdriveClientSecret: String = ""
    @State private var gdriveRefreshToken: String = ""
    @State private var gdriveIsSigningIn: Bool = false
    @State private var gdriveSignInError: String?

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

                commonPolicyFields

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
    private var commonPolicyFields: some View {
        Section("Background fetching") {
            Toggle("Fetch thumbnails", isOn: $policyFetchThumbnails)
            Toggle("Background metadata fetching", isOn: $policyBackgroundFetch)
                .disabled(!policyFetchThumbnails)
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
            if dropboxRefreshToken.isEmpty {
                Button {
                    Task { await runDropboxSignIn() }
                } label: {
                    if dropboxIsSigningIn {
                        HStack(spacing: 8) {
                            ProgressView().scaleEffect(0.6)
                            Text("Waiting for browser…")
                        }
                    } else {
                        Text("Sign in to Dropbox…")
                    }
                }
                .disabled(dropboxIsSigningIn)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Signed in to Dropbox")
                    Spacer()
                    Button("Sign in again") {
                        dropboxRefreshToken = ""
                        dropboxAppKey = ""
                        dropboxSignInError = nil
                    }
                    .buttonStyle(.borderless)
                }
            }
            if let err = dropboxSignInError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } footer: {
            Text("DiskJockey opens your browser to dropbox.com, then captures the redirect on a local loopback port. The refresh token returned is stored in the macOS keychain.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Drive the OAuth flow on the main actor. `OAuthCoordinator`
    /// owns the loopback listener + browser open + token exchange;
    /// here we just translate its result into local @State.
    @MainActor
    private func runDropboxSignIn() async {
        dropboxIsSigningIn = true
        dropboxSignInError = nil
        defer { dropboxIsSigningIn = false }
        do {
            let tokens = try await OAuthCoordinator.shared.authorizeDropbox()
            // Snapshot the App Key from the bundled config so the
            // mount we create carries the same key the OAuth flow
            // used — important if the JSON is later edited.
            dropboxAppKey = OAuthClientConfig.dropbox?.appKey ?? ""
            dropboxRefreshToken = tokens.refreshToken
        } catch {
            dropboxSignInError = error.localizedDescription
            AppLog.shared.error("Dropbox sign-in failed: \(error)")
        }
    }

    @ViewBuilder
    private var gdriveFields: some View {
        Section {
            if gdriveRefreshToken.isEmpty {
                Button {
                    Task { await runGDriveSignIn() }
                } label: {
                    if gdriveIsSigningIn {
                        HStack(spacing: 8) {
                            ProgressView().scaleEffect(0.6)
                            Text("Waiting for browser…")
                        }
                    } else {
                        Text("Sign in to Google Drive…")
                    }
                }
                .disabled(gdriveIsSigningIn)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Signed in to Google Drive")
                    Spacer()
                    Button("Sign in again") {
                        gdriveRefreshToken = ""
                        gdriveClientID = ""
                        gdriveClientSecret = ""
                        gdriveSignInError = nil
                    }
                    .buttonStyle(.borderless)
                }
            }
            if let err = gdriveSignInError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } footer: {
            Text("DiskJockey opens your browser to accounts.google.com, then captures the redirect on a local loopback port. The refresh token returned is stored in the macOS keychain. Until the app's Google verification completes, only test users listed in the Google Cloud Console can sign in (see docs/google-drive-registration.md §7).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Drive the Google OAuth flow on the main actor. Mirrors
    /// `runDropboxSignIn` — `OAuthCoordinator` owns the loopback +
    /// browser open + token exchange; we just translate its result
    /// into local @State.
    @MainActor
    private func runGDriveSignIn() async {
        gdriveIsSigningIn = true
        gdriveSignInError = nil
        defer { gdriveIsSigningIn = false }
        do {
            let tokens = try await OAuthCoordinator.shared.authorizeGDrive()
            // Snapshot the developer credentials from the bundled
            // config so the mount we create carries the same values
            // the OAuth flow used — important if the JSON is later
            // edited.
            gdriveClientID = OAuthClientConfig.gdrive?.clientID ?? ""
            gdriveClientSecret = OAuthClientConfig.gdrive?.clientSecret ?? ""
            gdriveRefreshToken = tokens.refreshToken
        } catch {
            gdriveSignInError = error.localizedDescription
            AppLog.shared.error("Google Drive sign-in failed: \(error)")
        }
    }

    @ViewBuilder
    private var onedriveFields: some View {
        Section {
            if onedriveRefreshToken.isEmpty {
                Button {
                    Task { await runOneDriveSignIn() }
                } label: {
                    if onedriveIsSigningIn {
                        HStack(spacing: 8) {
                            ProgressView().scaleEffect(0.6)
                            Text("Waiting for browser…")
                        }
                    } else {
                        Text("Sign in to OneDrive…")
                    }
                }
                .disabled(onedriveIsSigningIn)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Signed in to OneDrive")
                    Spacer()
                    Button("Sign in again") {
                        onedriveRefreshToken = ""
                        onedriveClientID = ""
                        onedriveSignInError = nil
                    }
                    .buttonStyle(.borderless)
                }
            }
            if let err = onedriveSignInError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } footer: {
            Text("DiskJockey opens your browser to login.microsoftonline.com, then captures the redirect on a local loopback port. The refresh token returned is stored in the macOS keychain. Work/school tenants may show an \"unverified app\" warning until publisher verification completes (see docs/microsoft-onedrive-registration.md §5).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Drive the Microsoft OAuth flow on the main actor. Mirrors
    /// `runDropboxSignIn` / `runGDriveSignIn` — `OAuthCoordinator` owns
    /// the loopback + browser open + token exchange; we just translate
    /// its result into local @State.
    @MainActor
    private func runOneDriveSignIn() async {
        onedriveIsSigningIn = true
        onedriveSignInError = nil
        defer { onedriveIsSigningIn = false }
        do {
            let tokens = try await OAuthCoordinator.shared.authorizeOneDrive()
            // Snapshot the developer client_id from the bundled
            // config so the mount we create carries the same value
            // the OAuth flow used — important if the JSON is later
            // edited.
            onedriveClientID = OAuthClientConfig.onedrive?.clientID ?? ""
            onedriveRefreshToken = tokens.refreshToken
        } catch {
            onedriveSignInError = error.localizedDescription
            AppLog.shared.error("OneDrive sign-in failed: \(error)")
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
        // Name is optional — `DirectMountRegistry.createMount`
        // auto-generates "<Protocol> Mount" when blank. Requiring it
        // here surprised users who'd successfully signed in but
        // couldn't see why "Add Mount" was disabled.
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
            return !dropboxRefreshToken.isEmpty && !dropboxAppKey.isEmpty
        case .gdrive:
            return !gdriveRefreshToken.isEmpty
                && !gdriveClientID.isEmpty
                && !gdriveClientSecret.isEmpty
        case .onedrive:
            return !onedriveRefreshToken.isEmpty && !onedriveClientID.isEmpty
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
                let policySnapshot = MountPolicy(
                    fetchThumbnails: policyFetchThumbnails,
                    backgroundFetch: policyBackgroundFetch
                )
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
                        ftps: ftps,
                        policy: policySnapshot
                    )
                case .sftp:
                    mount = try await directMountRegistry.createSFTPMount(
                        name: nameSnapshot,
                        host: host,
                        port: Int(port) ?? 22,
                        user: user,
                        password: password,
                        rootPath: trimmedRoot,
                        useSSHAgent: sftpUseAgent,
                        policy: policySnapshot
                    )
                case .smb:
                    mount = try await directMountRegistry.createSMBMount(
                        name: nameSnapshot,
                        host: host,
                        port: Int(port) ?? 445,
                        share: smbShare,
                        user: user,
                        password: password,
                        rootPath: trimmedRoot,
                        policy: policySnapshot
                    )
                case .webdav:
                    mount = try await directMountRegistry.createWebDAVMount(
                        name: nameSnapshot,
                        url: webdavURL,
                        user: user,
                        password: password,
                        pathPrefix: webdavPathPrefix.isEmpty ? "/" : webdavPathPrefix,
                        policy: policySnapshot
                    )
                case .dropbox:
                    mount = try await directMountRegistry.createDropboxMount(
                        name: nameSnapshot,
                        appKey: dropboxAppKey,
                        refreshToken: dropboxRefreshToken,
                        policy: policySnapshot
                    )
                case .gdrive:
                    mount = try await directMountRegistry.createGDriveMount(
                        name: nameSnapshot,
                        clientID: gdriveClientID,
                        clientSecret: gdriveClientSecret,
                        refreshToken: gdriveRefreshToken,
                        policy: policySnapshot
                    )
                case .onedrive:
                    mount = try await directMountRegistry.createOneDriveMount(
                        name: nameSnapshot,
                        clientID: onedriveClientID,
                        refreshToken: onedriveRefreshToken,
                        policy: policySnapshot
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
                        usePathStyle: s3PathStyle,
                        policy: policySnapshot
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
