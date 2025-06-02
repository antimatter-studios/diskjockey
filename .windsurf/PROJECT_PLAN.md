# 📋 Project Plan (Updated): Virtual Filesystem for macOS with FileProvider & Go Backend

This plan outlines the phases, tasks, and design thinking for a robust, plugin-based, cloud-synced virtual filesystem on macOS. It incorporates best practices for IPC, metadata, resilience, and security.

---

## 🎯 Project Objective
Build a secure, mountable macOS virtual drive that integrates with Finder, supports POSIX access, and synchronizes data with multiple backends (SFTP, WebDAV, IPFS), with modular plugin support.

---

## 🧱 Project Phases

### Phase 1: Foundation Setup
- Create a new macOS app project in Xcode with FileProvider Extension
- Initialize the Swift extension with Apple’s template
- Create a companion Go project with a long-running daemon process
- Define an IPC protocol (Protocol Buffers over Unix socket)
- Store `.proto` files in shared/ and generate Go/Swift bindings
- Establish secure communication between Swift and Go processes (see ARCHITECTURE_UPDATED.md)

### Phase 2: Metadata and Mounting
- Implement file tree enumeration in Swift
- Add support for placeholder files and metadata hydration
- Mount the FileProvider volume and verify accessibility via Finder and Terminal
- Ensure POSIX access (ls, cat, open) works

### Phase 3: Go Daemon Design
- Define the Backend interface in Go
- Implement a sample plugin: SFTPBackend
- Implement plugin loading/configuration
- Add local metadata store (BoltDB, see technical-specs.md for rationale)
- Support logging, metrics, and configuration reloading

### Phase 4: File Fetch and Sync
- Handle providePlaceholder(at:) to show file metadata
- Handle startProvidingItem(at:) to download file from Go daemon
- Cache files locally in a disk-backed storage
- Watch for file modifications and notify the Go daemon
- Upload changed files via appropriate backend plugin

### Phase 5: User Experience and Management
- Build a Swift-based menu bar app
- Show sync status and backend configuration
- Allow starting/stopping daemon, selecting backends, and viewing logs
- Provide clear error reporting and user notifications

### Phase 6: Reliability and Persistence
- Implement retry queues and journaling in the Go daemon
- Maintain change tracking (local + remote)
- Ensure daemon relaunches and reconnects with extension
- Handle file conflicts and version mismatch gracefully
- All state is persisted (BoltDB/cache); extension is stateless and always queries daemon for state

### Phase 7: Testing and Packaging
- Write integration tests for file lifecycle
- Test with multiple apps (VSCode, Go compiler, ffmpeg)
- Package app with notarization and developer signing
- Create installation guide and system permission checklist

---

## 📂 Key Deliverables
- Swift FileProvider extension (POSIX-compatible virtual drive)
- Go-based daemon with plugin architecture
- At least one working backend (SFTP)
- Local metadata + cache engine (BoltDB, on-disk cache)
- UI for controlling sync, settings, and error reporting
- Secure, versioned IPC protocol (Protobuf)

---

## 🧠 Design Thinking Notes
- POSIX compatibility is guaranteed only inside FileProvider volume
- Plugin interface in Go must isolate errors and support retries
- Files must be fully hydrated before POSIX access—no just-in-time reads
- Go handles protocol logic, sync engine, caching
- Swift handles system-level and GUI interactions
- Communication is cleanly separable for debugging and security
- All persistent state is on disk for resilience; extension is stateless
- IPC protocol is versioned and cross-language (Protobuf)
- Daemon and extension can be independently updated

---

## ✅ Success Criteria
- POSIX file access works seamlessly via the mounted volume
- Multiple backends supported via plugins
- No need to reduce macOS system security (no SIP reduction or kernel extensions)
- Handles sync, conflicts, and caching transparently
- User can install and use app with minimal technical knowledge
- Secure, auditable, and App Store-compatible
