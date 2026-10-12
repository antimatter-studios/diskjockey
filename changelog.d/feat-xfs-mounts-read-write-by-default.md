### Changed

- **XFS volumes mount read-write by default.** The explicit `rw` requirement
  from #321 is gone: a volume is writable whenever the hardware can be
  written and the mounted driver reports it can write, and read-only only on
  read-only hardware, under a driver that cannot write, or with `ro` /
  `--rdonly`. XFS is meant to be a read-write filesystem here, and a gate
  that needed an option nobody passes from Finder kept every volume
  read-only. Fail-closed behaviour stays: a driver that cannot write gives a
  read-only mount whose mutations answer `EROFS`, options delivered after
  load can revoke writes but never grant them, and a refused mount is never
  retried with weaker options (#343).
