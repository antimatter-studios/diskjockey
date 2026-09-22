# CLI tooling: naming, packaging and distribution

Decided 2026-08-31. This records the reasoning as well as the decisions,
because most of the choices below look arbitrary from the outside and
several of them went *against* the obvious answer for a measured reason.

Nothing here is built yet. It exists so that when the formatters land,
the surface they get is decided rather than improvised.

---

## What these are for

**Filesystem operations on a disk image or a raw device, without
mounting it.**

That is the whole pitch, and it is worth stating before the naming
argument, because the naming argument is downstream of it.

On Linux this need barely exists: `mount -o loop disk.img /mnt` and then
`ls`, `cp` and `rm` do the job, because the kernel has drivers for all
of these formats. On macOS it does not. There is no loop mount for ext4,
NTFS, XFS or Btrfs — which is the reason this project exists at all — so
"look inside this image" has no answer short of installing a filesystem
extension, or booting a Linux VM to do it.

These tools read and write the image **directly**. No mount, no kernel
driver, no root, no FSKit extension, no VM. The same code path serves a
raw device (`/dev/diskN`, `\\.\PhysicalDriveN`) as serves a file,
because to a driver both are just bytes at offsets.

Which is also why the read verbs matter more than `mkfs`, and why they
come first: someone can borrow a Linux box to *create* a filesystem, but
"read this disk that will not mount" is the thing they installed this
for, and it is the thing macOS offers nothing for.

### An escape hatch, not a filesystem

Worth being blunt about the scope, because it is what makes the small
verb set defensible rather than merely small: **nobody is meant to do
real filesystem work through these.** Accessing data inside an image
this way is the emergency exit — get the one file out, put the one file
in, read the label, check whether it is dirty — not somewhere to live.

If you want a filesystem, mount one. That is what the FSKit extension is
for, and it is the better tool the moment you have more than an errand:
the kernel gets a cache, `find` and `rsync` and your editor all work, and
nothing is paying process-startup cost per file.

These two are not competitors, they are different modes:

| | use |
|---|---|
| the extension | real work — browsing, editing, building, copying trees |
| these tools | an errand, or a context where mounting is not available: CI, a script, a machine without the extension installed, an image you do not trust enough to mount |

Several things follow, and they are the answers to feature requests that
would otherwise arrive one at a time:

- **No obligation to be fast.** Nobody is running a build out of an
  image. Correct and obvious beats clever.
- **No obligation to be complete.** There is no `find`, no `chmod -R`,
  no recursive copy, and the answer to "why not" is *mount it*. A tool
  that is honestly an escape hatch does not need to grow into a shell.
- **`read` and `write` really are enough**, because the unit of work is
  a file, not a session.

It also explains the ordering note further down rather than leaving it
as a preference: the read verbs come first because **retrieval is the
whole use case**. "Get my data off this disk that will not mount" is the
errand people actually have.

---

## The problem

Given that, the question is what to call them — and the Linux toolset is
an object lesson. It has one consistent name and dozens of
inconsistent ones. Four filesystems, four separate vocabularies for the
same concepts:

| concept | ext4 | xfs | btrfs | ntfs |
|---|---|---|---|---|
| create | `mkfs.ext4` | `mkfs.xfs` | `mkfs.btrfs` | `mkfs.ntfs` |
| check | `fsck.ext4` | `xfs_repair` | `btrfs check` | `ntfsfix` |
| inspect | `dumpe2fs` | `xfs_info` | `btrfs fi show` | `ntfsinfo` |
| label | `e2label` | `xfs_admin -L` | `btrfs fi label` | `ntfslabel` |
| resize | `resize2fs` | `xfs_growfs` | `btrfs fi resize` | `ntfsresize` |

Only `mkfs.*` is consistent, and only because a dispatcher forced it.
Everything else is four unrelated projects' folklore, accumulated over
decades.

We are writing all of these from scratch, in one family, over a shared
`fs-core`, with C APIs that already expose the same verbs. There is no
reason to reproduce the fragmentation.

---

## Why we write our own rather than porting

Worth recording because it is the question everyone asks first.

The *format* is host-independent — a formatter opens a file, writes
bytes, closes it, and no kernel driver is involved. That is why our Rust
formatters already run on macOS and produce images Linux mounts.

The *upstream programs* are not portable as written:

- there is no macOS package for the xfs userspace tools at all;
- the btrfs userspace formula is `depends_on :linux` and pulls in
  `systemd` (libudev) and `util-linux`.

They are built against Linux headers, Linux ioctl numbers and `/sys`
device enumeration; the xfs userspace library is the kernel's own XFS
code shimmed out. Porting is a project, not a `./configure && make`.

And a successful port still would not ship, for two independent reasons
either of which is fatal on its own:

- **Licence.** Both are GPL-2.0. We do not link GPL.
- **Sandbox.** A MAS app cannot `NSTask` a bundled executable.
  Formatting works today because it is a framework call into the FSKit
  extension.

Running them in a VM at runtime fails both tests as well. Where they
*are* useful is as **test oracles at arm's length** — a separate
process, no linking, no copying. That is the contract `mkfs_ext4` has
with the ext4 checker and `mkfs_erofs` has with the erofs checker in CI,
and it is unaffected by any of the above.

---

## Naming

### The dot means "dispatcher backend", and the direction matters

`mkfs.ext4`, `fsck.xfs` and `mount.nfs` are all `<verb>.<filesystem>`.
`mkfs(8)` literally builds the string `mkfs.xfs` and execs it. The dot
is a separator a front-end constructs, not a style choice.

So `<filesystem>.<verb>` — `btrfs.amctl` — is backwards, and reads as a
misuse of the convention rather than a use of it. Anything of ours that
is not in a dispatcher family uses a hyphen instead.

Evidence for how narrow the convention is: e2fsprogs ships **30
binaries, exactly 6 dotted**, and those 6 are precisely
`mkfs.ext{2,3,4}` and `fsck.ext{2,3,4}`. Every other binary in the same
package uses that package's house style. Note also `mksquashfs`,
`mkswap` and `mkisofs` — "always dot" would be wrong.

### The verb goes before the dot, and every tool has the same shape

```
<verb>.<fs>  <target>  [args…]
```

```
mkfs.ext4  disk.img
fsck.ext4  disk.img
fs.ext4    disk.img ls /the/subdirectory
fs.ext4    disk.img read /path/to/file        # stdout, or -o out.bin
fs.ext4    disk.img write /path/to/file < input
fs.ext4    disk.img mkdir /new/dir
fs.ext4    disk.img get label
fs.ext4    disk.img set label "Backup"
fs.ext4    disk.img resize 20G --force
```

### Only two verbs are dotted, and the boundary is not arbitrary

Earlier drafts dotted the file operations too — `read.ext4`,
`write.ext4`, `ls.ext4`, `mkdir.ext4` and so on. The objection that
killed it is that **there is no principled place to stop.** If
`mkdir.ext4` earns a name, so do `stat.ext4`, `du.ext4`, `find.ext4`,
`chmod.ext4`, `truncate.ext4` and `df.ext4` — every one exactly as
defensible as the last, and the list becomes a snapshot of whatever
someone thought of that week. Reinventing the Linux command set, one
plausible verb at a time, is the failure mode this document opens by
criticising.

The line that does hold is between a closed set and an open one:

- **`mkfs` and `fsck` are closed.** Two whole-filesystem lifecycle
  actions, with names everyone already types and that other tools expect
  — `mount -t`, the `fsck` front-end. They stay dotted.
- **Operations on paths inside a filesystem are open-ended.** There is
  no set to enumerate, so they go under one tool that can be asked what
  it supports.

An earlier draft defended the dotted verbs on the grounds that a missing
link signals missing support — no `write.erofs` because EROFS is
read-only. That does not survive contact with what the shell actually
prints: a missing link gives **`command not found`**, which reads as
"you did not install it", not "this filesystem cannot do that". The
signal was ambiguous in the worse direction.
`fs.erofs disk.img write …` answering *"EROFS is read-only"* is strictly
better, and it is the same reason properties could not be dotted:
support is per-operation, and only the tool knows.

### `read`/`write`, not `cat`

An earlier draft had `cat.ext4`, and the asymmetry is probably why this
set had no write verb at all until someone noticed: `cat` has no natural
inverse. `tee.ext4` is not a name anyone would guess, so the write side
simply never got named — while `am-fs-ext4`, `am-fs-ntfs` and
`am-fs-xfs` all have write paths, and `rust-ntfs` already ships `write`,
`touch`, `mkdir`, `rm`, `rmdir`, `rename` and `link`.

Two smaller objections point the same way. `cat` means *concatenate*,
and we would only ever pass one file. And it bakes the destination into
the name: the operation is "read this file", of which stdout is one
possible sink alongside `-o` or a pipe.

`ls` survives the same test — listing a directory is exactly what `ls`
means. `cat` does not.

The precedent argument is real and does not carry it: `ntfscat` ships
and `debugfs` has a `cat` command. But this scheme's whole claim is one
uniform vocabulary rather than twenty years of drift, and borrowing
shell idioms piecemeal is how that drift begins.

The namespace verbs the drivers already implement follow the same rule —
name the operation, in matched pairs where one exists:

```
mkdir.ext4  disk.img /new/dir
rm.ext4     disk.img /path
mv.ext4     disk.img /from /to
ln.ext4     disk.img /target /link
touch.ext4  disk.img /path
```

**The target is always the first argument.** `mkfs.*` and `fsck.*`
already work that way, so extending it costs nothing and means the disk
is never in a different position depending on which tool you reached
for.

Rejected alternative: a *category* before the dot with verbs as
subcommands (`inspect.ext4 ls …`). It reintroduces exactly the
inconsistency we are removing — some tools would take a subcommand and
some would not, inside one namespace.

### Names are free; PATH entries are not

Three names per filesystem — `mkfs.<fs>`, `fsck.<fs>`, `fs.<fs>` — so
four filesystems is twelve entries. Still **one multi-call binary
dispatching on `argv[0]`**, installed under each name, the way busybox
and e2fsprogs do it (which is why an installed `mkfs.ext4` shows a link
count of 2). `fs.<fs>` then dispatches its own subcommands normally.

The earlier draft dotted every verb, which would have been 4 × ~10 ≈ 40.
The implementation cost really is near zero — that was never the
objection — but **PATH is a shared global namespace and the entries are
not free there**:

- forty tab-completion hits on `r<TAB>`, `w<TAB>`, `l<TAB>`;
- forty chances to collide with another project's tool. This document
  already declines a bare `mkfs` because it is "the worst possible
  collision candidate", and that risk scales with every name claimed;
- forty things to remove cleanly on uninstall.

Twelve names that each mean something beat forty that mostly restate
`ls`.

### The pipe supplies the verbs we did not write

This is what makes the small set *sufficient* rather than merely tidy,
and it is why the slippery slope has a floor. `read` emits raw bytes on
stdout and `write` consumes them on stdin, so the shell already owns
every operation we declined to name:

```sh
fs.ext4 img read /var/log/syslog | grep -i error
fs.ext4 img read /etc/passwd | wc -l
tar cf - ./dir | fs.ext4 img write /backup.tar
fs.ext4 img get --json | jq -r .label
```

No `grep.ext4`, no `tee.ext4`, no `wc.ext4`, no `head.ext4` — asking for
them is asking us to reimplement tools that already work, on the wrong
side of a pipe.

Copying a file **between two different filesystems** falls out of the
same property, with no `cp` verb existing anywhere:

```sh
fs.ext4 src.img read /data.bin | fs.ntfs dst.img write /data.bin
```

It also settles the output-format split from the other direction:
metadata composes with `jq`, file content composes with everything else.
Each half gets the format its ecosystem expects, which is why the
carve-out is not an inconsistency to apologise for.

### No `mkfs` dispatcher of our own

Declining it *removes* risk rather than just declining a feature. A bare
`mkfs` on PATH is the worst possible collision candidate — it shadows
the front-end everything else on a Linux box routes through — for
almost no ergonomic gain, since `mkfs.ext4 disk.img` is already shorter
than `mkfs -t ext4 disk.img`. It stays available later; adding it is
purely additive.

### No generic `dj` binary

Rejected after being proposed twice, on the grounds that it is a **layer
confusion**: the CLI tools are the domain layer and are useful to
someone who never installs the app, while DiskJockey is the brand layer
on top. `udisksctl` is not called `gnome-udisksctl` even though GNOME is
its main consumer. `dj` is also a poor command name in its own right —
two letters, says nothing about disks, and collides readily.

Nothing needs to replace it. The identification step already exists as a
domain-named tool:

```
diskprobe /dev/disk4          → ext4
ls.ext4   /dev/disk4 /etc
```

Two commands, both honest, and nothing is ever inferred wrongly on a
mutating verb.

**Package names are a different layer.** `diskjockey-btrfs` as a
*formula* is fine — packages are routinely vendor-named and no formula
name lands on anyone's PATH. Only what lands in `bin/` must be
domain-named.

### Cargo cannot produce a dotted name

Tested: `error: invalid character '.' in crate name`. So the cargo
target keeps an underscore (`mkfs_ext4`) and the **release step**
renames it, so the published tarball carries the real name. Renaming in
the formula instead would leave the build-system artefact visible in a
public artifact.

---

## The interface contract

Names are the visible half. The half that matters is that all four
filesystems answer the same way.

1. **Same verb set.** Every filesystem implements every verb. A verb
   that is not yet supported returns "not implemented" rather than the
   name being absent from the *interface* — so a script moved between
   filesystems fails loudly instead of silently meaning something else.
   (The *link* may be absent; that is the packaging-level signal. The
   two are different layers.)

2. **Same flags for the same concepts** — `--label`, `--size`,
   `--force`, `--json`, `--quiet`. This is where Linux fails worst: `-L`
   happens to agree across the three formatters, but `-f`, `-n` and `-b`
   all diverge.

3. **Same output envelope.** Common fields at the top, filesystem
   specifics nested:

   ```json
   { "fs": "ntfs", "label": "…", "total_bytes": …, "free_bytes": …,
     "block_size": …, "dirty": false,
     "ntfs": { "mft_total_records": …, "serial_number": "…" } }
   ```

   This is not invented. It is already the shape ntfs returns — its
   volume info carries `label`, `total_size`, `free_clusters`,
   `cluster_size`, `dirty` alongside `mft_*`, `serial_number` and
   `ntfs_version_*`. It needs naming and enforcing, not designing.

4. **Same exit codes.** `fsck.*` follows the scheme scripts already
   depend on — 0 clean, 1 corrected, 4 uncorrected, 8 operational error.

5. **Properties are a namespace, and they get ONE tool with
   subcommands rather than a dotted verb each.** Linux invented
   `e2label`, `xfs_admin -L`, `ntfslabel`, `tune2fs -U` and
   `btrfs filesystem label` for one concept. Instead:

   ```
   fs.ext4 disk.img get label
   fs.ext4 disk.img set label "Backup"
   fs.ntfs disk.img set dirty false
   fs.ext4 disk.img get                # list every key, with types
   fs.ext4 disk.img resize 20G --force
   ```

   This is the one place the dotted scheme is dropped, and the reason is
   the same one that justifies it everywhere else. The scheme's real
   payoff is that **partial support shows up as a missing link** — if
   xfs cannot be checked, `fsck.xfs` does not exist and tab-completion
   says so. That signal cannot work for properties, because support is
   per-KEY, not per-verb: `set.xfs` existing would tell you nothing,
   since it might accept `label` and refuse `uuid`.

   So the split is a rule rather than an exception:

   - **one specific action** gets its own dotted name — `mkfs`, `fsck`,
     `read`, `write`, `ls`, `mkdir`, `rm`, `mv`, `ln`, `touch`. Support
     is per-verb, so the link carries it.
   - **a namespace of operations over a keyspace** gets one tool with
     subcommands. Support is per-key and has to be discovered by
     asking, which is what `fs.<fs> <target> get` with no key does.

   **JSON by default; `--text` for humans.** These tools exist to be
   driven — the automated test pipeline is the primary consumer, not
   someone at a prompt — so the default is the format that consumer
   wants, and the escape hatch points the other way.

   ```
   fs.ext4 disk.img get              # { "label": "Backup", ... }
   fs.ext4 disk.img get label        # { "label": "Backup" }
   fs.ext4 disk.img get label --text # Backup
   ```

   Two things JSON buys that text cannot. Values are unambiguous — a
   label with a trailing space or an embedded newline, a UUID as bytes,
   a null all survive, where bare text quietly mangles them. And errors
   are structured: `{"error": "...", "code": 4}` beats parsing stderr,
   which for a pipeline is worth more than the query output is.

   **One carve-out, and it is forced rather than chosen:** `read` writes
   FILE BYTES to stdout and `write` consumes them on stdin. Wrapping
   arbitrary binary in JSON means base64, which makes the ordinary
   `read.ext4 disk.img /path > out.bin` both wrong and expensive. So:

   | | default |
   |---|---|
   | `get` `info` `ls` `fsck` `mkfs` `resize` `set` | JSON |
   | `read` (stdout), `write` (stdin) | raw bytes |

   The rule is **metadata is JSON, file content is raw**, which is easy
   to remember because it follows what the data is.

   `ls` gains the most: name, size, mode and mtime as fields rather
   than columns to parse — the shape that otherwise breaks silently on a
   filename containing a space.

   The cost, stated plainly: `$(fs.ext4 disk.img get label)` now yields
   `"Backup"` WITH QUOTES, so shell one-liners need `--text` or
   `jq -r`. That is the trade — worse at a prompt, better for everything
   driving these programmatically.

   **This flipped twice while being written**, so the deciding argument
   is recorded rather than left to whoever speaks last. The two cases
   are close on convenience and NOT symmetric on failure:

   - text default, automation forgets `--json` → a script parses
     `Backup Volume` and keeps `Backup`, or splits a filename on a
     space. Wrong, plausible-looking, silent.
   - JSON default, a person forgets `--text` → they see quotes.
     Immediate, harmless, self-correcting.

   One default makes a human mildly annoyed; the other makes a script
   quietly wrong.

   **The tripwire for revisiting it:** if the tools end up mostly typed
   by hand rather than driven, the premise is gone and this should flip.
   It is a default, not an architecture — one line and this paragraph.

   `tune.<fs>` was considered for the name, since `tune2fs` is precisely
   this tool. It implies write-only, and half of this is reading.
   `btrfs filesystem …` made the same call.

   A new property is a new key, not a new command. ntfs already
   implements `set_volume_label`, `read_volume_label`, `is_dirty` and
   `clear_dirty`, so this has working code behind it today.

   **`set size` does not exist; `resize` does.** An earlier draft folded
   resizing into `set`, on the grounds that size is a property. Size is
   a property to READ. Changing it is not a write of that property — it
   is a job that happens to end with the number being different, and it
   relocates data, takes minutes and can fail partway.

   The test that separates them is whether the operation needs anything
   beyond the value:

   ```
   fs.ext4 disk.img set label "Backup"                    # a value
   fs.ext4 disk.img resize 20G --force --no-shrink --dry-run
   ```

   `set` can be a uniform setter precisely BECAUSE every key takes one
   value and nothing else. The moment one key needs a force flag, a
   grow/shrink distinction and a dry run, `set` becomes a generic verb
   carrying per-key flags — which is the shape this whole scheme exists
   to avoid.

   The asymmetry is honest rather than awkward. Plenty of properties are
   readable and never writable (`block.size`, on every filesystem);
   size is the case where the read and the write are different kinds of
   thing. So `get size.total` answers, `get` reports size as
   non-writable, and the help names `resize` as what to use instead.

   **`info` and `get` are the same tool under two names.** An earlier
   draft justified keeping them apart by claiming different output
   contracts — `info` for the whole envelope, `get` for one bare value.
   That was wrong. A key argument and the `--text` flag this document
   already mandates cover both in one verb:

   ```
   info.ext4 disk.img                 # whole envelope
   info.ext4 disk.img label --text    # one bare value
   ```

   What actually argues for two names is narrower, and it is
   discoverability against symmetry. `info` is the conventional name —
   `xfs_info`, `ntfsinfo`, `dumpe2fs` — and is what someone asking "what
   IS this filesystem" reaches for. But `get`/`set` is a pair, and
   `info`/`set` is not: a reader who has learnt `set.ext4 disk.img label
   X` will guess `get.ext4 disk.img label`.

   The multi-call design settles that cheaply. One binary dispatching on
   `argv[0]` means a second name is **one more symlink and no code at
   all** — so both exist, with one implementation behind them. That is
   not the compromise it would be if these were separate binaries; it is
   the same property that makes the whole verb matrix affordable.

**Enforcement:** the verb set, flag vocabulary and output envelope live
in a shared crate that each filesystem *fills in*. A new filesystem then
cannot invent its own dictionary, because there is nowhere to put one.
This is the same move as the rest of the family — one definition rather
than four copies that agree by inspection. The Linux toolset is exactly
what four copies look like after twenty years of drift.

---

## Distribution

### Homebrew, not direct download

Quarantine is applied by browsers and AirDrop, not by curl, so a
brew-installed tarball runs **without notarisation**. A direct download
from the website would be quarantined and would need it. That decides
the channel on its own.

The tap already exists: `antimatter-studios/homebrew-tap`.

### One tap, formulae named per repo

The binaries are built and released from each filesystem's own repo; the
*formulae* all live in the one existing tap. Six taps would mean six
`brew tap` commands before anything is installable.

Formulae are named for the **repo**, not for one binary —
`diskjockey-btrfs`, not `mkfs-btrfs` — because a repo grows tools and a
binary-named formula goes stale the moment it ships a second one. The
ecosystem agrees: e2fsprogs is one formula shipping 30 binaries.

House idiom for this tap is **prebuilt per-platform tarballs from GitHub
Releases** with sha256 (see `chore.rb`), not build-from-source. Tarballs
are named for the crate — `am-fs-btrfs-0.6.0-darwin-arm64.tar.gz` —
with the dotted binary inside: artifact named for the source, binary
named for the user, and no extra dot for a filename parser to trip over.

Every repo's current `release.yml` is crates.io publish only, so emitting
binary tarballs is new work in each. It should be **one reusable
workflow** called with a binary name, not seven copies of the same YAML.

### Linking: macOS yes, Linux keg-only

| platform | linked | why |
|---|---|---|
| macOS | yes | nothing to shadow — no `mkfs` dispatcher exists, and no `mkfs.*` ships in the base system |
| Linux | **keg-only** | the real tools exist and should win by default |

The Linux hazard is not hypothetical and is not solved by declining to
write a dispatcher: `mkfs -t ext4` works on any Linux box because
util-linux's `mkfs` is already there, and it resolves `mkfs.ext4` off
PATH regardless of our intentions. Leaving it to PATH ordering means the
outcome depends on how a user's shell happens to be configured, and the
failure mode is someone formatting a real disk with our implementation
while believing they ran the mature one. That is a race worth not
entering.

Precedent, in our own dependency tree: Homebrew ships e2fsprogs
`keg_only`, which is why `mkfs.ext4` is present on a Mac with it
installed and still absent from PATH.

It is a default, not a lock-in — `brew unlink` and `brew link --force`
both work. And you can add a name later; you cannot take one away, so
ship the minimal set.

### The umbrella

`diskjockey-tools` (preferred over `diskjockey-cli`, which reads as
"the CLI version of DiskJockey" — a thing we are explicitly not
building) is a pure meta-formula: `depends_on` lines and no binaries of
its own.

It keeps one job on Linux: because the leaves are keg-only there, it
collects symlinks into a single directory so there is **one** PATH line
instead of six. Symlink to each leaf's `opt_bin`, never to the Cellar
path — `opt` follows the current version, so the umbrella survives leaf
upgrades untouched.

It must be keg-only on Linux too. A linked umbrella symlinking
everything would put `mkfs.ext4` back on PATH and undo the whole reason
the leaves are keg-only.

```console
# macOS
brew install antimatter-studios/tap/diskjockey-tools     # done

# Linux
brew install antimatter-studios/tap/diskjockey-tools
export PATH="$(brew --prefix diskjockey-tools)/bin:$PATH"
```

---

## The `diskjockey` control CLI — separate, and last

Distinct from everything above: a CLI that talks to the **app**, not to
filesystems. Branded correctly, because the brand is its subject —
`docker` controls the Docker daemon, `systemctl` controls systemd.

The transport already exists. `com.antimatterstudios.diskjockey.agent`
is a registered Mach service and `DJAgentClient.swift` already connects
to it with `NSXPCConnection(machServiceName:)`. It vends `attachImage`,
`detachDevice`, `mountFSKit` and `probeImage` — all operations a
sandboxed app cannot perform itself, which is why the agent exists. The
`diskjockey://` URL scheme is the other channel but is fire-and-forget,
so it is useless for scripting.

Two properties make it worth building:

- the agent is a **LaunchAgent**, so a scripted call works whether or
  not the GUI is running — the CLI talks to the same service the GUI
  talks to, rather than driving the GUI;
- it can answer things nothing else can. FSKit extension enable-state is
  read via `pluginkit`, which the sandboxed app cannot do — so there is
  currently no way to ask from a script at all.

**One constraint to solve first.** Both ends call
`setCodeSigningRequirement` — the client validates the agent *and* the
agent validates its caller. A brew-installed `diskjockey` binary is
rejected unless it is Developer ID signed and the agent's requirement
admits it (Team ID rather than the app's bundle ID alone).

That produces an asymmetry which is itself a reason to keep these as
separate packages:

| | signing | pipeline |
|---|---|---|
| `mkfs.*`, `fsck.*`, `diskprobe` | none — nothing validates them | plain cross-compile + tarball |
| `diskjockey` | Developer ID required | signed build, cert in CI |

The filesystem tools stay trivially portable; only the control CLI
inherits Apple's machinery.

---

## Current state

| repo | ships today | planned |
|---|---|---|
| rust-fs-ext4 | `mkfs_ext4` | rename to `mkfs.ext4` |
| rust-fs-erofs | `mkfs_erofs` | rename to `mkfs.erofs` |
| rust-fs-ntfs | `rust-ntfs` (**test-harness driver**) | `mkfs.ntfs` added |
| rust-fs-squashfs | `lssquashfs` | fold into the verb scheme |
| rust-blk-probe | `diskprobe` | already correctly named |
| rust-img-qcow2 | `qcow2_tool` | rename — `_tool` says nothing |
| rust-img-vhd | `vhd_tool` | rename |
| rust-fs-xfs | — | **mkfs deferred — see below**; read verbs first |
| rust-fs-btrfs | — | **mkfs deferred — see below**; read verbs first |

### Why `mkfs.xfs` and `mkfs.btrfs` are deferred — measured 2026-09-04

Neither crate can format, and that is not a wrapper away. Worth stating
precisely, because both look far closer than they are.

`am-fs-xfs` has `super_write`, `group_write`, `log_write`, `create`,
`alloc_btree`, `inode_btree` and `dir_write`. `am-fs-btrfs` has
`super_write`, `tree_write`, `extent_write`, `commit` and `transaction`.
Read as a file list, that is most of a formatter.

It is not, because **every one of those modules edits a filesystem that
already exists.** `group_write`'s public surface is `rebuild_leaf`,
`rebuild_inode_leaf`, `changed_chunks`, `restamp_crc` — each takes the
buffer it is amending. `create` makes a file inside a transaction on a
mounted volume. Nothing in either crate computes an *initial layout*:
allocation-group count and size, empty allocation and inode btrees, the
root inode, an initialised log.

The one exception is the XFS superblock, modelled field by field and
buildable from nothing. That is the first of roughly six pieces, not
the last.

Confirming it from the other direction: neither crate has a
`format_filesystem` or `build_image` entry point. `am-fs-ext4`,
`am-fs-ntfs` and `am-fs-erofs` each do, and their `mkfs.*` binaries are
thin wrappers around exactly that one function.

**So: defer.** The ordering note below is the second reason rather than
an afterthought. `ls.xfs`, `read.xfs` and `info.xfs` are wrappers over
`mount`, `dir_*`, `read_file`, `stat` and `get_volume_info` — all of
which exist in both crates today. `mkfs.xfs` is a new subsystem.
Someone can borrow a Linux box to *create* an XFS filesystem; they
installed this to read one that will not mount.

`rust-ntfs` is **not** a formatter: it is the driver the
`fs-windows-test-harness` config invokes to exercise write paths inside the
Windows VM, with eleven subcommands. Renaming it would churn the harness
config, the VM protocol docs and the test matrix for no user-facing
gain. Add a separate thin `mkfs_ntfs` calling the same
`format_filesystem()` entry point, and leave `rust-ntfs` unshipped.

Ordering note: `fsck` and the read verbs are **cheaper than `mkfs` and
arguably more valuable**. Every crate already exposes `mount`, `dir_*`,
`read_file`, `stat` and `get_volume_info`, and ext4 and ntfs already
have `fsck` implementations. Someone can borrow a Linux box to *create*
a filesystem; "read this disk that will not mount" is why they installed
DiskJockey, and macOS offers nothing for it.

## Still open

- House style for tools with no dispatcher convention — `lssquashfs`,
  `qcow2_tool`, `vhd_tool`. The tap leans short and lowercase
  (`chore`, `ddt`, `dotman`, `tacli`); `diskprobe` already fits.
- Whether the image formats (qcow2, vhd, vhdx, vmdk) join the same verb
  scheme — `info.qcow2`, `ls.qcow2` — or stay separate tools.
