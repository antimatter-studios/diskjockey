### Added

- **The erofs capability seed is built and checked independently.** CI builds it with `mkfs.erofs` from a staged tree holding its hard link, symlink and xattr, checks it with `fsck.erofs`, reads it back through a read-only kernel mount, and proves every capability operation gets a fresh copy.
