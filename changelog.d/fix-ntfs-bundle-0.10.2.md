### Fixed

- **NTFS volumes keep their reparse-point and object-id indexes in step.**
  The NTFS bundle moves to rust-fs-ntfs 0.10.2. A symlink, a reparse point
  or an object id the extension writes is entered in
  `$Extend\$Reparse:$R` or `$Extend\$ObjId:$O`, and taken out with the
  file. Deleting a file with an object id works on a volume where Windows
  has grown that index past its root. Before this, chkdsk found such files
  missing from the index.
