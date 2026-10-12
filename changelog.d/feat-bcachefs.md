### Added

- **bcachefs volumes mount read-write.** A new `DiskJockeyBCACHEFS` FSKit
  extension, linked to `rust-fs-bcachefs` with its `write` feature,
  recognises a bcachefs superblock and mounts single-device, unencrypted
  filesystems read-write whenever the device is writable; `ro` and FSKit's
  `--rdonly` make it read-only. Reads cover directories, files, symlinks,
  hard links, extended attributes, times and free space; writes cover
  create, mkdir, remove, rename, symlink, hard link, write, truncate, mode,
  owner and extended attributes. What the driver refuses (encrypted or
  multi-device filesystems, subvolumes other than the root, names in
  casefolded directories) reaches FSKit as its errno. The app's partition
  probe, image attach, sidebar and Home page know bcachefs, and the library
  tier tests the volume over the real driver on images the reference
  bcachefs tools made (#342).
