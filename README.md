# DiskJockey Architecture (June 2025)

## High-Level Overview
- **Main App**: Manages mounts, settings, and user orchestration. Does **not** directly request file lists.
- **Helper Process**: Always running. Manages persistent IPC connection pool to the Go backend. Acts as a bridge for all communication between the main app, File Provider extension, and Go backend. Handles:
  - Mount management requests from the app
  - File system requests from the File Provider extension
  - Receives log/events from backend and writes to unified log
  - Forwards backend events to app or extension as needed
- **Go Backend**: Handles actual file operations, sync, and business logic. Communicates only with the helper over IPC. Sends logs/events to helper.
- **File Provider Extension**: Stateless, short-lived. Exposes the virtual file system to Finder. Calls into the helper for all backend/file operations. Does **not** talk to the Go backend directly or the app for file lists.

### Message Flow
| Action                | Initiator         | Flow                                 |
|-----------------------|-------------------|--------------------------------------|
| Mount/unmount         | App               | App → Helper → Backend               |
| File list/read/write  | Finder (via FP)   | FileProvider → Helper → Backend      |
| Logging               | Backend           | Backend → Helper → Unified Log       |
| Status/events         | Backend           | Backend → Helper → App (optional)    |

### Benefits
- Single point of IPC management (the helper)
- Unified logging via helper
- Extension stays lightweight
- Easy to add new features

### Notes
- The app does **not** directly request file lists; only the File Provider does this, and only via the helper.
- The Go backend is mostly useless on its own; it runs only when the app (and thus the helper) is running.
- File Provider extension is short-lived and stateless.

---

# Go Backend (Details)

This directory contains the Go daemon, plugin system, and cache/metadata logic.
- main.go: entry point for the daemon
- ipc/: IPC server and protocol bindings
- plugins/: plugin system and dummy/test plugin
- cache/: local cache logic
- metadata/: BoltDB logic
- config/: configuration files
- shared/: generated Go bindings from shared/protocol_definitions.proto
