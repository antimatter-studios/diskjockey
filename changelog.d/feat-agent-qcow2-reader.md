### Added

- **The agent reads qcow2 images for the virtual disk.** A qcow2 image's
  decoded capacity and blocks reach the DriverKit read path through the same
  agent adapter as VHDX. An image that names a backing file is refused, since
  only the chosen image was authorized.
