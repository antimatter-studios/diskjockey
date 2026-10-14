### Added

- **An XFS repair task repairs the volume (#324).** `fsck -y` on an XFS
  volume used to be refused before anything ran. It now runs the driver's
  repair over the volume's device. The mounted driver is let go first, so
  the repair plans from what is on the device and nothing reads it
  meanwhile, and the device is mounted again afterwards as it was. Each
  change, refusal and unrepaired finding goes to the partition log. The
  task completes only when the driver checks the volume clean after the
  repair, and a repair on a device that cannot be written is refused.
  Cancelling the task stops the driver's repair at its next item, before
  anything is written; the volume is still mounted again, and the task
  fails with ECANCELED.
