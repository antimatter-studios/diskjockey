### Fixed

- **Verify on a mounted ext4 volume runs and reports what it found**
  (#348). Verify ran `fsck_fskit` against the device, and FSKit serves that
  check in a new extension instance that opens the device again, which a
  mounted volume refuses with "Resource busy". Verify is now a request to
  the extension instance that holds the mount, served read-only over the
  mounted volume's own driver under its operation lock, the way Repair
  already was, and the result says how many problems the scan found.
