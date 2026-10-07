# macOS XFS v5 release validation

This is the dedicated, interactive macOS runner job for diskjockey#325. It
validates the signed application through Apple's FSKit mount and maintenance
entry points, and asks the Rust driver's independent Linux oracle to validate
the resulting images. The unsigned PR test tiers do not certify a release.

The job is `chore test:xfs-v5-release`, implemented by
`scripts/test-xfs-v5-release.sh` and `scripts/xfs-v5-release.py`. Missing inputs,
an unregistered/disabled extension, a refused supported operation, a missing
oracle or an unexpected check result fail the job. There are no fixture skips.
Only disposable copies of raw whole-volume fixtures are attached or modified.
Do not supply physical devices, valuable data or partitioned disk images.

## Release order and provenance

1. Select a **published** Rust XFS release only after its required CI, format
   oracles and release/attestation gates have passed. Retain the release URL,
   the exact successful runs and fixture-generation evidence. A crate existing
   on crates.io or a release having a tag is not gate evidence.
2. Review its v5 support/refusal matrix. Only then update the XFS bundle
   dependency and lockfile, when an update is needed. Do not infer support from
   the application's ability to build. This change does **not** move the
   existing `rust-fs-xfs 0.12.0` bundle pin or advertise v5 write/repair support.
3. In a clean release checkout, run `make vendor-all`, the three test tiers and
   `make installable`. Keep the vendor and signed archive/export build logs.
   Build against the reviewed lockfile without `dev-link` overrides. Produce
   the receipt below **from that build**, binding the extension executable and
   the archive to the resolved driver version. A receipt copied from another
   build is invalid even when its marketing version matches.
4. Run this job on that exact signed application and retain all its evidence.
   Update release support documentation only when all eight cases and the
   independent oracle pass. An incomplete or failed job blocks certification.

The reviewed build receipt is JSON:

```json
{
  "driver_version": "REVIEWED_PUBLISHED_VERSION",
  "rust_release_url": "https://github.com/antimatter-studios/rust-fs-xfs/releases/tag/REVIEWED_TAG",
  "rust_gates_url": "https://github.com/antimatter-studios/rust-fs-xfs/actions/runs/REVIEWED_RUN",
  "fixture_provenance_url": "https://REVIEWED_FIXTURE_ARTIFACT_AND_GENERATION_LOG",
  "extension_sha256": "SHA256_OF_SIGNED_EXTENSION_EXECUTABLE",
  "archive_sha256": "SHA256_OF_LIBDJ_XFS_BUNDLE_ARCHIVE"
}
```

Use `shasum -a 256` on
`<app>/Contents/Extensions/DiskJockeyXFS.appex/Contents/MacOS/DiskJockeyXFS`
and `lib/bundle_xfs/libdj_xfs_bundle.a`. The runner compares both hashes,
`lib/bundle_xfs/VERSION.txt` and `rust-bundles/dj-xfs-bundle/Cargo.lock`. It
records the checkout commit, lockfile digest, resolved crate versions, macOS
version and receipt. Receipt URLs are evidence references for human review;
the runner does not certify remote GitHub check conclusions by itself.

## Runner prerequisites

- macOS 26, Xcode, Python 3.11 or newer, an interactive logged-in GUI session,
  Developer Mode and a signed application with the FSKit Module entitlement.
- The reviewed application is launched and its XFS extension is enabled in
  System Settings. Exactly that extension path must be registered. Follow
  [the extension registry procedure](ext4-mount-runbook.md#the-extension-registry-what-decides-which-extension-mount-gets)
  before running; the job does not reset daemons or change registration.
- `sudo -n` works for `mount`, `umount` and `fsck_fskit` for this test session.
  Use a disposable runner; do not weaken machine-wide sudo policy for the job.
  Fixture roots must permit the logged-in test user to create files. An
  `EACCES` failure is not accepted as proof of read-only policy.
- Reviewed fixture images, `matrix.json`, the build receipt and an executable
  absolute path to the driver's Linux oracle adapter. These are release
  artifacts, not fixtures manufactured by the Swift tests.
- Enough space for eight full image copies, command logs and oracle artifacts.
  Each command has a 120-second ceiling; a timeout fails the job.

## Required matrix

Every ID below must occur exactly once. Feature names in the manifest are the
complete enabled set reported by the independent oracle, including any
additional features. The listed features are the minimum required per row.

| ID | Minimum features | Required result |
|---|---|---|
| `rw-base` | v5 CRC | Clean check/repair, read, successful writes and remount |
| `rw-features` | CRC, finobt, inobtcount, rmapbt, reflink | Same; include hashes of populated shared files to catch damage to existing contents |
| `rw-encoding` | CRC, bigtime, nrext64, sparse | Same with these inode encodings |
| `ro-request` | v5 CRC | Writable device attached, `mount -o rdonly`, writes refused |
| `ro-resource` | v5 CRC | Device attached with `hdiutil -readonly`, writes refused without requiring a read-only mount option |
| `unsupported` | v5 CRC plus a named unsupported feature | Check, repair and mount refuse with exact reviewed status and feature-specific diagnostic |
| `repairable` | v5 CRC plus known supported corruption | Check detects corruption, repair changes bytes, check becomes clean, mount/read/write/remount succeed |
| `unrepairable` | v5 CRC plus known unsupported corruption | Check detects corruption, repair refuses by name, no image bytes change |

The corruption fixtures must come with independently established defects and
expected outcomes. Do not choose arbitrary bit flips and accept whatever the
application returns. Use the released driver's fixture-generation and oracle
evidence; filesystem structure generation/validation remains in that repository.
Do not downgrade a required `rw` row to read-only to make the job pass.

Each entry of `matrix.json` has this shape; this is one schema example, not a
complete matrix or a statement that a particular driver release supports it:

```json
{
  "id": "rw-base",
  "mode": "rw",
  "features": ["crc"],
  "image": "xfs-v5-base.img",
  "sha256": "64_LOWERCASE_HEX_DIGITS_FROM_LINUX_FIXTURE_ARTIFACT",
  "files": {"sf/aaaa": "64_LOWERCASE_HEX_DIGITS_FROM_LINUX_SHA256SUM"},
  "check": {"exit": 0, "pattern": ""},
  "repair": {"exit": 0, "pattern": ""},
  "mount": {"exit": 0, "pattern": ""}
}
```

The top-level JSON is an array of eight entries. `mode` is `rw` for the four
write rows, `deny` for both read-only rows, and `reject` for the two refusal
rows. Paths are relative to the manifest; seed file paths are relative to the
volume. Read hashes come from Linux kernel reads, not this driver's reader.
Reserve `dj-release*` at the volume root for the test workload. For `reject`
rows, `files` can be empty. The `unrepairable` mount expectation is unused:
the job intentionally does not mount a volume whose corruption cannot be
repaired. Its evidence is the maintenance refusal and unchanged image.

Nonzero expected statuses must be exact integers and have a reviewed regular
expression that names the known defect/unsupported feature. A generic failure
or `Module ... is disabled!` must never satisfy those expectations. Even if
`fsck_fskit -n` exits zero, the independent oracle must agree that the image is
clean; XFS check's historical unconditional success is not accepted as evidence.

## Independent oracle adapter

Keep filesystem validation in the driver repository. The macOS job calls its
release's approved adapter as:

```text
/absolute/driver-oracle-adapter image-copy.img oracle-expectation.json evidence-directory
```

The adapter must transfer or expose the **post-macOS** image to Linux, run
`xfs_db` to report v5 features, run `xfs_repair -n`, and mount supported images
with the real Linux XFS kernel read-only without log replay (`ro,norecovery`).
It must compare all expected file hashes and expected absences. For refused
or unrepairable images it must independently confirm the named feature/defect
and the expected refusal/corruption verdict. Retain raw tool diagnostics,
kernel read/hash results, tool/kernel versions and transfer digests in the
evidence directory. Check diagnostic contents as well as process status:
`xfs_repair -n` can report inconsistencies that need repair without a reliable
nonzero status for every defect. Do not run repairing `xfs_repair`, use `-L`,
or replay the journal to conceal an unsuccessful macOS repair.

The adapter exits nonzero on any mismatch and emits only this JSON on stdout
(normal logs go to retained files or stderr):

```json
{
  "filesystem_version": 5,
  "features": ["crc"],
  "files": {"sf/aaaa": "EXPECTED_HASH", "dj-release/removed": null},
  "verdict": "clean",
  "kernel_version": "EXACT_LINUX_KERNEL_VERSION",
  "xfsprogs_version": "EXACT_XFSPROGS_VERSION"
}
```

`files` must match the expectation exactly. `null` means an entry must be
absent. `verdict` is `clean`, `unsupported` or `corrupt`, as specified by the
job. Report actual feature flags and reads, never copy expected JSON into a
report. Transport adapters need the same review as the fixture artifacts.
For SSH, use `BatchMode=yes`, `IdentitiesOnly=yes` and the named agent key on
every hop. Use the existing driver oracle transport; no new SSH config entries.
The job checks that the oracle leaves the local evidence image unchanged.

## Execute and retain evidence

After the prerequisites and receipt have been reviewed:

```sh
chore test:xfs-v5-release -- \
  --matrix /absolute/release-fixtures/matrix.json \
  --app /absolute/reviewed/DiskJockey.app \
  --release-evidence /absolute/reviewed/build-receipt.json \
  --oracle /absolute/driver-oracle-adapter \
  --output "$PWD/tmp/xfs-v5-release/run-$(date -u +%Y%m%dT%H%M%SZ)"
```

The output directory must be new. The quiet wrapper retains its transcript at
`tmp/logs/xfs-v5-release.log` (100 lines/20,000 bytes; eight verdicts plus a
summary fit comfortably; command transcripts live in separate JSON artifacts).
Run the script directly with the same arguments if `chore` is unavailable.

For every mounted supported row, the job verifies Linux-derived seed hashes,
creates a directory/file, overwrites, appends, truncates, fsyncs, renames and
unlinks. It unmounts, detaches, reattaches and mounts read-only before verifying
the fixed payload hash and absence of the unlinked file. It checks again after
writes and requires the Linux oracle to confirm the same persisted contents.
Both read-only cases must refuse writes with `EROFS`/`ENOTSUP`, retain all seed
contents across remount, and preserve the whole image SHA-256. Checks always
preserve image bytes. Clean repairs and refused repairs preserve bytes; the
known repairable fixture must change and then be independently clean.

Archive the complete output directory and quiet log even on failure, including
all image copies, command JSON, receipt, original matrix, per-case hashes,
oracle records and `summary.json`. Certification requires process exit zero,
`summary.json.passed == true` and eight per-case `result.json` records with
`passed == true`. Contract tests using local fake commands validate the runner
only; they are never macOS filesystem release evidence.

## Initial implementation evidence and remaining release gate

The baseline on 2026-10-07 was 43 shell guards, 577 library cases, 85 app cases
and the native XFS callback oracle, all passing. macOS shell guards require
the installed GNU date/sed on PATH; their existing tests exercise those CLI
forms. The new runner contract tests cover completeness, provenance inputs,
refusal diagnostics, image preservation, cleanup and independent readback.
The post-change tiers pass 44 shell guards, 577 library cases and 85 app cases,
plus the native callback oracle. The runner has 25 contract tests; its measured
branch coverage rises from 71% to 84% as failure-path tests are added. The
missing-input job exits 1 and retains `summary.json` with `passed: false`.

No end-to-end v5 release pass is claimed here. The current application still
mounts XFS read-only and its check callback reports unconditional success;
this job deliberately fails those behaviors on required write/corruption rows.
An approved v5 release receipt, complete reviewed corruption/feature matrix,
driver oracle adapter and enabled signed candidate are required before the
eight-case release gate can be run and support documentation/pins advanced.
