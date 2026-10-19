### Added

- **The ext4 capability seed is built and checked independently.** CI builds it with e2fsprogs, reads it back with `e2fsck` and `debugfs`, and proves every capability operation gets a fresh copy.
