import Foundation

final class AgentImpl: NSObject, DJAgentProtocol {
    /// What this agent attached, shared by every connection and kept on
    /// disk across launchd's restarts. See AgentAuthority.swift.
    private let ledger: AttachLedgerFile

    init(ledger: AttachLedgerFile) {
        self.ledger = ledger
    }

    /// Attach only an image the caller has shown it can read: `proof` is
    /// that image, opened by the caller inside its own sandbox and sent
    /// over XPC (diskjockey#94). What the attach produced is recorded, so
    /// a later detach can be checked against it.
    func attachImage(atPath incoming: String, proof: FileHandle,
                     reply: @escaping ([String]?, String?) -> Void) {
        let path: String
        let checked = AgentAuthority.attachableImage(incoming, proof: proof.fileDescriptor)
        try? proof.close()
        switch checked {
        case .success(let resolved): path = resolved
        case .failure(let why):
            reply(nil, why)
            return
        }
        switch Self.hdiutilAttach(path: path) {
        case .success(let slices):
            ledger.update { $0.recordAttach(imagePath: path, devices: slices) }
            reply(slices, nil)
            return
        case .failure(let err):
            // Image may already be attached from a previous failed mount attempt.
            // Detach it first to ensure a clean state, then re-attach fresh.
            // Reusing the stale block device (without detach) risks DA having
            // blacklisted it from the prior failed mount attempt.
            guard let staleDevs = Self.alreadyAttachedDevices(forImagePath: path),
                  let parent = staleDevs.first(where: {
                      $0.range(of: #"^/dev/disk\d+$"#, options: .regularExpression) != nil
                  }) else {
                reply(nil, err)
                return
            }
            Self.hdiutilDetach(parent)
        }

        // Re-attach after detaching the stale image.
        switch Self.hdiutilAttach(path: path) {
        case .success(let slices):
            ledger.update { $0.recordAttach(imagePath: path, devices: slices) }
            reply(slices, nil)
        case .failure(let err):
            reply(nil, "hdiutil attach (retry) \(err)")
        }
    }

    // Runs `hdiutil attach -nomount -plist <path>` and returns the dev-entry
    // slice list on success, or an error string on failure.
    private static func hdiutilAttach(path: String) -> Result<[String], String> {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        proc.arguments = ["attach", "-nomount", "-plist", path]
        // Waiting before reading deadlocks once the child fills the
        // ~64 KiB a pipe holds, and stderr was a `Pipe()` nothing read,
        // which blocks the child just as surely. Both are drained
        // concurrently, and the wait comes after.
        let result: ProcessRunner.Output
        do { result = try ProcessRunner.run(proc) } catch { return .failure(error.localizedDescription) }
        guard result.status == 0 else {
            return .failure("hdiutil attach exited with status \(result.status)")
        }
        guard let devices = HdiutilPlist.devices(fromAttach: result.stdout) else {
            return .failure("failed to parse hdiutil plist output")
        }
        return .success(devices)
    }

    /// Query `hdiutil info -plist` and return the dev-entry list for the
    /// given image path if it is already attached, or nil if not found.
    private static func alreadyAttachedDevices(forImagePath path: String) -> [String]? {
        guard let images = attachedImages(),
              let image = images.first(where: { $0.isImage(at: path) }),
              !image.devices.isEmpty else { return nil }
        return image.devices
    }

    /// Fire-and-forget hdiutil detach. Used to clear stale orphan attachments
    /// before a fresh attach — we don't care about the exit status here since
    /// the attach will fail and surface an error if detach didn't work.
    private static func hdiutilDetach(_ bsdName: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        proc.arguments = ["detach", "-force", bsdName]
        // The output is not wanted, which is not the same as attaching
        // pipes and ignoring them: an unread pipe fills and blocks the
        // child. /dev/null has no buffer to fill.
        _ = try? ProcessRunner.runDiscardingOutput(proc)
    }

    /// Every image `hdiutil info` reports attached right now, or nil if it
    /// could not be asked.
    private static func attachedImages() -> [AttachedImage]? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        proc.arguments = ["info", "-plist"]
        // `hdiutil info -plist` lists EVERY attached image on the
        // machine. That passes the ~64 KiB a pipe holds on any
        // developer's laptop, and waiting for the child before reading
        // it is the deadlock: the child cannot exit until its output is
        // read, and this side would not read until it exited.
        guard let result = try? ProcessRunner.run(proc), result.status == 0 else { return nil }
        return HdiutilPlist.images(fromInfo: result.stdout)
    }

    /// Detach only a device this agent attached, and only while hdiutil
    /// still shows it attached from the image the ledger names — a BSD
    /// number is reused once its image is ejected (diskjockey#94).
    func detachDevice(_ bsdName: String,
                      reply: @escaping (Bool, String?) -> Void) {
        guard AgentAuthority.isBSDDiskName(bsdName) else {
            reply(false, "refusing to detach \(bsdName): not a BSD disk name")
            return
        }
        guard let current = Self.attachedImages() else {
            reply(false, "refusing to detach \(bsdName): hdiutil info could not be read, so nothing shows this agent attached it")
            return
        }
        let authorized = ledger.update { ledger -> Result<Void, String> in
            ledger.prune(attached: current)
            return ledger.authorizeDetach(bsdName, attached: current)
        }
        if case .failure(let why) = authorized {
            reply(false, why)
            return
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        proc.arguments = ["detach", bsdName]
        // Only the exit status is wanted. Sending both streams to
        // /dev/null is what makes that safe — an unread `Pipe()` fills
        // and blocks the child before it can exit.
        let status: Int32
        do {
            status = try ProcessRunner.runDiscardingOutput(proc)
        } catch {
            reply(false, error.localizedDescription)
            return
        }
        if status == 0 {
            ledger.update { $0.forget(device: bsdName) }
            reply(true, nil)
        } else {
            reply(false, "hdiutil detach exited with status \(status)")
        }
    }

    func probeImage(atPath path: String,
                    reply: @escaping (String?, String?) -> Void) {
        guard let probeURL = Self.locateBlkProbe() else {
            reply(nil, "blk.probe binary not found in bundle Resources or project lib/")
            return
        }
        let proc = Process()
        proc.executableURL = probeURL
        proc.arguments = [path]
        // blk.probe emits a JSON description of a whole disk, which is
        // past the ~64 KiB a pipe holds for anything with many
        // partitions. Waiting before reading is the deadlock.
        let result: ProcessRunner.Output
        do {
            result = try ProcessRunner.run(proc)
        } catch {
            reply(nil, error.localizedDescription)
            return
        }
        guard result.status == 0 else {
            reply(nil, "blk.probe exited \(result.status): \(result.stderrText)")
            return
        }
        reply(result.stdoutText, nil)
    }

    private static func locateBlkProbe() -> URL? {
        // 1. Bundle Resources — production path once blk.probe is added as a resource.
        let agentURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let bundleCandidate = agentURL
            .deletingLastPathComponent() // DiskJockeyAgent → LaunchAgents/
            .deletingLastPathComponent() // LaunchAgents/   → Library/
            .deletingLastPathComponent() // Library/        → Contents/
            .appendingPathComponent("Resources/blk.probe")
        if FileManager.default.isExecutableFile(atPath: bundleCandidate.path) {
            return bundleCandidate
        }
#if DEBUG
        // Dev fallback: walk up from this source file to find lib/blk.probe/blk.probe.
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent("lib/blk.probe/blk.probe")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
            dir = dir.deletingLastPathComponent()
            if dir.path == "/" { break }
        }
#endif
        return nil
    }
}
