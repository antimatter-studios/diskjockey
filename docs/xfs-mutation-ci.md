# XFS mutation CI

The `XFS mutations` workflow runs on every pull request touching
`DiskJockeyXFS/`, the XFS bundle, or the oracle's build and VM inputs. It also
runs on matching changes to `main`, daily, and on manual dispatch.

Three jobs pass the same image between runners:

1. **XFS mutations (Linux image)** boots the pinned `fs-linux-test-harness`
   guest under KVM on an x86_64 Ubuntu runner. The guest's `mkfs.xfs` creates
   a 400 MiB image, and the Linux kernel populates the mutation fixtures.
2. **XFS mutations (macOS FSKit volume)** builds the locked XFS Rust bundle
   and runs `scripts/test-xfs-mutations.sh` on `macos-26`. The executable
   compiles the production `XfsVolume`, `XfsDriver`, mount policy and block
   device bridge, calls the FSKit volume methods in-process, and reads the
   mutations back after remounting read-only.
3. **XFS mutations (Linux verify)** boots the same pinned guest and checks
   the changed image with `xfs_repair -n`, `xfs_db`, `xfs_logprint`, and a
   Linux kernel mount. It compares file bytes, metadata, links, extended
   attributes and ACL preservation against the expected results.

All three checks are **advisory**, explicitly declared in `.github-guard`.
Path-filtered checks cannot be required because they do not report on every
pull request. The existing required checks and their budgets remain intact;
the shell guard adds one file to the scripts tier's executed-file floor.
An advisory failure is still a failed oracle run, not validation evidence.

The native executable needs no GUI session, extension installation or
signing. It uses direct `swiftc` compilation with the library tier's Swift 5
language mode and macOS 15.5 target; it is not a SwiftPM test target. It
exercises the real FSKit methods and Rust ABI, but does not demonstrate a
Finder mount or the `fskitd` extension lifecycle. Those remain covered by the
separate signed release validation described in
[XFS v5 release validation](xfs-v5-release-validation.md).

The Linux guest is the independent oracle. Its tools operate on the guest's
own disk, and both Linux jobs make any runner-installed XFS tools unusable
before running the oracle. Missing KVM, fixtures, tools or bundle artifacts
fail the relevant job. Each job retains its full `tmp/logs/` output; image
artifacts connect the jobs within one workflow run. A green native job alone
does not establish Linux acceptance: the verify job must also pass.

For a manual run, check out `fs-linux-test-harness` beside this repository at
the tag in `SIBLING_PINS.txt`, provide the harness's supported host tools and
the XFS bundle, then run:

```sh
scripts/xfs-mutations-vm.sh create tmp/xfs-mutations
mkdir -p tmp/xfs-mutations/expected
scripts/test-xfs-mutations.sh tmp/xfs-mutations/xfs.img tmp/xfs-mutations/expected
scripts/xfs-mutations-vm.sh verify tmp/xfs-mutations
```

Each VM wrapper stops its guest on exit, including failure.
