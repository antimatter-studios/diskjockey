### Added

- **The app has an explicit state for each stage of activating the virtual
  disk system extension.** Requesting, waiting for the user's approval,
  activated, activated after a restart, and failed with Apple's error code are
  distinct states; a late callback never undoes a finished activation, and a
  stale copy of the app never downgrades a newer installed driver.
