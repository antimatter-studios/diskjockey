# 📁 Virtual Filesystem Architecture for macOS (FileProvider-Based, Updated)

This document describes a secure, disk type-capable, cross-protocol virtual filesystem for macOS using Apple’s FileProvider framework for POSIX compatibility, and a Go-based daemon to orchestrate backend data operations. It incorporates recommendations for IPC, metadata, resilience, and security.

---

## 🧩 System Overview

The application provides a virtual drive mountable via Finder that:
- Appears like a normal disk in the macOS filesystem
- Supports open(), read(), write(), and other POSIX operations transparently
- Loads data on-demand from multiple backends (SFTP, WebDAV, IPFS, etc.)
- Uploads modified files to the appropriate backend
- Maintains a local cache for offline and accelerated access

---

## 🧠 Key Components

### 1. FileProvider Extension (Swift)
- Runs in a macOS sandboxed context
- Exposes the mounted volume (e.g., `/System/Volumes/Data/com.apple.FileProvider.LocalStorage/...`)
- Handles user requests (file open, save, rename, delete)
- Communicates with the Go daemon for data and metadata over a secure IPC channel
- On startup/reconnect, always queries the Go daemon for current state
- Implements robust error handling for daemon restarts or IPC failures

### 2. Core Daemon (Go)
- Persistent background process, restartable and stateless between crashes (all state persisted)
- Implements business logic, cache management, disk type coordination
- Uses BoltDB for metadata storage (see technical-specs.md for rationale)
- Communicates with the Swift extension via IPC (Unix sockets, Protobuf/gRPC)
- Handles authentication, permission mapping, logging, and journaling

### 3. Disk Type Backends (Go interfaces)
- Modular adapters that implement a common Backend interface:
  - `List(path string) ([]FileInfo, error)`
  - `Read(path string) (io.ReadCloser, error)`
  - `Write(path string, data io.Reader) error`
  - `Delete(path string) error`
- Examples: SFTPBackend, WebDAVBackend, IPFSBackend
- Responsible for fetching file data and syncing modifications
- Disk types are loaded/configured dynamically based on user settings

### 4. Cache Directory (User-Managed Disk Cache)
- Stores locally available file data
- Indexed via metadata (BoltDB) to enable quick access and sync tracking
- Supports LRU eviction, pinning, checksum validation, and encryption if required
- File structure: `~/.cache/vfs/backend/domain/...`

### 5. Swift Menu Bar App (Optional)
- Provides user interface for:
  - Mount management
  - Sync status
  - Preferences and backend configuration
  - Log viewing and error reporting
- Talks to the core daemon and exposes UI events

---

## 🔁 IPC Communication

All data transfer between the FileProvider and the Go daemon occurs over a secure IPC layer:
- Protocol: Unix domain sockets using Protocol Buffers (Protobuf) for all messages
- `.proto` definitions stored in shared/ directory, Go and Swift bindings generated
- Socket is placed in app group container directory, permissions set to 0600
- Peer credentials verified on connection; optionally, authentication tokens used
- Never exposes socket on network interfaces
- Daemon handles authentication, permission mapping, and logging

---

## 📦 File Lifecycle Flow

1. Finder shows the virtual drive
2. User opens a file via any POSIX app
3. FileProvider receives the request and checks metadata
4. If file is not available locally:
   - Swift requests file from Go daemon via IPC
   - Go daemon routes request to appropriate disk type
   - Disk type backend fetches file and streams to Swift
   - Swift writes file into the virtual volume
5. File is now accessible via POSIX APIs
6. When user modifies the file:
   - FileProvider notifies Swift
   - Swift notifies Go daemon
   - Daemon syncs changes back to backend

---

## 🚀 Performance and Extensibility
- Multithreaded downloads supported in Go
- Prefetching and prioritization strategies possible (e.g., small files first, recently accessed)
- Pluggable backends can be added without touching core logic
- Daemon and FileProvider are decoupled, improving testability and maintainability
- All state sync is resilient to daemon or extension restarts (see DEVELOPMENT.md)

---

## ✅ Benefits
- Native macOS integration with POSIX support
- No FUSE or kernel extensions required
- Secure and App Store-compatible
- Highly extensible and protocol-agnostic
- Robust against process crashes or restarts

---

## 🔒 Security Considerations
- All backend credentials stored securely in user keychain
- Data access sandboxed per backend
- IPC bridge is authenticated and limited to localhost/app group
- All sensitive operations logged and auditable

---

## 🛠 Future Improvements
- Versioning and conflict resolution
- Snapshotting for offline work
- Metadata-based indexing and fast search
- Transparent encryption for sensitive folders
- Support for multiple FileProvider domains (multi-mount)

---

## 🧠 Design Notes
- All persistent state (metadata, cache) is stored on disk for resilience
- FileProvider extension is stateless; always queries daemon for current state
- IPC protocol is versioned and cross-language (Protobuf)
- Daemon and extension can be independently updated
