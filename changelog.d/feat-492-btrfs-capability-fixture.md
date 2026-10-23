### Added

- **The btrfs capability seed is built and checked independently.** CI builds it with `mkfs.btrfs --rootdir` and a kernel loop mount, checks it with `btrfs check --readonly`, reads it back with `btrfs inspect-internal dump-tree` and a read-only kernel mount, and proves every capability operation gets a fresh copy.
