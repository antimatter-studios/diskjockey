### Fixed

- **Add Disk Image mounts, and the Home page lists, every filesystem the app
  ships** (#346, #351). An XFS or Btrfs partition was skipped as having no
  driver, a single XFS, Btrfs, EROFS or SquashFS image named by blk.probe was
  not recognised, and the Home page's Filesystems card listed four of six.
  The app now reads one list of its FSKit extensions, held by a test to the
  personalities their Info.plist files declare, and its own partition probe
  recognises XFS and Btrfs, reading far enough into a partition to reach
  Btrfs's superblock at 64 KiB.
