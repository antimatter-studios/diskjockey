### Added

- **Checking an XFS volume reads it.** A check task runs the XFS driver's
  checker over the mounted volume and writes nothing. Each finding goes to
  the partition log, and the error count to the app. A scan that could not
  read every structure fails the task rather than report the volume clean,
  a repair is refused until the driver offers one, and while a check runs
  the volume answers EBUSY instead of changing what is being checked
  (#324).
