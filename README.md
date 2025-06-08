# DiskJockey 
## Project Summary

DiskJockey is a modular, virtual filesystem solution for macOS designed to unify, mount, and manage remote storage backends (cloud, network, etc.) in a seamless way. It leverages a robust Go backend for performance and plugin extensibility, a Swift/Xcode-based macOS GUI for user interaction, and a lightweight helper process to bridge all IPC and system integration. The project aims to provide a reliable, extensible, and user-friendly way to access and synchronize files from various sources, all presented as native Finder volumes.

**Motivation:**  
- Simplify integration of multiple remote storage backends into Finder.
- Provide a secure, auditable, and modular architecture.
- Make it easy to add new backends (via Go plugins) and automate workflows (via CLI).
- Decouple UI, backend logic, and system integration for maintainability and testability.

**Aims:**  
- Support mounting/unmounting remote filesystems as native Finder volumes.
- Provide a unified, extensible backend for file operations and sync.
- Deliver a polished macOS GUI and CLI for users and power-users.
- Ensure robust, secure IPC and logging throughout the stack.

---

## Project Status

- ✅ Modular Go backend daemon with plugin system
- ✅ Go-based CLI tool (`djctl`) for backend control and debugging
- ✅ Swift/Xcode macOS GUI application
- ✅ Background helper process for IPC and orchestration
- ✅ Shared Swift framework for IPC, protobuf, and backend comms
- ✅ File Provider extension for Finder integration
- ✅ Unified IPC protocol using protobuf
- ✅ Makefile and build automation for Go/Swift targets
- ✅ Multi-process orchestration (main app, helper, backend)
- ✅ Logging and event forwarding via helper
- ⬜️ User-friendly GUI for mount management
- ✅ Plugin system to add different filesystems
- ⬜️ Robust error handling and user notifications
- ⬜️ Comprehensive integration and unit tests
- ⬜️ End-user documentation and onboarding
- ⬜️ Production-ready code signing, packaging, and deployment

---

## Plugin Status

CLI status means you can use the `djctl` tool to control the plugin. <br/>
File Provider status means the plugin is exposed to Finder.

- ✅ Local Directory (mostly useless test dummy plugin)
    - ✅ List Directory (✅ CLI ❌ File Provider)
    - ✅ Read File (✅ CLI ❌ File Provider)
    - ⬜️ Write File 
    - ⬜️ Delete File 
- ✅ Dropbox
    - ✅ List Directory (✅ CLI ❌ File Provider)
    - ✅ Read File (✅ CLI ❌ File Provider)
    - ⬜️ Write File 
    - ⬜️ Delete File 
- ✅ FTP
    - ✅ List Directory (✅ CLI ❌ File Provider)
    - ✅ Read File (✅ CLI ❌ File Provider)
    - ⬜️ Write File 
    - ⬜️ Delete File 
- ✅ SFTP
    - ✅ List Directory (✅ CLI ❌ File Provider)
    - ✅ Read File (✅ CLI ❌ File Provider)
    - ⬜️ Write File 
    - ⬜️ Delete File 
- ✅ SMB
    - ✅ List Directory (✅ CLI ❌ File Provider)
    - ✅ Read File (✅ CLI ❌ File Provider)
    - ⬜️ Write File 
    - ⬜️ Delete File 
- ✅ WebDAV
    - ✅ List Directory (✅ CLI ❌ File Provider)
    - ✅ Read File (✅ CLI ❌ File Provider)
    - ⬜️ Write File 
    - ⬜️ Delete File 

---

# Architecture

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

# Project Structure

```
.
├── diskjockey-backend/      # Go backend daemon
│   ├── main.go
│   ├── ipc/
│   ├── plugins/
│   ├── ...
├── diskjockey-cli/          # Go command-line client (djctl)
│   ├── main.go
│   ├── ...
├── DiskJockeyApplication/   # Main macOS app (Xcode, Swift)
│   ├── AppDelegate.swift
│   ├── ...
├── DiskJockeyHelper/        # Helper app (Xcode, Swift)
│   ├── main.swift
│   ├── ...
├── DiskJockeyHelperLibrary/ # Shared Swift framework for IPC, protobuf, etc.
│   ├── DiskJockeyAPI.swift
│   ├── protocol_definitions.pb.swift
│   ├── ...
├── DiskJockeyFileProvider/  # File Provider extension (Xcode, Swift)
│   ├── FileProviderItem.swift
│   ├── ...
├── Makefile                 # Build automation
├── go.work                  # Go workspace file
├── Package.swift            # SwiftPM manifest
└── ...
```

## Component Descriptions

- **diskjockey-backend** (Go):
  - The backend daemon responsible for all file operations, sync, plugin management, and business logic.
  - Communicates only with the helper process via IPC (UNIX socket).
  - Not directly accessed by the main app or extension.

- **diskjockey-cli** (Go, binary: `djctl`):
  - Command-line tool for advanced users and debugging.
  - Connects to the backend daemon over IPC for manual mount management, plugin inspection, etc.

- **DiskJockeyApplication** (Swift, Xcode):
  - The main macOS GUI app.
  - Manages user settings, mount orchestration, and launches/monitors the helper and backend processes.
  - Does NOT directly request file lists; delegates all backend communication to the helper.

- **DiskJockeyHelper** (Swift, Xcode):
  - A background/launch agent process.
  - Manages persistent IPC connections to the backend.
  - Bridges communication between the main app, File Provider extension, and backend.
  - Handles unified logging and event forwarding.

- **DiskJockeyHelperLibrary** (Swift, Xcode & SwiftPM):
  - Shared framework containing all IPC, protobuf, and backend communication logic.
  - Used by both the helper app and File Provider extension (and optionally the main app).
  - Ensures no code duplication and consistent protocol handling.

- **DiskJockeyFileProvider** (Swift, Xcode):
  - macOS File Provider extension.
  - Exposes the virtual file system to Finder.
  - Stateless and short-lived; calls into the helper for all file operations.

- **Makefile / go.work / Package.swift**:
  - Build system and dependency management for Go and Swift projects.

---

# Diskjockey Backend

This directory contains the Go daemon, plugin system, and cache/metadata logic.

Project Structure:
- main.go: entry point for the daemon
- ipc/: IPC server and protocol bindings
- plugins/: plugin system and dummy/test plugin
- cache/: local cache logic
- metadata/: BoltDB logic
- config/: configuration files
- shared/: generated Go bindings from shared/protocol_definitions.proto

# Diskjockey CLI

This directory contains the Go command-line client (djctl).
- It's purpose is to provider a way to control the system through the comand line
- It's useful for debugging purposes, I can test things without having to use the GUI and I can see more detailed information by outputting a different type of data than what you would see only through the GUI