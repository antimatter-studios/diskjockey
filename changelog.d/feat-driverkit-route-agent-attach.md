### Added

- **qcow2 and VHDX images mount through the DriverKit route.** The app attaches
  the image through the agent's owned DriverKit attachment, waits for its
  partitions to appear, and mounts each selected partition read-only. A mount
  failure, or partitions that never appear, detaches the attachment exactly
  once, so none survives a half-finished mount.
