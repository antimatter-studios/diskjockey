### Added

- **A qcow2 or VHDX image holding a bare filesystem mounts.** An image with no partition table attaches through the DriverKit virtual disk, and its whole disk mounts read-only once it appears, from the disk-image inspector and the file picker alike, instead of the inspector turning it away (#515).
