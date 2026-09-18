import Foundation

/// Run a child process and collect what it wrote, without deadlocking.
///
/// # Why this is a second copy
///
/// `DiskJockeyLibrary` has the same helper, and the app targets use it.
/// This agent cannot: it is not a target in the Xcode project, it is a
/// standalone executable compiled on its own, and it links no framework
/// of ours. A shared file would have to be shared across a boundary
/// that does not exist.
///
/// The two must stay in step. Both carry the reasoning below so a change
/// to one is visibly a change to a decision, not to a detail.
///
/// # The deadlock
///
/// A pipe holds roughly 64 KiB. Once it is full the child's next `write`
/// blocks until somebody drains it — so a parent that waits before
/// reading has arranged for each side to wait on the other:
///
/// ```swift
/// try proc.run()
/// proc.waitUntilExit()                              // waits for the child
/// let out = pipe.fileHandleForReading.readToEnd()   // never reached
/// ```
///
/// `hdiutil info -plist` lists every attached image on the machine and
/// passes 64 KiB easily. `blk-probe` emits a JSON description of a whole
/// disk. Both were called this way.
///
/// Reading first fixes one pipe. Reading two pipes one after the other
/// does not: if the child fills the second while this side is blocked on
/// the first, the standoff happens one stream over. So both are drained
/// concurrently — stderr on a private queue, stdout on the calling
/// thread — and the wait comes last.
///
/// A stream nobody wants still needs a destination that cannot fill,
/// which is what `runDiscardingOutput` uses `/dev/null` for. An unread
/// `Pipe()` is the same bug wearing a different hat.
enum ProcessRunner {

    /// What a finished child left behind.
    struct Output {
        let stdout: Data
        let stderr: Data
        let status: Int32

        var stdoutText: String { String(data: stdout, encoding: .utf8) ?? "" }
        var stderrText: String { String(data: stderr, encoding: .utf8) ?? "" }
    }

    /// Launch `proc`, drain both streams to EOF, and wait for it.
    ///
    /// `proc.standardOutput` and `proc.standardError` are replaced with
    /// fresh pipes, so a caller cannot leave one attached to a buffer
    /// nothing reads.
    static func run(_ proc: Process) throws -> Output {
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        try proc.run()

        // Only stderr goes to another thread; stdout is read on the
        // caller's, which is already committed to waiting. Two
        // background readers cost one more blocked thread per
        // concurrent call for no extra safety.
        var errData = Data()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "diskjockey.agent.process-runner")
        queue.async(group: group) {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        group.wait()

        // Safe now: both pipes are at EOF, so nothing the child does can
        // block, and it has already closed its ends.
        proc.waitUntilExit()
        return Output(stdout: outData, stderr: errData, status: proc.terminationStatus)
    }

    /// Run `proc` with both streams sent to `/dev/null`.
    ///
    /// For a child whose output is genuinely not wanted. `/dev/null` has
    /// no buffer to fill, so the child can write as much as it likes and
    /// still exit.
    @discardableResult
    static func runDiscardingOutput(_ proc: Process) throws -> Int32 {
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()
        return proc.terminationStatus
    }
}
