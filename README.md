# Go Backend

This directory contains the Go daemon, plugin system, and cache/metadata logic.
- main.go: entry point for the daemon
- ipc/: IPC server and protocol bindings
- plugins/: plugin system and dummy/test plugin
- cache/: local cache logic
- metadata/: BoltDB logic
- config/: configuration files
- shared/: generated Go bindings from shared/protocol_definitions.proto
