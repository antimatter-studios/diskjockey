### Added

- **Apple filesystems on qcow2 and VHDX images mount read-only.** FAT, exFAT,
  HFS+ and APFS partitions on an image attached through the DriverKit route are
  mounted read-only through Disk Arbitration instead of skipped.

### Changed

- **The disk-image inspector offers mount controls for qcow2 and VHDX.** It no
  longer calls them a future update; a partitioned qcow2 or VHDX image gets the
  same controls as raw, VHD and VMDK, with read-only drivers marked. A qcow2 or
  VHDX image without a partition table, and a format with no attachment route,
  says it cannot be mounted.
