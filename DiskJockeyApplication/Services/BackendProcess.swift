import Foundation
import Combine
import DiskJockeyLibrary

public struct BackendProcessInfo: Equatable {
    public let port: Int
    public let pid: Int32
    
    public init(port: Int, pid: Int32) {
        self.port = port
        self.pid = pid
    }
}

public enum BackendProcessError: Error, Equatable {
    case executableNotFound
    case invalidConfigDirectory
    case processFailed(String)  // Store error description instead of Error type
    case timeout
    case invalidPort
    case alreadyRunning
    case notRunning
    case terminationFailed
    
    public static func == (lhs: BackendProcessError, rhs: BackendProcessError) -> Bool {
        switch (lhs, rhs) {
        case (.executableNotFound, .executableNotFound):
            return true
        case (.invalidConfigDirectory, .invalidConfigDirectory):
            return true
        case let (.processFailed(lhsError), .processFailed(rhsError)):
            return lhsError == rhsError
        case (.timeout, .timeout):
            return true
        case (.invalidPort, .invalidPort):
            return true
        case (.alreadyRunning, .alreadyRunning):
            return true
        case (.notRunning, .notRunning):
            return true
        case (.terminationFailed, .terminationFailed):
            return true
        default:
            return false
        }
    }
}

public final class BackendProcess: ObservableObject {
    private let logger: LogRepository?

    public init(logger: LogRepository? = nil) {
        self.logger = logger
    }
    
    private func log(_ msg: String) {
        print("Backend: \(msg)")
        logger?.addLogEntry(LogEntry(message: msg, category: "backend"))
    }
    // MARK: - State
    
    public enum State: Equatable {
        case stopped
        case starting
        case running(BackendProcessInfo)
        case failed(BackendProcessError)
        
        public var isRunning: Bool {
            if case .running = self { return true }
            return false
        }
        
        public var info: BackendProcessInfo? {
            if case .running(let info) = self {
                return info
            }
            return nil
        }
    }
    
    // MARK: - Properties
    
    private var process: Process?
    private var observers = [AnyCancellable]()
    private var configDir: String?
    private var readBuffer = Data()
    private var timeoutWorkItem: DispatchWorkItem?
    private let ioQueue = DispatchQueue(label: "com.diskjockey.backend.process", qos: .utility)
    private var fileHandle: FileHandle?
    private var isReading = false
    
    @Published public private(set) var state: State = .stopped
    public var processStatePublisher: AnyPublisher<State, Never> {
        $state.eraseToAnyPublisher()
    }
    
    deinit {
        cleanup()
    }
    
    // MARK: - Public Methods
    
    /// Sets the configuration directory for the backend process
    public func setConfigDir() -> String? {
        // Find the backend executable (customize the path as needed)
        let fileManager = FileManager.default
        let appSupportDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        
        if let backendURL = Bundle.main.url(forResource: "diskjockey-backend", withExtension: nil) {
            self.configDir = appSupportDir.appendingPathComponent("DiskJockey").path
        }

        return self.configDir
    }
    
    /// Starts the backend process if it's not already running
    /// - Throws: `BackendProcessError` if the process cannot be started
    public func start() throws {
        log("[BackendProcess] start() called")
        // Ensure we're not already running
        guard !state.isRunning else {
            log("Backend already running, aborting start.")
            throw BackendProcessError.alreadyRunning
        }
        
        // Ensure we have a valid config directory
        guard let configDir = self.setConfigDir() else {
            log("No config directory set, aborting start.")
            throw BackendProcessError.invalidConfigDirectory
        }
        
        // Ensure the backend executable exists
        guard let backendURL = Bundle.main.url(forResource: "diskjockey-backend", withExtension: nil) else {
            log("Backend executable not found in bundle, aborting start.")
            throw BackendProcessError.executableNotFound
        }
        
        // Clean up any existing process
        log("Cleaning up any existing backend process.")
        // cleanup()
        
        log("Setting backend process state to .starting")
        // Update state to starting
        state = .starting
        
        log("Creating and configuring backend process instance.")
        // Create and configure the process
        let process = Process()
        process.executableURL = backendURL
        process.arguments = ["--config-dir", configDir]
        
        log("Setting up pipes for backend process.")
        // Set up pipes
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        log("Setting up termination handler for backend process.")
        // Set up termination handler
        process.terminationHandler = { [weak self] process in
            guard let self = self else { return }
            let status = process.terminationStatus
            log("Backend process terminated with status: \(status)")
            DispatchQueue.main.async {
                self.cleanup()
                if case .running = self.state {
                    // Only transition to stopped if we were running
                    self.state = .stopped
                }
            }
        }
        
        do {
            log("Launching '\(backendURL.lastPathComponent)' with arguments: \(process.arguments ?? [])")
            // Start the process
            print("Launching '\(backendURL.lastPathComponent)' with arguments: \(process.arguments ?? [])")
            try process.run()
            
            log("Storing process and file handle.")
            // Store process and file handle
            self.process = process
            self.fileHandle = pipe.fileHandleForReading
            self.isReading = true
            
            log("Starting to read backend output in background.")
            // Start reading output in the background
            startReading()
            
            log("Setting up backend process startup timeout.")
            // Set up timeout
            setupTimeout()
            
        } catch {
            let errorDescription = String(describing: error)
            print("Failed to launch backend: \(errorDescription)")
            cleanup()
            throw BackendProcessError.processFailed(errorDescription)
        }
    }
    
    /// Stops the backend process if it's running
    /// - Returns: `true` if the process was stopped, `false` if it wasn't running
    @discardableResult
    public func stop() -> Bool {
        log("[BackendProcess] stop() called")
        // guard let process = process else {
        //     log("[BackendProcess] stop() failed: no process running")
        //     return false
        // }
        
        // // Terminate the process
        // process.terminate()
        
        // // Wait for process to terminate (with timeout)
        // let timeout: TimeInterval = 30.0 // 5 seconds timeout
        // let startTime = Date()
        
        // while process.isRunning {
        //     if Date().timeIntervalSince(startTime) > timeout {
        //         self.log("Warning: Timeout waiting for process to terminate")
        //         process.terminate()
        //         // Give it a moment to terminate gracefully
        //         Thread.sleep(forTimeInterval: 0.5)
        //         if process.isRunning {
        //             process.interrupt()
        //         }
        //         break
        //     }
        //     Thread.sleep(forTimeInterval: 0.1)
        // }
        
        // // Now safe to clean up resources
        // cleanup()
        
        // // Update state if we were running
        // if case .running = state {
        //     state = .stopped
        // }
        
        // self.process = nil
        return true
    }
    
    /// Restarts the backend process
    /// - Throws: `BackendProcessError` if the process cannot be restarted
    public func restart() throws {
        log("[BackendProcess] restart() called")
        stop()
        try start()
    }
    
    // MARK: - Private Methods
    
    private func startReading() {
        guard isReading, let fileHandle = self.fileHandle else { return }
        
        ioQueue.async { [weak self] in
            guard let self = self else { return }
            
            while self.isReading {
                let data = fileHandle.availableData
                if data.isEmpty {
                    // Process has terminated or no data available
                    Thread.sleep(forTimeInterval: 0.1)
                    continue
                }
                
                // Process the data on the main thread
                DispatchQueue.main.async {
                    self.processReceivedData(data)
                }
                
                // Small delay to prevent tight loop
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
    }
    
    private func processReceivedData(_ data: Data) {
        readBuffer.append(data)
        
        // Convert buffer to string and process line by line
        if let output = String(data: readBuffer, encoding: .utf8) {
            let lines = output.components(separatedBy: .newlines)
            
            // Process all complete lines (all except possibly the last one)
            for line in lines.dropLast() {
                print("BACKEND: \(line)")
                
                if line.hasPrefix("PORT=") {
                    let portStr = line.replacingOccurrences(of: "PORT=", with: "")
                    if let port = Int(portStr) {
                        let pid = process?.processIdentifier ?? 0
                        let info = BackendProcessInfo(port: port, pid: pid)
                        
                        // Update state on main thread
                        DispatchQueue.main.async {
                            self.state = .running(info)
                            self.cancelTimeout()
                        }
                        
                        self.log("Backend process started on port: \(port)")
                    }
                }
            }
            
            // Update buffer to only contain the last incomplete line
            if let lastLine = lines.last, !lastLine.isEmpty {
                readBuffer = Data(lastLine.utf8)
            } else {
                readBuffer.removeAll()
            }
        } else {
            // Invalid UTF-8 data, clear buffer
            readBuffer.removeAll()
        }
    }
    
    private func setupTimeout() {
        // Cancel any existing timeout
        cancelTimeout()
        
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self, case .starting = self.state else { return }
            
            self.log("Timeout waiting for backend to start")
            self.cleanup()
            self.state = .failed(.timeout)
        }
        
        timeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: workItem)
    }
    
    private func cancelTimeout() {
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
    }
    
    private func cleanup() {
        log("[BackendProcess] cleanup() called")
        // isReading = false
        // cancelTimeout()
        
        // // Close file handles
        // try? fileHandle?.close()
        // fileHandle = nil
        
        // // Clear buffer
        // readBuffer.removeAll()
        
        // // Remove any observers
        // observers.removeAll()
    }
}
