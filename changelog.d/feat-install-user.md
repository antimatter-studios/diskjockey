### Added

- `chore install:user` installs the signed Release app into `~/Applications`, creating the folder, without a password.

### Changed

- `chore install` is now `chore install:system`, and `scripts/build-installable.sh --install` takes `user` or `system`; the system install goes through `sudo` only when the account cannot write `/Applications`.
