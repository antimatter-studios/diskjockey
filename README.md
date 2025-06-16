# DiskJockey 
## Project Summary

DiskJockey is a modular, virtual filesystem solution for macOS designed to unify, mount, and manage remote storage backends (cloud, network, etc.) in a seamless way. It leverages a robust Go backend for performance and plugin extensibility, a Swift/Xcode-based macOS GUI for user interaction, and a lightweight helper process to bridge all IPC and system integration. The project aims to provide a reliable, extensible, and user-friendly way to access and synchronize files from various sources, all presented as native Finder volumes.

## Updates:

__15/05/2025:__ I finally was able to launch a file provider and see actual finder volumes. The files were fake. But the file provider was working. I was able to see the volumes in finder and I was able to mount and unmount them. 

__14/06/2025:__ I realise I need a developer account and I can't launch a file provider extension without one :(

__12/06/2025:__ My architecture isn't working as I expect. I think I can't really use a helper application to mediate between the file provider and the backend. I need to find a different way to do this. Because I can't actually get the helper app to run. I think I need to use a different approach.

## Caveats

I realise that this is an open source project and you can download all the code and use it. But you know what? Because apple don't let you run unsigned code in your Finder as
the project requires you to, because you are going to need to run a File Provider extension. You need an Apple Developer Account to compile and run the project. If you don't have one, then all this code will be useful in an educational way. But you won't be able to actually run it. 

## Motivation  
- Simplify integration of multiple remote storage backends into Finder.
- Provide a secure, auditable, and modular architecture.
- Make it easy to add new backends (via Go plugins) and automate workflows (via CLI).
- Decouple UI, backend logic, and system integration for maintainability and testability.

## Aims  
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
File Provider status means the plugin is exposed to Finder. <br/>

Right now, nothing is working through finder, I am building the app up in stages
and I have a rough file provider implementation done. But it's not working yet.

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

- **Main Application**:
  - Manages mounts, settings, and user interface
  - Handles all communication with the backend server
  - Manages the File Provider extension lifecycle
  - Coordinates between the UI, File Provider, and backend

- **Backend Server**:
  - Runs as a separate process managed by the main application
  - Handles file operations, sync, and business logic
  - Exposes a gRPC/HTTP API for communication
  - Manages plugin system for different storage backends
  - Returns port information for direct connections

- **File Provider Extension**:
  - Integrates with macOS Finder to present files
  - Communicates directly with the main application
  - Stateless - all state is managed by the main application
  - Handles file operations initiated by the user in Finder

### Message Flow
| Action                | Initiator         | Flow                                 |
|-----------------------|-------------------|--------------------------------------|
| Mount/unmount         | App UI            | App → Backend                        |
| File operations       | Finder (via FP)   | FileProvider → App → Backend         |
| Backend notifications | Backend           | Backend → App → (UI/FileProvider)    |
| Plugin management     | App UI            | App → Backend                        |

### Benefits
- Simplified architecture with fewer moving parts
- Direct communication between components
- Centralized state management in the main application
- Easier debugging and maintenance
- More reliable IPC through managed connections

### Notes
- The main application acts as the central coordinator
- Backend server is managed by the main application
- File Provider extension remains stateless
- All persistent state is managed by the backend
- The application handles connection management and retries

---

# Project Structure

```
.
├── DiskJockeyApplication/        # Main Xcode project
│   │   ├── App/                  # App entry point and setup
│   │   ├── Views/                # Main UI components
│   │   ├── ViewModels/           # View models
│   │   └── Repositories/         # Data access layer
│   │
├── DiskJockeyFileProvider/       # File Provider extension
│   │   ├── FileProviderItem.swift
│   │   └── FileProviderExtension.swift
│   │
├── DiskJockeyLibrary/            # Shared library between app and extension
│   ├── Models/                   # Shared data models
│   └── Utilities/                # Shared utilities
│
├── diskjockey-backend/           # Go backend
│   ├── ipc/                      # IPC server
│   │   └── client.go
│   │   └── server.go
│   │
│   ├── plugins/                  # Plugin system
│   │   └── dropbox.go
│   │   └── ftp.go
│   │   └── sftp.go
│   │   └── smb.go
│   │   └── webdav.go
│   │
│   ├── services/                   # Services
│   │   └── config_service.go
│   │   └── sqlite_service.go
│   │   └── plugin_service.go
│   │
│   ├── models/                      # gRPC/HTTP API
│   │   └── mount.go
│   │   └── plugin.go
│   │   └── config.go
│   │
│   ├── migrations/                 # Database migrations
│   │   └── migrations.go
│   │   └── 20250608182000_create_mounts.go
│   │   └── 20250608182001_create_plugins.go
│   │   └── 20250608182002_create_configs.go
│   │   └── ...etc
│
├── diskjockey-cli/                # Command-line interface
│   └── main.go                    # djctl implementation
```

## Component Descriptions

- **DiskJockey** (Swift):
  - Main macOS application managing the UI and user interactions
  - Coordinates between the File Provider extension and backend
  - Handles mount management and settings
  - Contains shared code used by both the app and File Provider extension

- **Backend** (Go):
  - Handles all file operations, sync, and plugin management
  - Exposes gRPC/HTTP API for communication
  - Manages mount points and storage backends
  - Runs as a separate process managed by the main app

- **CLI** (Go):
  - Command-line interface for advanced users and automation
  - Uses the same gRPC API as the main app
  - Useful for scripting and headless environments

- **Protocol** (Protocol Buffers):
  - Defines the gRPC service contracts
  - Used to generate client and server code
  - Ensures type-safe communication between components
  - Reduces code duplication through generated client and server code

## Building and Running

### Prerequisites
- Xcode 14+
- Go 1.19+
- Protocol Buffer compiler (protoc) with Swift and Go plugins

### Running

1. Start the DiskJockey app from Xcode or the built .app
2. The app will automatically start the backend server
3. Use the CLI for advanced operations:
   ```bash
   ./djctl list-mounts
   ./djctl list-plugins
   ```