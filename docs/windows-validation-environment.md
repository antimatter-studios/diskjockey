# Windows validation environment for fs_ntfs_mkfs

End-to-end notes on running Windows `chkdsk` against NTFS images produced
by `fs_ntfs_mkfs` (and, by extension, anything in `vendor/rust-fs-ntfs`
that mutates on-disk state). Our own crate's read path round-trips an
mkfs'd image cleanly, but that only proves the image is self-consistent;
it doesn't prove Windows will mount it without errors. The first time we
ship `mkfs.ntfs` to real users, the volume needs to survive `chkdsk`.

This doc enumerates the available environments — free, paid, ARM, x86,
local, cloud — and recommends a default per use case.

## TL;DR — pick by use case

| Use case | Environment | Cost |
|---|---|---|
| Automated CI on every PR | **GitHub Actions `windows-latest` runner** | Free for public repos, ~$0.01/min for private |
| Local dev iteration on Apple Silicon | **UTM + Windows 11 ARM Insider Preview** | Free (one-time 1–2 hr setup) |
| Local dev on Intel Mac / Linux | **QEMU + Windows Server 2025 Eval ISO** | Free, 180-day eval, re-armable |
| Single one-off verification | **Azure B-series Windows spot VM** | ~$0.02–0.10 for a 30-min job |
| Reproducing a chkdsk-flagged bug | UTM/QEMU snapshot | Free |

The recommended default is **CI on GitHub Actions + local UTM for
debugging**. Cloud spot VMs only make sense if a contributor without a
Mac/Linux dev box needs Windows access for an investigation.

## Why automation matters here

`fs_ntfs_mkfs` writes ~12 system MFT records, fixup arrays, mapping
pairs, $UpCase, $Bitmap, etc. Any one of those getting a single byte
wrong can produce an image that mounts under our crate (because our
parser is permissive about the same fields the writer got wrong) but
fails on Windows with one of:

- `chkdsk` reports "errors found" — the volume is technically mountable
  but Windows considers it dirty, and a real user run would see "scan
  this drive" prompts repeatedly.
- `Mount-DiskImage` returns `0xC03A0014` (corrupt) — mount fails
  outright.
- The volume mounts but throws errors on first directory enumeration.

Catching all three classes requires running real Windows, not just our
own parser. We want that check to fire automatically on every PR that
touches `vendor/rust-fs-ntfs/src/mkfs.rs` or any of its dependencies.

## Option A — GitHub Actions `windows-latest` (recommended for CI)

`windows-latest` runners are full Windows Server 2022/2025 VMs with
PowerShell, `chkdsk`, and `Mount-DiskImage` built in. Free for public
repos; paid by the minute for private.

### Pricing (2026-01-01 onwards)

- **Free quota** on the Free plan: 2,000 minutes/month including
  Windows runner usage. Pro: 3,000. Team: 3,000. Enterprise: 50,000.
- **Public repos**: free, no quota.
- **Per-minute** beyond quota: ~$0.01/min for `windows-latest`
  (after the December 2025 price cut).

### The raw-image gotcha

`Mount-DiskImage` on Windows accepts VHD, VHDX, and ISO — but **not raw
`.img` / `.dd` files**. Our mkfs writes raw bytes. Two options:

1. **Wrap as VHDX in the Linux/macOS build step**, then upload as
   artifact. `qemu-img convert -f raw -O vhdx out.img out.vhdx` — qemu
   is GPL but we use it only as a build tool, never redistributed in
   our app, so the licence is fine.
2. **Use `ImDisk`** on the Windows runner — pre-installed via
   `choco install imdisk-toolkit`; can mount raw images directly. Adds
   ~30 seconds to runner provisioning.

Option 1 is cleaner: the wrapping happens once, the artifact is
self-describing, and the Windows job has no extra deps.

### How to trigger it (already committed in `vendor/rust-fs-ntfs`)

The workflow is `.github/workflows/ci.yml` in the `rust-fs-ntfs`
submodule. Three trigger paths:

1. **Manual `workflow_dispatch`** (the iteration loop): visit
   <https://github.com/christhomas/rust-fs-ntfs/actions/workflows/ci.yml>
   and click "Run workflow". No tag needed. Use this every time
   you want to see what real chkdsk says about your latest
   `fs_ntfs_mkfs` output.

2. **Tag push** (`v*`): release-time validation. Cut a tag,
   workflow runs automatically alongside the Linux jobs.

3. **Push or PR to main**: only the Linux validation runs (cheap).
   The Windows job is gated behind `startsWith(github.ref,
   'refs/tags/v') || github.event_name == 'workflow_dispatch'` so
   PRs don't burn windows-latest minutes.

Diagnostics from every run are uploaded as a
`ntfs-windows-diag-<run-id>` artifact, containing chkdsk's full
stdout, `Get-Volume` metadata, `fsutil fsinfo` dumps, and the root
directory listing. Compare across commits when chkdsk's verdict
shifts.

### Example workflow (sketch from earlier — superseded by what's committed)

```yaml
name: NTFS mkfs Windows validation
on:
  pull_request:
    paths:
      - 'vendor/rust-fs-ntfs/**'

jobs:
  build-image:
    runs-on: macos-14
    outputs:
      artifact: ntfs-mkfs-image
    steps:
      - uses: actions/checkout@v4
        with: { submodules: recursive }
      - name: Generate NTFS image
        run: |
          cd vendor/rust-fs-ntfs
          cargo run --release --example mkfs_to_file -- /tmp/out.img 64M
      - name: Wrap as VHDX
        run: |
          brew install qemu
          qemu-img convert -f raw -O vhdx /tmp/out.img /tmp/out.vhdx
      - uses: actions/upload-artifact@v4
        with: { name: ntfs-mkfs-image, path: /tmp/out.vhdx }

  chkdsk:
    needs: build-image
    runs-on: windows-latest
    steps:
      - uses: actions/download-artifact@v4
        with: { name: ntfs-mkfs-image, path: . }
      - name: Mount and chkdsk
        shell: pwsh
        run: |
          $img = Mount-DiskImage -ImagePath "$pwd\out.vhdx" -PassThru
          $vol = Get-Volume -DiskImage $img
          $letter = $vol.DriveLetter
          # /scan = read-only check; fails the job if errors found
          chkdsk "${letter}:" /scan
          if ($LASTEXITCODE -ne 0) {
            Write-Error "chkdsk reported errors (exit $LASTEXITCODE)"
            exit 1
          }
          Dismount-DiskImage -ImagePath "$pwd\out.vhdx"
```

Two-job split (macOS build + Windows verify) instead of one Windows job
that does both because we want the Rust toolchain on its native
platform — Windows Rust builds are slower and the macOS runner is
already in our matrix for the regular FSKit extension build.

A `cargo run --example mkfs_to_file` wrapper needs to live in
`vendor/rust-fs-ntfs/examples/`. Trivial: open a file, build a
`BlockDevice` impl that writes through `seek` + `write`, call
`format_filesystem()`. Add this when we wire the workflow up.

## Option B — UTM + Windows 11 ARM Insider Preview (recommended for local dev on Apple Silicon)

UTM is a free Apple Silicon-native QEMU frontend. Windows 11 ARM runs
natively (no x86 emulation) and the Insider Preview ISO is free with a
Microsoft Insider account.

### Setup (1–2 hours, one time)

1. Install UTM from <https://mac.getutm.app> (free; `.dmg` from the
   site, NOT the App Store version which charges a $9.99 tip).
2. Sign in / sign up at <https://www.microsoft.com/en-us/software-download/windowsinsiderpreviewARM64>
   and download the ARM64 Insider ISO (~6 GB).
3. In UTM: New → Virtualize → Windows → point at the ISO. Allocate
   ≥8 GB RAM and ≥64 GB disk for the VM.
4. During Windows setup, install the VirtIO drivers
   from <https://github.com/utmapp/UTM/releases> (Spice guest tools
   ISO) so networking and integration services work.
5. After install, enable file sharing (UTM Shared Directory) so we
   can drop our generated `.img` files into the VM without re-imaging.

### Caveats

- ARM64 Insider Preview is **legally grey for commercial use** —
  Microsoft permits it for development/testing but the EULA isn't
  the standard retail one. Fine for our purposes (validating an
  open-source filesystem driver); revisit if we ever sell support
  contracts.
- Some Windows features that require Hyper-V nested virtualization
  don't work inside UTM. `chkdsk` doesn't care; `bcdedit` and
  Windows Sandbox would.
- Snapshots in UTM let us roll the VM back to a clean state between
  runs — important because `chkdsk /f` modifies the volume; we need
  a snapshot before each test so we can rerun cleanly.

### Workflow

Once the VM exists, validation is:

1. Generate `out.img` on the Mac side (Rust test or example binary).
2. `qemu-img convert -f raw -O vhdx out.img out.vhdx` (qemu installed
   via `brew install qemu`).
3. Drop `out.vhdx` into the UTM shared folder.
4. In Windows: right-click `.vhdx` → Mount; run
   `chkdsk Z: /scan` in PowerShell.

## Option C — QEMU + Windows Server 2025 Evaluation (free local, any host)

Microsoft Evaluation Center ships free 180-day Windows Server 2025
ISOs (Datacenter + Standard editions). Activated by simply running it
within the first 10 days; can be re-armed (`slmgr /rearm`) up to 6
times for a total of ~3 years before requiring a clean reinstall.

Download: <https://www.microsoft.com/en-us/evalcenter/download-windows-server-2025>
(requires Microsoft account sign-in; ISO is ~6 GB; both x86_64 and ARM64
editions available).

This is the fallback for Linux contributors or Intel Macs where UTM's
ARM-native path doesn't apply. QEMU/KVM with `-cpu host -enable-kvm`
gives near-native performance on Linux. On Intel Mac without KVM
acceleration, expect emulation slowdowns — fine for `chkdsk` runs which
are I/O-bound, painful for general Windows use.

## Option D — Azure / AWS / GCP Windows VM (paid, on-demand)

For one-off verifications without setting up local Windows:

- **Azure B1s spot Windows VM**: ~$0.005–0.02/hour depending on region
  and demand. Spin up via `az vm create`, run chkdsk, tear down.
  Total cost for a 30-min session: <$0.05.
- **AWS t3.micro Windows**: ~$0.013/hour compute + ~$0.046/hour
  Windows licence ≈ $0.06/hour. Higher than Azure spot but cheaper
  on-demand than the equivalent Azure tier.
- **GCP e2-small Windows**: similar to AWS.

All three support automation via REST API or CLI; an Azure example:

```bash
az vm create -g rg-dj-validation -n dj-test \
  --image MicrosoftWindowsServer:WindowsServer:2025-Datacenter:latest \
  --priority Spot --eviction-policy Deallocate \
  --size Standard_B1s --admin-username dj --admin-password '...'
# RDP / WinRM in, run chkdsk, capture output
az vm delete -g rg-dj-validation -n dj-test --yes
```

Skip this path unless GitHub Actions free tier is exhausted or a
contributor specifically needs interactive Windows access from a
non-Mac/Linux machine.

## Option E — Windows Sandbox (NOT applicable)

Built into Windows 10/11 Pro+. Free, fast spin-up, but only available
*if you already have a Windows host*. Listed here so we don't waste
time evaluating it: irrelevant for a Mac-only dev team.

## What "validation passed" means

For an `fs_ntfs_mkfs`-produced image, all of:

1. `Mount-DiskImage` succeeds, returns drive letter.
2. `Get-Volume` reports the volume as `Healthy` (not `Repair Needed`).
3. `chkdsk X: /scan` exit code 0 (read-only check, no errors).
4. `chkdsk X: /f` (read-write repair pass) reports zero corrections.
5. A round-trip create-file / list-dir / delete-file via PowerShell
   succeeds.
6. A second `chkdsk /scan` after the round-trip is still clean.

The CI workflow should fail if any of these fail. Step 4 is the
strictest — if `chkdsk /f` finds anything to repair, our mkfs is
producing technically-mountable but subtly-wrong images.

## Open questions / TODO

- **`fs_ext4_mkfs` Linux validation** — corresponding doc for ext4
  side. Easier: `fsck.ext4 -fn out.img` from any Linux box. GitHub
  Actions `ubuntu-latest` runners ship `e2fsprogs` already; the
  workflow is one-line. Should pair with this doc when we wire up
  ext4-side validation.
- **Snapshot-before-mutate in UTM** — codify the workflow so a
  contributor running `chkdsk /f` doesn't dirty their dev VM
  permanently. UTM CLI supports snapshot create/restore; needs a
  helper script in `scripts/`.
- **Add `examples/mkfs_to_file.rs`** to the rust-fs-ntfs crate so the
  CI workflow has a binary to run against. Also useful for local
  debugging without a full FSKit mount.
