### Added

- **XFS mount access is explicitly gated.** Read-only is the default; `rw` requires writable hardware and approval from the mounted driver. `ro` and FSKit's `--rdonly` veto writes, driver refusal errors are preserved, and read-only volumes no longer advertise permission changes. The currently pinned callback mount remains read-only and refuses explicit writable requests (#321).
- **XFS v5 releases have a dedicated macOS validation job.** The signed FSKit runner requires a complete feature/corruption matrix, verifies write persistence across remount and byte preservation for read-only/refused operations, compares check/repair results with the driver's independent Linux oracle, and retains the exact driver/build provenance (#325). The existing bundle pin and support claims remain unchanged until release validation passes.
- **The XFS device bridge supports bounded writes and flushes.** Partition-relative callbacks preserve partial blocks, reject overflow and writes outside the mounted slice, report short transfers and device errors, and refuse read-only resources. Native ABI and POSIX byte-oracle checks gate the app tier; XFS volume operations remain read-only pending the later integration steps (#320).
- **`am-branch-reap` deletes the branches of merged pull requests nothing needs.** Across the constellation, a branch goes only when a pull request from the same repository merged it at its current commit, more than an hour ago, and no open pull request has it as head or base. Each deletion is logged with its commit first, and the tip and any stacked pull request are checked again just before the delete. Closed and unmerged branches are reported for a person, never deleted. `chore branch:reap` runs it, dry by default.
- **btrfs-win-driver is in the constellation list.** The overview, the ledger and the worktree tools now cover the Btrfs Windows driver beside the ext4, xfs and erofs ones, and the product-scope test expects all 24 repositories (#302).

### Fixed

- **The Unmount button and the stale-mount cleanup work on FSKit volumes.** Both ran `diskutil unmount`, which storagekitd refuses for every FSKit volume ("The volume needs to be mounted"); they now unmount through DiskArbitration, and refuse any path that is not itself a mount point (#166).
- **A transient HTTP 5xx from the chore release download no longer fails a CI job.** `ci.yml` and `release.yml` retry the download up to five times on any error, and `scripts/check-chore-pin.sh` refuses a chore download that does not.

### Changed

- **Every bundle links the latest rust-fs and rust-img releases.** The lockfiles still resolved the first release of each new crate name; they now take rust-fs-core 0.3.11, rust-fs-btrfs 0.10.2, rust-fs-erofs 0.4.1, rust-fs-xfs 0.12.1, rust-img-qcow2/-vhd/-vhdx 0.6.1 and rust-img-vmdk 0.5.1. rust-fs-ext4 0.8.0, rust-fs-ntfs 0.9.0 and rust-fs-squashfs 0.4.0 were already current (#340).
- **`diskutil mount` is documented as unusable for FSKit volumes.** StorageKit lists them as "File System: None" and fails with "Disk is not mountable" without asking DiskArbitration, which mounts the same volume; a guard keeps the app from mounting or unmounting through diskutil (#166).
