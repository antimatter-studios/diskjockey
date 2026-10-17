### Fixed

- **An XFS file's access, change and creation times read back as
  themselves.** Every time was shown as the modification time, so an access
  time set on a writable volume read back as a different time. A v4 volume,
  which has no creation time, still shows the modification time for it.
