### Fixed

- **NTFS Verify checks through a device that flushes, and clears the dirty
  flag only when asked** (#367). Verify ran rust-fs-ntfs' fsck over the
  read/write callback pair, which 0.10.0 refuses for a log replay or a
  dirty-flag clear because it cannot order those writes. It now checks
  through an fs_core device with a flush callback, over the same container
  and partition slice the mount reads. Verify clears the dirty flag; the
  check a read-write remount runs on its own replays the log and leaves the
  flag for Windows' chkdsk, so a volume still dirty stays read-only until
  Verify.
