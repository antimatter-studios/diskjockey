### Fixed

- **XFS volumes no longer advertise immutable-flag changes.** The driver's
  attribute ABI cannot set them, even on a writable mount, so Finder's
  Locked flag was offered and every change was refused.
