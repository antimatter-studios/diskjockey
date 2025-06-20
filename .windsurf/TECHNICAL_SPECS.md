# 🛠 TECHNICAL_SPECS_UPDATED.md: Virtual Filesystem for macOS

This document details the technical steps, rationale, and additional best practices for implementing a robust, disk type-based virtual filesystem using Swift (FileProvider & GUI) and Go (backend daemon, disk types).

---

## 🧰 Prerequisites
- macOS 13 or later
- Xcode (latest)
- Go (>= 1.20)
- Apple Developer Account (for provisioning & notarization)
- Code signing certificate and entitlements
- [Optional] Homebrew for dependency management

---

## 🧱 Project Structure

project-root/
├── go-backend/
│   ├── main.go
│   ├── ipc/
│   ├── disktypes/
│   ├── cache/
│   ├── metadata/ (BoltDB)
│   └── config/
├── swift-client/
│   ├── App (menubar app)
│   └── FileProviderExtension/
│       └── FileProvider.swift
├── shared/
│   └── protocol_definitions.proto
│   └── generated/ (Go/Swift bindings)
├── scripts/
│   └── build.sh, test.sh, etc.

---

## 🔧 Step-by-Step Implementation

### 1. Setup the Xcode Project
- Create a new macOS App in Xcode with:
  - App (menu bar)
  - FileProvider Extension
- Enable File Provider capability in both targets
- Add required entitlements:
  - com.apple.developer.fileprovider.testing-mode
  - com.apple.developer.fileprovider.read-write-access
  - Network access (for IPC)
- Configure provisioning profiles and signing certificates
- [Optional] Enable Hardened Runtime

### 2. Build the FileProvider Extension (Swift)
- Implement basic FileProvider domain and item enumeration
- Implement:
  - enumerator(for:)
  - providePlaceholder(at:)
  - startProvidingItem(at:)
  - itemChanged(at:)
- Establish a local mount with NSFileProviderManager.add()
- Implement IPC client to talk to Go daemon
- Handle downloads/uploads and caching by delegating to Go daemon
- Use robust error handling for daemon restarts or IPC failures

### 3. Implement IPC Layer
- Use Unix domain sockets (inside app group container)
- Protocol: Protocol Buffers (Protobuf), not JSON
- Store .proto in shared/, generate Go/Swift bindings
- Permissions: 0600, verify peer credentials, optionally use tokens
- Never expose socket on network interfaces
- In Go:
  - Start IPC server listener
  - Accept requests from Swift
  - Route requests to disk type layer
- In Swift:
  - Connect to socket
  - Encode/decode messages
  - Handle timeouts/fallbacks

### 4. Build the Go Daemon
- Long-running, restartable process
- Command-line interface:
  - ./daemon --foreground --socket=<path> --cache-dir=~/.cache/vfs
- Implement:
  - Metadata store (BoltDB)
  - Cache manager (file expiration, prefetch, LRU, pinning, checksum)
  - Request dispatcher (connects IPC to disk types)
  - Journaling for operation logs
  - Logging (to file & stdout)
  - Config reload support

#### Rationale for BoltDB
- Embedded, Go-native, low overhead
- ACID, concurrent access (single-process)
- High performance
- Avoids SQLite locking issues

### 5. Implement Disk Type System in Go
- Define DiskType interface:
  - List(path) ([]FileInfo, error)
  - Read(path) (io.ReadCloser, error)
  - Write(path, data io.Reader) error
  - Delete(path) error
- Create sample disk type: SFTPBackend
- Disk type registry, load config (JSON, TOML, or YAML)
- Route requests by domain/path
- Disk types must isolate errors and support retries

### 6. Integrate Go Daemon with FileProvider
- Swift receives provide/startProviding item request
- Request metadata/file content from Go daemon
- Write result to NSFileProviderItem local storage
- Acknowledge success/failure
- Swift watches for file change notifications and triggers upload
- All requests are idempotent for resilience

### 7. Implement Local Cache
- Structure: ~/.cache/vfs/backend/domain/...
- Utility methods: LRU eviction, pinning, checksum, invalidation
- Cache is versioned, supports offline mode
- [Optional] Transparent encryption for sensitive files

### 8. Build Menu Bar App (Swift)
- Show sync status (upload/download, last sync time)
- Allow:
  - Start/stop daemon
  - View active backends
  - Configure credentials (Keychain)
  - Open log viewer
  - Communicate with Go daemon via IPC

### 9. Development & Testing Utilities
- CLI to manually test daemon requests
- Write logs to file/stdout
- Unit tests for disk type interface, IPC handlers
- Use Instruments/fs_usage for POSIX flow
- [Optional] Integration tests for end-to-end flows

### 10. Packaging & Distribution
- .app bundle with proper sandbox entitlements
- Sign app with Developer ID
- Enable hardened runtime
- Notarize with Apple
- Build installer script or .dmg
- Document system permissions required

---

## 🛡️ Security & Resilience
- All credentials in Keychain
- IPC socket permissions 0600, peer verification
- Daemon and extension stateless between restarts; all state in BoltDB/cache
- All sensitive operations are logged and auditable
- [Optional] Use encrypted cache for privacy
- [Optional] Use ephemeral tokens for IPC authentication

---

## 🧩 Additional Best Practices & Missing Pieces
- **CI/CD:** Automate build, test, and notarization steps (e.g., GitHub Actions)
- **Crash Recovery:** Use operation logs/journaling for safe recovery after crash
- **Versioning:** IPC protocol and cache format are versioned; support rolling upgrades
- **Observability:** Add metrics endpoints (Prometheus, etc.) for daemon health
- **Documentation:** Inline code docs, user/developer guides, and troubleshooting FAQ
- **Accessibility:** Menu bar app and notifications should support VoiceOver
- **Internationalization:** Prepare for localization if distributing broadly
- **Performance:** Profile cache, IPC, and disk type code under real workloads

---

## ✅ Completion Checklist
- App runs with FileProvider integration
- Volume appears in Finder and via POSIX
- Go daemon responds to IPC and serves files
- Cache system and disk type interface are reliable
- All error and sync states are visible in UI/logs
- Fully signed and notarized application package
- Tested with third-party apps (VSCode, ffmpeg, go build)
- CI/CD pipeline passes for build/test/package
