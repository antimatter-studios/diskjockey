# DEVELOPMENT.md

## Recommended Implementation Sequence

1. **IPC Protocol First**
   - Define all IPC messages in shared/protocol_definitions.proto (Protobuf).
   - Generate Go and Swift bindings.
   - Implement a simple Go daemon that responds to test messages.
   - Implement Swift code to connect and send/receive test messages.

2. **FileProvider Extension Skeleton**
   - Create Xcode project with FileProvider Extension.
   - Implement basic enumeration and placeholder logic.
   - Wire up IPC communication with the Go daemon.

3. **Go Daemon Core**
   - Implement metadata storage using BoltDB (see technical-specs.md for rationale).
   - Implement plugin registry and dummy backend.
   - Add logging and configuration reload support.

4. **End-to-End Dummy Flow**
   - Swift requests file metadata/content via IPC.
   - Go daemon returns dummy data.
   - Swift writes file into FileProvider volume.

5. **Add Real Backend (SFTP)**
   - Implement SFTPBackend plugin in Go.
   - Test real file fetch and sync.

6. **Cache and Sync**
   - Implement cache manager (LRU, pinning, checksum, invalidation).
   - Implement sync queue and journaling.

7. **Menu Bar App and UX Polish**
   - Add Swift menu bar app for status, backend config, and logs.
   - Handle error reporting and user notifications.

## Rationale
- This sequence reduces risk by validating IPC and FileProvider integration early.
- BoltDB is chosen for simplicity, reliability, and Go-native integration.
- Protobuf ensures protocol versioning and cross-language safety.

---

## Notes on State Sync and IPC Security

### Resilient State Sync
- Go daemon stores all state in BoltDB and cache on disk.
- FileProvider extension always queries daemon for current state on startup/reconnect.
- Use operation logs and versioned metadata for recovery.
- Idempotent requests prevent duplication or loss.

### Secure IPC Socket
- Place Unix domain socket in app group container directory.
- Set permissions to 0600.
- Verify peer credentials on connection.
- Optionally use authentication tokens.
- Never expose socket on network interfaces.
