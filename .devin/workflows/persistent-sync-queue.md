---
description: How to implement a persistent sync queue for unsynced files in DiskJockey
---

# Persistent Sync Queue for DiskJockey

## Problem
When the main app (and helper/backend) is quit, files that are not yet synced to the server may be lost if the sync queue is only in memory. On relaunch, the app should resume syncing any files that were pending or in progress.

## Solution: Durable Sync Queue

1. **Persist the Sync Queue:**
   - Store the sync queue on disk (e.g., using BoltDB, SQLite, or a JSON file).
   - Each file in the queue should have a status: `pending`, `in_progress`, `synced`, `failed`.
   - Update the queue on every enqueue, dequeue, or status change.

2. **Resume on Startup:**
   - On backend/helper startup, load the queue from disk.
   - Resume processing files with status `pending` or `in_progress`.

3. **Graceful Shutdown:**
   - On shutdown, flush the queue to disk.
   - Mark any `in_progress` items as `pending` so they will be retried on next launch.

4. **Atomicity:**
   - Use transactional DBs (BoltDB, SQLite) or atomic file writes to avoid corruption.

5. **User Feedback:**
   - The main app can query the helper/backend for sync status and display pending/failed/syncing files.

## Example Data Structure (Go)
```go
type SyncItem struct {
    FilePath  string
    Status    string // pending, in_progress, synced, failed
    LastError string
    Timestamp time.Time
}
```

## Summary
- Never keep the sync queue only in memory.
- Persist queue to disk and reload on startup.
- On shutdown, flush state and mark in-progress as pending.

---

This workflow describes the recommended approach for reliable file sync in DiskJockey. Refer to this file when implementing or updating sync queue logic.
