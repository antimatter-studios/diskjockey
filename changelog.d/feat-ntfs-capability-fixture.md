### Added

- **The ntfs capability seed is built and checked independently.** CI builds it with mkntfs and an ntfs-3g mount, reads it back with `ntfsls`, `ntfscat` and `ntfsinfo`, and proves every capability operation gets a fresh copy.
