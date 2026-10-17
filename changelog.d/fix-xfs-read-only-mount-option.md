### Fixed

- **An XFS volume that cannot write mounts read-only** (#354). A volume the
  policy mounts read-only, or whose driver refused writes, asks FSKit for a
  read-only mount, so Finder no longer shows it as writable and lets every
  write fail with EROFS.
