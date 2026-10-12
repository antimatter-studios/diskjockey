### Added

- **XFS volumes take creates, removals, renames and hard links** (#326,
  #327). Each reaches rust-fs-xfs 0.13's logged record: a file or directory
  is made with the mode asked for and its owner set right after, a name is
  unlinked or an empty directory removed, a rename replaces a name at the
  destination as rename(2) does, and a hard link gives a file a second name.
  Every refusal is the driver's own errno. A symlink stays `ENOTSUP`, because
  rust-fs-xfs makes none, and so do devices, fifos and sockets, which its C
  ABI cannot create.
