### Fixed

- **NTFS Verify remounts a disk-image or partition volume through the
  resource it was mounted from** (#369). The remount after the check went
  through the raw block device in every case, which for a qcow2, vhd, vhdx
  or vmdk container, or a partition slice, is not the NTFS volume: both the
  read-write and the read-only attempt failed and the volume was left with
  no handle until it was mounted again. It now goes through the same
  container reader and partition slice the mount used, read-write when the
  volume was loaded writable (read-only when the driver refuses), and
  read-only when it was not.
