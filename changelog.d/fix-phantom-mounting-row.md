### Fixed

- **No phantom "mounting" row from a test run (#349).** The volume tests run
  the extensions' code over a fake block device named `disk0s1`, and their
  events went to the shared log the app tails, so the app showed
  `disk0s1 · ntfs · mounting…` in Local Drives on a Mac with no NTFS
  partition. Only the app and its extensions now write the shared log; any
  other process, a test runner or an app-hosted test bundle, writes to a
  temporary directory instead. A preview row that no mount follows within
  ten minutes now reads "Not mounted", says which partition the extension
  reported and that Forget removes the row, rather than "mounting" for as
  long as the app runs.
