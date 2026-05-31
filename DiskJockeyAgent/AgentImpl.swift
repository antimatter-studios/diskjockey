import Foundation

final class AgentImpl: NSObject, DJAgentProtocol {
    func attachImage(atPath path: String,
                     reply: @escaping ([String]?, String?) -> Void) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        proc.arguments = ["attach", "-nomount", "-plist", path]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.launch()
            proc.waitUntilExit()
        } catch {
            reply(nil, error.localizedDescription)
            return
        }
        if proc.terminationStatus != 0 {
            // Image may already be attached from a previous failed mount attempt.
            // Detach it first to ensure a clean state, then re-attach fresh.
            // Reusing the stale block device (without detach) risks DA having
            // blacklisted it from the prior failed mount attempt.
            if let staleDevs = Self.alreadyAttachedDevices(forImagePath: path),
               let parent = staleDevs.first(where: {
                   $0.range(of: #"^/dev/disk\d+$"#, options: .regularExpression) != nil
               }) {
                Self.hdiutilDetach(parent)
                // Fall through to fresh attach below.
            } else {
                reply(nil, "hdiutil attach exited with status \(proc.terminationStatus)")
                return
            }
        } else {
            // Fresh attach succeeded — parse and return devices.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            var fmt = PropertyListSerialization.PropertyListFormat.xml
            guard let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: &fmt) as? [String: Any],
                  let entities = plist["system-entities"] as? [[String: Any]] else {
                reply(nil, "failed to parse hdiutil plist output")
                return
            }
            let slices = entities.compactMap { $0["dev-entry"] as? String }
            reply(slices, nil)
            return
        }

        // Re-attach after detaching the stale image.
        let proc2 = Process()
        proc2.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        proc2.arguments = ["attach", "-nomount", "-plist", path]
        let pipe2 = Pipe()
        proc2.standardOutput = pipe2
        proc2.standardError = Pipe()
        do { try proc2.launch(); proc2.waitUntilExit() } catch {
            reply(nil, error.localizedDescription); return
        }
        guard proc2.terminationStatus == 0 else {
            reply(nil, "hdiutil attach (retry) exited with status \(proc2.terminationStatus)")
            return
        }
        let data = pipe2.fileHandleForReading.readDataToEndOfFile()
        var fmt = PropertyListSerialization.PropertyListFormat.xml
        guard let plist = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: &fmt) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else {
            reply(nil, "failed to parse hdiutil plist output")
            return
        }
        let slices = entities.compactMap { $0["dev-entry"] as? String }
        reply(slices, nil)
    }

    /// Query `hdiutil info -plist` and return the dev-entry list for the
    /// given image path if it is already attached, or nil if not found.
    private static func alreadyAttachedDevices(forImagePath path: String) -> [String]? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        proc.arguments = ["info", "-plist"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        guard (try? proc.launch()) != nil else { return nil }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
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
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try? proc.launch()
        proc.waitUntilExit()
    }

    func detachDevice(_ bsdName: String,
                      reply: @escaping (Bool, String?) -> Void) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        proc.arguments = ["detach", bsdName]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        do {
            try proc.launch()
            proc.waitUntilExit()
        } catch {
            reply(false, error.localizedDescription)
            return
        }
        if proc.terminationStatus == 0 {
            reply(true, nil)
        } else {
            reply(false, "hdiutil detach exited with status \(proc.terminationStatus)")
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
        guard let diskprobeURL = Self.locateDiskprobe() else {
            reply(nil, "diskprobe binary not found in bundle Resources or project lib/")
            return
        }
        let proc = Process()
        proc.executableURL = diskprobeURL
        proc.arguments = [path]
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        do {
            try proc.launch()
            proc.waitUntilExit()
        } catch {
            reply(nil, error.localizedDescription)
            return
        }
        guard proc.terminationStatus == 0 else {
            let errMsg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                               encoding: .utf8) ?? ""
            reply(nil, "diskprobe exited \(proc.terminationStatus): \(errMsg)")
            return
        }
        let json = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        reply(json, nil)
    }

    private static func locateDiskprobe() -> URL? {
        // 1. Bundle Resources — production path once diskprobe is added as a resource.
        let agentURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let bundleCandidate = agentURL
            .deletingLastPathComponent() // DiskJockeyAgent → LaunchAgents/
            .deletingLastPathComponent() // LaunchAgents/   → Library/
            .deletingLastPathComponent() // Library/        → Contents/
            .appendingPathComponent("Resources/diskprobe")
        if FileManager.default.isExecutableFile(atPath: bundleCandidate.path) {
            return bundleCandidate
        }
#if DEBUG
        // Dev fallback: walk up from this source file to find lib/diskprobe/diskprobe.
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent("lib/diskprobe/diskprobe")
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
