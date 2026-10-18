### Added

- **The DriverKit extension has a read-only block-device child.** It carries
  the disk image's attachment identity, so the agent can recognise the disk it
  attached, and advertises write-protected media whose writes are refused.
  Reads are refused until a read backend is connected.
