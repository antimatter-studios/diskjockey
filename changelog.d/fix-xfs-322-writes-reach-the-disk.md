### Fixed

- **XFS FSKit writes reach the disk** (#322). The extension mounted every
  XFS volume through the driver's read-only callback mount, so no write was
  ever authorised. It now asks rust-fs-xfs 0.13 for a writable mount whenever
  the policy and the hardware allow one, and mounts read-only when the driver
  cannot write the volume (a v4 volume, a log holding unapplied records).
  `synchronize` flushes the driver's log home and answers its errno, and a
  writable volume offers its free blocks to Finder, which checks them before
  it copies.
