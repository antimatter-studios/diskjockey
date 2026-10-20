### Added

- **The virtual disk driver and the helper carry the DriverKit entitlements
  activation needs.** The driver is signed with the block-storage family
  entitlement, and the helper with user-client access to the driver, so a
  build signed with a matching provisioning profile can activate it.
