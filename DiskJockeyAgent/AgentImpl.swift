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
        guard proc.terminationStatus == 0 else {
            reply(nil, "hdiutil attach exited with status \(proc.terminationStatus)")
            return
        }
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
        func shellQuote(_ s: String) -> String {
            "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        func appleScriptQuote(_ s: String) -> String {
            "\"" + s
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }

        var cmd = "/bin/mkdir -p \(shellQuote(mountPoint)) && /sbin/mount -F -t \(shellQuote(fsType)) "
        if partitionOffset > 0 {
            cmd += "-o \(shellQuote("partition_offset=\(partitionOffset),partition_length=\(partitionLength)")) "
        }
        cmd += "\(shellQuote(source)) \(shellQuote(mountPoint))"

        let appleScript = "do shell script \(appleScriptQuote(cmd)) with prompt \"Disk Jockey wants to mount a disk image.\" with administrator privileges"

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
}
