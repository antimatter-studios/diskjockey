### Added

- **The DriverKit extension's user client accepts mount, unmount and list
  requests.** A mount creates the read-only block-device child for the disk
  image and an unmount removes it again. Mounts are still refused until a
  read backend is connected, so no disk appears yet.
