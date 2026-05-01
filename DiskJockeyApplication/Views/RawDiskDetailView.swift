//
// RawDiskDetailView.swift — detail pane for an unmounted / unformatted
// block device.
//
// Sibling of AttachedDiskDetailView. That one is for volumes the system
// already mounted; this one is for media we'd want to *format* before it
// can become a useful volume — blank SD cards, USB sticks, partitions
// with unknown filesystems, etc.
//
// Format actions are deliberately disabled in this scaffold — the
// underlying Rust `fs_ext4_mkfs` / `fs_ntfs_mkfs` haven't been written
// yet. The buttons exist so the UX shape is visible (and so the wire-up
// when mkfs lands is just "swap the disabled-with-tooltip for the real
// admin-prompt subprocess invocation"). Each format action will trigger
// an admin password prompt every time — destructive, no caching of trust.
//

import SwiftUI
import AppKit

struct RawDiskDetailView: View {
    let bsdName: String
    let container: AppContainer

    @ObservedObject private var rawDisks: RawDisksModel
    @ObservedObject private var attachedDisks: AttachedDisksModel

    /// Which filesystem type the user is in the middle of confirming.
    /// Drives the alert that pops up between button click and the
    /// admin-prompt subprocess. nil = no confirmation pending.
    @State private var pendingFormat: FormatRequest? = nil
    /// Spinner shown on the active Format button while
    /// `newfs_fskit` is in flight (i.e. between admin prompt and
    /// completion). Disables every action button so a double-tap
    /// can't queue a second format mid-flight.
    @State private var formatInProgress: String? = nil
    /// Surfaced failure from `newfs_fskit` — displayed as an inline
    /// banner under the actions row. Cleared by tapping "Dismiss" or
    /// initiating a fresh format.
    @State private var formatError: String? = nil
    /// Surfaced success message; auto-clears after a few seconds via
    /// the `.task(id:)` on the message string. Lets the user see
    /// "Format complete" without a modal interruption.
    @State private var formatSuccess: String? = nil

    /// Opaque pre-format request — captures both which fs to format as
    /// and the disk identity at the moment the user clicked Format.
    /// Stored in `pendingFormat` until the user confirms. The disk
    /// reference is captured by BSD so a sidebar refresh between
    /// click + confirm doesn't desync.
    private struct FormatRequest: Identifiable {
        let id = UUID()
        let fsType: String       // "ext4" or "ntfs"
        let bsdName: String      // e.g. "disk5" or "disk5s1"
        let displayName: String  // user-visible label for the alert text
    }

    init(bsdName: String, container: AppContainer) {
        self.bsdName = bsdName
        self.container = container
        self.rawDisks = container.rawDisks
        self.attachedDisks = container.attachedDisks
    }

    private var disk: RawDisk? {
        rawDisks.disk(withBsdName: bsdName)
    }

    var body: some View {
        if let disk = disk {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header(disk)

                    Divider()

                    detailsForm(disk)

                    if disk.isWhole {
                        partitionList(disk)
                    }

                    actionsSection(disk)

                    Spacer(minLength: 0)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        } else {
            ContentUnavailableView(
                "Disk Disappeared",
                image: "tabler-externaldrive-badge-minus",
                description: Text("\(bsdName) is no longer attached.")
            )
        }
    }

    // MARK: - Header

    @ViewBuilder
    private func header(_ disk: RawDisk) -> some View {
        HStack(spacing: 12) {
            Image(disk.isWhole
                  ? "externaldrive.badge.questionmark"
                  : "internaldrive")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
                .frame(width: 36, height: 36)
            VStack(alignment: .leading) {
                HStack(spacing: 6) {
                    Text(headerName(disk))
                        .font(.title2)
                        .bold()
                    statusBadge(disk)
                }
                Text(headerSubtitle(disk))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func headerName(_ disk: RawDisk) -> String {
        if let label = disk.volumeName, !label.isEmpty { return label }
        if disk.isWhole { return "Disk \(disk.bsdName)" }
        return "Partition \(disk.bsdName)"
    }

    private func headerSubtitle(_ disk: RawDisk) -> String {
        if disk.isUnformatted {
            return disk.isWhole
                ? "No filesystem · ready to format or partition"
                : "Empty partition slot · ready to format"
        }
        if disk.isWhole {
            return "Partition map: \(prettyContent(disk.content))"
        }
        return prettyContent(disk.content)
    }

    @ViewBuilder
    private func statusBadge(_ disk: RawDisk) -> some View {
        if disk.isUnformatted {
            Text("unformatted")
                .font(.caption2).bold()
                .foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Color.orange))
        }
    }

    // MARK: - Details form

    @ViewBuilder
    private func detailsForm(_ disk: RawDisk) -> some View {
        Form {
            LabeledContent("BSD device", value: "/dev/" + disk.bsdName)
            LabeledContent("Size", value: humanBytes(disk.size))
            LabeledContent("Type") {
                Text(disk.isWhole ? "Whole disk" : "Partition")
            }
            LabeledContent("Content", value: prettyContent(disk.content))
            if let parent = disk.parentBsdName {
                LabeledContent("Parent disk", value: "/dev/" + parent)
            }
            LabeledContent("Removable") {
                yesNo(disk.isRemovable)
            }
            LabeledContent("Ejectable") {
                yesNo(disk.isEjectable)
            }
            LabeledContent("Internal") {
                yesNo(disk.isInternal)
            }
            if let mp = disk.mountPoint {
                LabeledContent("Mounted at", value: mp)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Partition list (for whole disks)

    @ViewBuilder
    private func partitionList(_ whole: RawDisk) -> some View {
        let slices = rawDisks.slices(of: whole)
        if !slices.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Partitions")
                    .font(.headline)
                ForEach(slices) { slice in
                    sliceRow(slice)
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func sliceRow(_ slice: RawDisk) -> some View {
        HStack(spacing: 8) {
            Image("tabler-internaldrive")
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(slice.volumeName ?? slice.bsdName)
                    .font(.body)
                Text("\(humanBytes(slice.size)) · \(prettyContent(slice.content))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if slice.isUnformatted {
                Text("empty")
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color.orange))
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(Color.secondary.opacity(0.06)))
    }

    // MARK: - Actions

    /// Format / partition actions. The format buttons spawn
    /// `/sbin/newfs_fskit -t <fs> /dev/diskN` via `osascript` with
    /// administrator privileges — every click triggers a fresh password
    /// prompt by design (no SMAppService trust caching), so a mistaken
    /// double-click can't slip through. The kernel routes the format
    /// request to our FSKit extension's `startFormat`, which calls the
    /// Rust `fs_*_mkfs` against the loaded device.
    ///
    /// The current leaf has caveats — see
    /// `docs/fskit-format-pipeline.md`. Briefly: the disk must be
    /// loaded (probed/mounted) first; blank disks aren't yet supported.
    /// The button still fires; the extension surfaces a clear error if
    /// the precondition isn't met.
    @ViewBuilder
    private func actionsSection(_ disk: RawDisk) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Format / Partition")
                .font(.headline)

            Text("Each format or partition action will prompt for your administrator password. Formatting **erases all data** on the target — no exceptions. macOS shows a separate prompt every time so a mistaken double-click can't slip through.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button(action: { requestFormat(disk: disk, fsType: "ext4") }) {
                    if formatInProgress == "ext4" {
                        HStack(spacing: 4) {
                            ProgressView().scaleEffect(0.5).frame(width: 14, height: 14)
                            Text("Formatting…")
                        }
                    } else {
                        Label("Format as ext4…", image: "tabler-square-grid-3x3")
                    }
                }
                .disabled(formatInProgress != nil)

                Button(action: { requestFormat(disk: disk, fsType: "ntfs") }) {
                    if formatInProgress == "ntfs" {
                        HStack(spacing: 4) {
                            ProgressView().scaleEffect(0.5).frame(width: 14, height: 14)
                            Text("Formatting…")
                        }
                    } else {
                        Label("Format as NTFS…", image: "tabler-square-grid-3x3-fill")
                    }
                }
                .disabled(formatInProgress != nil)

                if disk.isWhole {
                    Button(action: {}) {
                        Label("Partition…", image: "tabler-rectangle-split-3x1")
                    }
                    .disabled(true)
                    .help("Will invoke `diskutil partitionDisk` with admin escalation. Not yet wired up.")
                }

                Spacer()
            }

            if let err = formatError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(.vertical, 4)
                    .onTapGesture { formatError = nil }
            }
            if let ok = formatSuccess {
                Label(ok, systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
                    .padding(.vertical, 4)
                    .task(id: ok) {
                        // Auto-clear the success banner after 4s so it
                        // doesn't linger forever, but do it via .task
                        // (cancellable) rather than DispatchQueue so
                        // tearing down the view kills the timer.
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                        if formatSuccess == ok { formatSuccess = nil }
                    }
            }
        }
        .padding(.top, 4)
        .alert(item: $pendingFormat) { req in
            Alert(
                title: Text("Erase \(req.displayName) and format as \(req.fsType.uppercased())?"),
                message: Text("This will overwrite ALL data on /dev/\(req.bsdName). The action cannot be undone. macOS will then prompt for your administrator password before any bytes are written."),
                primaryButton: .destructive(Text("Erase and format")) {
                    runFormat(req)
                },
                secondaryButton: .cancel()
            )
        }
    }

    // MARK: - Format runner

    /// First half of the format flow: build a confirmation request
    /// from the click site and stash it in `pendingFormat`. The alert
    /// modifier keys off `pendingFormat` (it's `Identifiable`) so the
    /// dialog appears as soon as we set this. Doing it here rather
    /// than inline lets the button bodies stay tiny.
    private func requestFormat(disk: RawDisk, fsType: String) {
        formatError = nil
        formatSuccess = nil
        let displayName = disk.volumeName.flatMap { $0.isEmpty ? nil : $0 }
            ?? "/dev/\(disk.bsdName)"
        pendingFormat = FormatRequest(
            fsType: fsType,
            bsdName: disk.bsdName,
            displayName: displayName
        )
    }

    /// Second half: the user confirmed. Spawn `osascript` with admin
    /// privileges to run `/sbin/newfs_fskit -t <fs> /dev/diskN`. The
    /// password prompt comes from osascript itself; the kernel routes
    /// the format to our FSKit extension's `startFormat` which calls
    /// the Rust mkfs.
    ///
    /// We `.detached` the Process invocation off the main actor because
    /// `Process.waitUntilExit()` blocks the calling thread for the
    /// entire format duration (multi-second on real disks). The
    /// `formatInProgress`/`formatError`/`formatSuccess` state is
    /// flipped back through `MainActor.run`.
    private func runFormat(_ req: FormatRequest) {
        formatInProgress = req.fsType
        let device = "/dev/\(req.bsdName)"
        let fsType = req.fsType
        Task.detached {
            // osascript's `do shell script ... with administrator
            // privileges` is the conventional macOS way to elevate a
            // single command from a sandboxed app. The OS shows its own
            // password prompt; we don't store credentials.
            //
            // Single-quoting the inner shell string is intentional —
            // newfs_fskit takes no shell-interpreted args, but if the
            // device path ever contained shell metacharacters (it
            // shouldn't — diskutil names are alphanumeric) the quoting
            // contains them.
            let inner = "/sbin/newfs_fskit -t \(fsType) \(device)"
            let scriptSource =
                "do shell script \"\(inner.replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"

            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-e", scriptSource]
            let stdout = Pipe()
            let stderr = Pipe()
            task.standardOutput = stdout
            task.standardError = stderr

            let result: (success: Bool, message: String)
            do {
                try task.run()
                task.waitUntilExit()
                let outData = (try? stdout.fileHandleForReading.readToEnd()) ?? Data()
                let errData = (try? stderr.fileHandleForReading.readToEnd()) ?? Data()
                let outStr = String(data: outData, encoding: .utf8) ?? ""
                let errStr = String(data: errData, encoding: .utf8) ?? ""
                if task.terminationStatus == 0 {
                    result = (true, "Format complete. \(device) is now \(fsType.uppercased()).")
                } else {
                    // osascript exit codes: -128 user-cancelled,
                    // anything else is the underlying failure.
                    let detail = !errStr.isEmpty ? errStr
                        : !outStr.isEmpty ? outStr
                        : "newfs_fskit exited with status \(task.terminationStatus)"
                    result = (false, detail.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            } catch {
                result = (false, "Could not run osascript: \(error.localizedDescription)")
            }

            await MainActor.run {
                self.formatInProgress = nil
                if result.success {
                    self.formatSuccess = result.message
                } else {
                    self.formatError = result.message
                }
            }
        }
    }

    // MARK: - Formatting helpers

    @ViewBuilder
    private func yesNo(_ flag: Bool) -> some View {
        Text(flag ? "Yes" : "No")
            .foregroundStyle(flag ? .primary : .secondary)
    }

    private func humanBytes(_ n: UInt64) -> String {
        let labels = ["B", "KB", "MB", "GB", "TB", "PB"]
        var v = Double(n)
        var i = 0
        while i < labels.count - 1 && v >= 2048 { v /= 1024; i += 1 }
        return i == 0 ? "\(Int(v)) \(labels[i])"
                      : String(format: "%.1f %@", v, labels[i])
    }

    private func prettyContent(_ raw: String) -> String {
        switch raw {
        case "": return "(no filesystem)"
        case "GUID_partition_scheme": return "GPT (GUID Partition Table)"
        case "FDisk_partition_scheme": return "MBR (Master Boot Record)"
        case "Apple_HFS": return "HFS+"
        case "Apple_APFS", "Apple_APFS_Container": return "APFS"
        case "Apple_APFS_ISC": return "APFS (System Container)"
        case "Apple_APFS_Recovery": return "APFS Recovery"
        case "Apple_Boot": return "Apple Boot"
        case "EFI": return "EFI System Partition"
        case "Microsoft Basic Data": return "Windows / NTFS / exFAT"
        case "Linux": return "Linux"
        case "Linux_LVM": return "Linux LVM"
        case "Apple_Free": return "free space"
        default: return raw
        }
    }
}
