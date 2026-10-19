### Added

- **The xfs capability seed is built and checked independently.** CI builds it with a mkfs.xfs protofile and a kernel loop mount, checks it with `xfs_repair -n`, reads it back with `xfs_db` and a read-only kernel mount, and proves every capability operation gets a fresh copy.
