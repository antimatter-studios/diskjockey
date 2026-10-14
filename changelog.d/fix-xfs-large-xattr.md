### Fixed

- XFS delegates resource fork attributes to macOS's AppleDouble fallback, lists forks held in `._` files, and carries those files through removal and rename. Other extended attributes retain XFS's native 64 KiB limit (#353).
