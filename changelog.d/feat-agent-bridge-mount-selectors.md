### Added

- **The helper publishes and removes disk images through the DriverKit
  extension's mount and unmount requests.** A failed mount, a disk that never
  appears, a failed unmount or a failed removal each run the cleanup, and the
  image stays open until its disk is removed.
