### Added

- **The DriverKit extension learns each disk image's decoded size from the
  helper before it accepts a mount.** The helper's read connection carries the
  image's identity and decoded capacity, the extension checks every mount
  against that size, and a mount for an image the helper has not registered is
  refused as not ready.
