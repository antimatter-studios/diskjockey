### Added

- **The app activates its virtual disk driver when a qcow2 or VHDX image is
  mounted.** The app holds the system-extension install entitlement and asks
  for the driver the first time such an image is mounted, not at launch; a
  mount that needs approval or a restart says so instead of failing silently.
