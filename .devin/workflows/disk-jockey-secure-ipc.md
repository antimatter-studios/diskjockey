---
description: Proposal for Secure IPC for Disk-Jockey CLI and Daemon
---

# Secure IPC Proposal for Disk-Jockey

## 1. Local Security (default)
- Use a Unix domain socket with permissions `0600` (owner-only access).
- Only allow CLI and daemon to run as the same user.

## 2. Shared Secret Authentication (optional)
- Generate a random secret token at first launch, store in config file with `0600` permissions.
- Require CLI to read the token and present it on connection.
- Daemon validates token before accepting commands.

## 3. Challenge-Response (optional, advanced)
- Use a nonce-based challenge/response protocol to avoid replay attacks.

## 4. Remote Access (future)
- Use TLS with client/server certificates for encryption and authentication.
- Or require SSH port forwarding to access the Unix socket remotely.

## 5. Recommendation
- For now, rely on Unix socket permissions for local security.
- Add secret/token authentication if multi-user or remote access is needed.

---
This workflow documents security recommendations for future implementation. CLI and daemon currently run with no authentication for local development.
