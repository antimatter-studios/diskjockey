/*
 * RepairXPCService.swift — file-based repair watcher inside the NTFS
 * FSKit extension. Mirrors the EXT4 sibling's design exactly: poll
 * the App Group container for new request files, run the repair
 * (or in NTFS's case: reply "not implemented yet"), drop a result
 * file. See DiskJockeyEXT4/RepairXPCService.swift and
 * DiskJockeyRepairProtocol.swift for the rationale.
 *
 * The driver's repair pass isn't wired yet — `fs_ntfs_fsck_with_callbacks`
 * does dirty-bit/logfile work but not metadata repair. Until that
 * lands, every request gets a truthful "not implemented" response so
 * the host app surfaces an honest error rather than faking success.
 */

import Foundation
import os
import DiskJockeyLibrary

private extension String {
    func deletingPrefix(_ p: String) -> String {
        hasPrefix(p) ? String(dropFirst(p.count)) : self
    }
    func deletingSuffix(_ s: String) -> String {
        hasSuffix(s) ? String(dropLast(s.count)) : self
    }
}

final class RepairXPCService: NSObject {

    static let shared = RepairXPCService()

    private let lock = OSAllocatedUnfairLock(initialState: false)
    private var watcher: DispatchSourceFileSystemObject?
    private var watchedFD: CInt = -1
    private let workQueue = DispatchQueue(
        label: "com.antimatterstudios.diskjockey.ntfs.repair",
        qos: .userInitiated
    )

    func start() {
        let shouldStart: Bool = lock.withLock { started in
            if started { return false }
            started = true
            return true
        }
        guard shouldStart else { return }

        do {
            try DiskJockeyRepairFiles.ensureDirectories(forFsType: "ntfs")
        } catch {
            log.error("RepairWatcher: ensureDirectories failed: \(error.localizedDescription)",
                      scope: AppLogScope.lifecycle)
            return
        }
        guard let requestsURL = DiskJockeyRepairFiles.requestsURL(forFsType: "ntfs") else {
            log.error("RepairWatcher: App Group container unreachable",
                      scope: AppLogScope.lifecycle)
            return
        }

        scanAndProcess()

        let fd = open(requestsURL.path, O_EVTONLY)
        if fd < 0 {
            let errStr = String(cString: strerror(errno))
            log.error("RepairWatcher: open(\(requestsURL.path)) failed: \(errStr)",
                      scope: AppLogScope.lifecycle)
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: workQueue
        )
        source.setEventHandler { [weak self] in
            self?.scanAndProcess()
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()

        self.watchedFD = fd
        self.watcher = source

        log.info("RepairWatcher: watching \(requestsURL.path)",
                 scope: AppLogScope.lifecycle)
    }

    private func scanAndProcess() {
        guard
            let requestsURL = DiskJockeyRepairFiles.requestsURL(forFsType: "ntfs"),
            let processingURL = DiskJockeyRepairFiles.processingURL(forFsType: "ntfs")
        else { return }

        let fm = FileManager.default
        let entries: [URL]
        do {
            entries = try fm.contentsOfDirectory(
                at: requestsURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            log.error("RepairWatcher: cannot list \(requestsURL.path): \(error.localizedDescription)",
                      scope: AppLogScope.lifecycle)
            return
        }

        for src in entries where src.lastPathComponent.hasPrefix("request-") {
            let dst = processingURL.appendingPathComponent(src.lastPathComponent)
            do {
                try fm.moveItem(at: src, to: dst)
                log.info("RepairWatcher: claimed \(src.lastPathComponent) → processing/",
                         scope: AppLogScope.lifecycle)
            } catch {
                log.info("RepairWatcher: skipped \(src.lastPathComponent) (already claimed): \(error.localizedDescription)",
                         scope: AppLogScope.lifecycle)
                continue
            }
            workQueue.async { [weak self] in
                self?.handleRequest(at: dst)
            }
        }
    }

    private func handleRequest(at processingURL: URL) {
        defer {
            try? FileManager.default.removeItem(at: processingURL)
        }

        let request: RepairRequest
        do {
            let data = try Data(contentsOf: processingURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            request = try decoder.decode(RepairRequest.self, from: data)
            log.info("RepairWatcher: decoded request id=\(request.id) bsd=\(request.bsd)",
                     scope: AppLogScope.lifecycle)
        } catch {
            let filename = processingURL.lastPathComponent
            let recoveredID = filename
                .deletingPrefix("request-")
                .deletingSuffix(".json")
            log.error("RepairWatcher: decode failed for \(filename): \(error.localizedDescription) — replying with failure result so the host doesn't wait the full timeout",
                      scope: AppLogScope.lifecycle)
            if let uuid = UUID(uuidString: recoveredID) {
                writeResult(
                    RepairResult(
                        id: uuid,
                        success: false,
                        message: "Could not decode repair request: \(error.localizedDescription)"),
                    for: uuid
                )
            } else {
                log.error("RepairWatcher: filename did not yield a parseable UUID — host will hit polling timeout",
                          scope: AppLogScope.lifecycle)
            }
            return
        }

        log.info("RepairWatcher: starting repair for request id=\(request.id) bsd=\(request.bsd)",
                 scope: AppLogScope.lifecycle)
        let result = runRepair(for: request)
        log.info("RepairWatcher: repair finished for id=\(request.id) bsd=\(request.bsd) success=\(result.success) repaired=\(result.repairedCount.map { "\($0)" } ?? "-")",
                 scope: AppLogScope.lifecycle)
        writeResult(result, for: request.id)
    }

    private func runRepair(for request: RepairRequest) -> RepairResult {
        let resolved: NTFSFileSystem.MountedResource? = NTFSFileSystem.mountedResources.withLock { map in
            map.values.first(where: { $0.bsdName == request.bsd })
        }
        guard resolved != nil else {
            let msg = "no mounted ntfs volume for bsd=\(request.bsd) — is the disk still attached?"
            log.warn("RepairWatcher: \(msg)", scope: AppLogScope.fsck)
            return RepairResult(id: request.id, success: false, message: msg)
        }
        // Truthful "not implemented" — see file header.
        let msg = "In-process repair for NTFS isn't implemented yet — track follow-up work in the NTFS crate."
        log.warn("RepairWatcher: \(msg)", scope: AppLogScope.fsck)
        return RepairResult(id: request.id, success: false, message: msg)
    }

    private func writeResult(_ result: RepairResult, for id: UUID) {
        guard let responsesURL = DiskJockeyRepairFiles.responsesURL(forFsType: "ntfs") else {
            log.error("RepairWatcher: responses dir unreachable; result for \(id) dropped",
                      scope: AppLogScope.lifecycle)
            return
        }
        let dst = responsesURL.appendingPathComponent(
            DiskJockeyRepairFiles.resultFilename(id: id)
        )
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(result)
            try data.write(to: dst, options: .atomic)
            log.info("RepairWatcher: wrote result \(dst.lastPathComponent) (success=\(result.success))",
                     scope: AppLogScope.lifecycle)
        } catch {
            log.error("RepairWatcher: cannot write result for \(id): \(error.localizedDescription)",
                      scope: AppLogScope.lifecycle)
        }
    }
}
