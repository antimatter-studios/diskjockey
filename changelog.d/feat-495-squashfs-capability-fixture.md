### Added

- **The squashfs capability seed is built and checked independently.** CI builds it with `mksquashfs` from a staged tree holding its hard link, symlink and xattr, reads it back with `unsquashfs` and a read-only kernel mount, and proves every capability operation gets a fresh copy.
