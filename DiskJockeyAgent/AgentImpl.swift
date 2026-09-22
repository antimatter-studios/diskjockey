import Foundation

// `hdiutilAttach` returns `Result<[String], String>`, using a plain string
// as the lightweight internal failure value. Allow String as an Error.
// `@retroactive` acknowledges this conformance is on a type we don't own
// (SE-0364) and silences the Swift 6 retroactive-conformance warning.
extension String: @retroactive Error {}

final class AgentImpl: NSObject, DJAgentProtocol {
    /// Whether a path is one this agent will attach.
    ///
    /// `attachImage` attached ANY caller-supplied path — no
    /// canonicalisation, no symlink check, no existence check. That is a
    /// sandbox-escape primitive dressed as a convenience: a sandboxed
    /// caller cannot open a file outside its container, but it could ask
    /// this unsandboxed agent to attach one.
    ///
    /// The connection is now mutually authenticated, so the caller is at
    /// least our own app — but an app is a large thing to trust
    /// wholesale, and a bug in it should not become a whole-disk read.
    /// So: resolve symlinks first, then require a regular file that
    /// exists. Resolving BEFORE checking is the order that matters; a
    /// symlink checked and then followed is the classic race.
    static func attachableImage(_ path: String) -> Result<String, String> {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved,
                                             isDirectory: &isDirectory) else {
            return .failure("no such file: \(path)")
        }
        guard !isDirectory.boolValue else {
            return .failure("not a disk image: \(path) is a directory")
        }
        return .success(resolved)
    }

    func attachImage(atPath incoming: String,
                     reply: @escaping ([String]?, String?) -> Void) {
        let path: String
        switch Self.attachableImage(incoming) {
        case .success(let resolved): path = resolved
        case .failure(let why):
            reply(nil, why)
            return
        }
        switch Self.hdiutilAttach(path: path) {
        case .success(let slices):
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
        let data = result.stdout
        var fmt = PropertyListSerialization.PropertyListFormat.xml
        guard let plist = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: &fmt) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else {
            return .failure("failed to parse hdiutil plist output")
        }
        return .success(entities.compactMap { $0["dev-entry"] as? String })
    }

    /// Query `hdiutil info -plist` and return the dev-entry list for the
    /// given image path if it is already attached, or nil if not found.
    private static func alreadyAttachedDevices(forImagePath path: String) -> [String]? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        proc.arguments = ["info", "-plist"]
        // `hdiutil info -plist` lists EVERY attached image on the
        // machine. That passes the ~64 KiB a pipe holds on any
        // developer's laptop, and waiting for the child before reading
        // it is the deadlock: the child cannot exit until its output is
        // read, and this side would not read until it exited.
        guard let result = try? ProcessRunner.run(proc), result.status == 0 else { return nil }

        let data = result.stdout
        var fmt = PropertyListSerialization.PropertyListFormat.xml
        guard let plist = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: &fmt) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else { return nil }

        let canonical = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        for image in images {
            let imagePath = (image["image-path"] as? String) ?? ""
            let imageAlias = (image["image-alias"] as? String) ?? ""
            let imageCanonical = URL(fileURLWithPath: imagePath).resolvingSymlinksInPath().path
            let aliasCanonical = URL(fileURLWithPath: imageAlias).resolvingSymlinksInPath().path
            guard imageCanonical == canonical || aliasCanonical == canonical else { continue }
            guard let entities = image["system-entities"] as? [[String: Any]] else { continue }
            let devs = entities.compactMap { $0["dev-entry"] as? String }
            return devs.isEmpty ? nil : devs
        }
        return nil
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

    /// A BSD disk name, and nothing else.
    ///
    /// `detachDevice` hands its argument to `hdiutil detach`. The
    /// INTERNAL caller at the top of this file already checks the shape;
    /// this XPC entry point did not, so a peer could name any device —
    /// including volumes this agent never attached — and have them
    /// forced offline.
    ///
    /// Anchored at both ends deliberately: an unanchored match would
    /// accept `/dev/disk1 ; anything`.
    static func isBSDDiskName(_ name: String) -> Bool {
        name.range(of: #"^/dev/disk\d+(s\d+)?$"#, options: .regularExpression) != nil
    }

    func detachDevice(_ bsdName: String,
                      reply: @escaping (Bool, String?) -> Void) {
        guard Self.isBSDDiskName(bsdName) else {
            reply(false, "refusing to detach \(bsdName): not a BSD disk name")
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
            reply(true, nil)
        } else {
            reply(false, "hdiutil detach exited with status \(status)")
        }
    }

    func mountFSKit(source: String, mountPoint: String, fsType: String,
                    partitionOffset: Int64, partitionLength: Int64,
                    reply: @escaping (Bool, String?) -> Void) {
        var cmd = "/bin/mkdir -p \(Self.shellQuote(mountPoint)) && /sbin/mount -F -t \(Self.shellQuote(fsType)) "
        if partitionOffset > 0 {
            cmd += "-o \(Self.shellQuote("partition_offset=\(partitionOffset),partition_length=\(partitionLength)")) "
        }
        cmd += "\(Self.shellQuote(source)) \(Self.shellQuote(mountPoint))"

        let appleScript = "do shell script \(Self.appleScriptQuote(cmd)) with prompt \"Disk Jockey wants to mount a disk image.\" with administrator privileges"

        DispatchQueue.global(qos: .userInitiated).async {
            guard let script = NSAppleScript(source: appleScript) else {
                reply(false, "NSAppleScript init failed")
                return
            }
            var errorDict: NSDictionary?
            script.executeAndReturnError(&errorDict)
            if let err = errorDict {
                let code = (err[NSAppleScript.errorNumber] as? Int) ?? 0
                let msg = (err[NSAppleScript.errorMessage] as? String) ?? "error \(code)"
                reply(false, msg)
            } else {
                reply(true, nil)
            }
        }
    }

    func probeImage(atPath path: String,
                    reply: @escaping (String?, String?) -> Void) {
        guard let probeURL = Self.locateBlkProbe() else {
            reply(nil, "blk-probe binary not found in bundle Resources or project lib/")
            return
        }
        let proc = Process()
        proc.executableURL = probeURL
        proc.arguments = [path]
        // blk-probe emits a JSON description of a whole disk, which is
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
            reply(nil, "blk-probe exited \(result.status): \(result.stderrText)")
            return
        }
        reply(result.stdoutText, nil)
    }

    private static func locateBlkProbe() -> URL? {
        // 1. Bundle Resources — production path once blk-probe is added as a resource.
        let agentURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let bundleCandidate = agentURL
            .deletingLastPathComponent() // DiskJockeyAgent → LaunchAgents/
            .deletingLastPathComponent() // LaunchAgents/   → Library/
            .deletingLastPathComponent() // Library/        → Contents/
            .appendingPathComponent("Resources/blk-probe")
        if FileManager.default.isExecutableFile(atPath: bundleCandidate.path) {
            return bundleCandidate
        }
#if DEBUG
        // Dev fallback: walk up from this source file to find lib/blk-probe/blk-probe.
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent("lib/blk-probe/blk-probe")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
            dir = dir.deletingLastPathComponent()
            if dir.path == "/" { break }
        }
#endif
        return nil
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func appleScriptQuote(_ s: String) -> String {
        "\"" + s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
