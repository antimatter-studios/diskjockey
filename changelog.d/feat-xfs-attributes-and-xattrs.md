### Added

- **XFS volumes take mode, owner, time and extended attribute changes**
  (#328). Mode, owner and the access and modification times are set in one
  logged record beside a size change, and a field the driver cannot set (BSD
  flags, birth time) refuses the request before anything is written. Extended
  attributes are stored in XFS's user namespace under their macOS names,
  FSKit's create and replace policies are the driver's own flags, and every
  refusal is its errno. macOS's ACL attribute, `com.apple.system.Security`,
  is refused: stored as a POSIX ACL or as plain bytes it would change what
  it means. POSIX ACLs already on a volume stay in step with mode changes,
  which the driver keeps.
