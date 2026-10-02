# CLI tooling: naming, packaging and distribution

Decided 2026-08-31, and brought into line with the owner's decisions on
the tracker (#235) on 2026-10-02. This records the reasoning as well as
the decisions, because most of the choices below look arbitrary from the
outside and several of them went *against* the obvious answer for a
measured reason.

Most of it is built: every filesystem and disk-image driver now ships its
tools, released with the library and installable from the tap. What is
shipped, and what is still open, is in [Current state](#current-state).

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
process, no linking, no copying. That is the contract `mkfs.ext4` has
with the ext4 checker and `mkfs.erofs` has with the erofs checker in CI,
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

Namespace verbs follow the same rule — name the operation, in matched
pairs where one exists — and, like every per-path operation, they are
subcommands of `fs.<fs>`, not dotted names:

```
fs.ext4  disk.img mkdir /new/dir
```

`mkdir` is the one namespace verb in the shipped set. The drivers can
do more (`rust-ntfs` has `rm`, `rename`, `link` and `touch`), and should
one ever be added it is named the same way — `rm`, `mv`, `ln`, `touch`
— as a subcommand.

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
blk.probe /dev/disk4                          → ext4, partition at 1048576
fs.ext4   --offset 1048576 /dev/disk4 ls /etc
```

Two commands, both honest, and nothing is ever inferred wrongly on a
mutating verb. `--offset <bytes>` is on every `fs.<fs>`, so a partition
inside a whole-disk image is addressable from `blk.probe`'s `start`.

`blk.probe` itself is **an internal tool of this application**, staged
inside the app bundle: it has no formula and is not part of the public
`fs.`/`img.` families (owner decision, #235).

**Package names are a different layer**, and no formula name lands on
anyone's PATH. A formula is named for the **repository** —
`rust-fs-btrfs` — see [Distribution](#distribution).

### Cargo cannot produce a dotted name

Tested: `error: invalid character '.' in crate name`. So the one cargo
target in each repository is the multi-call binary, named for the
**repository** (`rust-fs-ext4`), and the dotted names are relative
symlinks to it that the **release step** makes. The published tarball
carries the real names and nothing cargo calls anything. Renaming in
the formula instead would leave the build-system artefact visible in a
public artifact.

The repository name is also installed on PATH, as the one name nothing
else can shadow, and it carries `<repo> doctor`: it resolves each dotted
name on PATH, checks through `--version` that the one found is ours, and
prints the winner and the exact fix if not. Every repository's `cli`
suite runs it first and fails with its output if anything is shadowed.

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
   `--force`, `--json`, `--text`, `--quiet`, `--offset`. This is where
   Linux fails worst: `-L` happens to agree across the three formatters,
   but `-f`, `-n` and `-b` all diverge. Every tool parses with clap,
   behind a `cli` cargo feature with `required-features` on the binary,
   so the static libraries the app links gain nothing; `--help` carries
   an example per subcommand.

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

   - **a whole-filesystem lifecycle action** gets its own dotted name —
     `mkfs` and `fsck`, and nothing else. Support is per-verb, so the
     link carries it.
   - **everything else** — the per-path operations (`ls`, `read`,
     `write`, `mkdir`) and the keyspace (`get`, `set`, `info`) — is a
     subcommand of `fs.<fs>`. Support is per-key or per-path and has to
     be discovered by asking, which is what `fs.<fs> <target> get` with
     no key does, and an unsupported verb answers with a structured
     error rather than `command not found`.

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
   `fs.ext4 disk.img read /path > out.bin` both wrong and expensive. So:

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
   fs.ext4 disk.img info              # whole envelope
   fs.ext4 disk.img info label --text # one bare value
   ```

   What actually argues for two names is narrower, and it is
   discoverability against symmetry. `info` is the conventional name —
   `xfs_info`, `ntfsinfo`, `dumpe2fs` — and is what someone asking "what
   IS this filesystem" reaches for. But `get`/`set` is a pair, and
   `info`/`set` is not: a reader who has learnt `fs.ext4 disk.img set
   label X` will guess `fs.ext4 disk.img get label`.

   Subcommands settle that cheaply: a second name is **one more alias
   and no code at all** — so both exist, with one implementation behind
   them.

**Enforcement:** the verb set, flag vocabulary and output envelope live
in a shared crate that each filesystem *fills in*. A new filesystem then
cannot invent its own dictionary, because there is nowhere to put one.
This is the same move as the rest of the family — one definition rather
than four copies that agree by inspection. The Linux toolset is exactly
what four copies look like after twenty years of drift.

**Where that crate is: `am-fs-core`, feature `cli`.** The plumbing every
tool shares — dispatch on `argv[0]`, the `<tool> (<crate>) <version>`
line, `<repo> doctor`, the JSON result and the `{"error", "code"}` failure
with their exit statuses, `--json`/`--text`, and `generate
names|man|completions` — is the module `fs_core::cli`, behind the `cli`
cargo feature of `am-fs-core`. A repository describes its tools once, as a
`cli::Family` of `cli::Tool`s, and calls `cli::main`. It turns on
`am-fs-core/cli` only under its own `cli` feature, next to the
`required-features` on its binary, so its static library gains nothing.

**Do not copy it into a repository.** It began as `src/cli/common/`,
copied by hand into each driver, and the copies drifted within weeks:
one `doctor` drained a long `--version` answer while the rest stalled on
it, one entry point aligned its help examples, and only some could write
man pages. A fix to the plumbing is a change to `am-fs-core` and a
release, then a pin bump in each repository — never an edit to a local
copy (antimatter-studios/rust-fs-core#177).

---

## Disk images: `img.<fmt>`

The container formats (qcow2, vhd, vhdx, vmdk) **join the interface
contract under their own family name**, `img.<fmt> <image> <subcommand>`
(owner decision, #235). They are not `fs.*` tools and they get no
per-verb dotted names.

- **The same shape as `fs.<fs>`:** target first, JSON metadata by
  default with `--text`, raw bytes for content, structured errors,
  "not implemented" answers, `--version`, `doctor`, the shared flags and
  envelope (`format`, `virtual_size`, `block_size`, `backing`, `dirty`,
  then format-specific keys nested).
- **A verb set that fits a block address space:** `info`/`get [key]`;
  `read [--offset N] [--length N]`, which with no range streams the whole
  virtual disk as raw bytes, so conversion to raw is just reading;
  `write --offset N` from stdin; `create <size>` where the crate can
  create; `resize` and `set` answer "not implemented". No `ls` and no
  `mkdir`: an image has no paths.
- **Rejected: `info.qcow2`, `ls.qcow2`**, for the reason the dotted file
  verbs were rejected above — there is no principled place to stop, and
  a missing link reads as "not installed" rather than "not supported".
- **Rejected: teaching `fs.<fs>` to open containers**
  (`fs.ext4 disk.qcow2 ls /`). A filesystem crate would then link
  container readers, against the rule that each crate is its own archive.
  Composition goes through a raw image instead:

  ```sh
  img.qcow2 d.qcow2 read -o d.raw && fs.ext4 d.raw ls /
  ```

  The cost, stated plainly: a temporary raw file as large as the virtual
  disk. For an escape hatch that is acceptable. If it proves not to be,
  the answer is a separate composing tool, not bundling.

The tools these replace — `qcow2_tool`, `vhd_tool` and `lssquashfs` —
were never in a tarball or a formula, so there are no transition links;
each repository's CHANGELOG names the replacement.

---

## Distribution

### Homebrew, not direct download

Quarantine is applied by browsers and AirDrop, not by curl, so a
brew-installed tarball runs **without notarisation**. A direct download
from the website would be quarantined and would need it. That decides
the channel on its own.

The tap already exists: `antimatter-studios/homebrew-tap`.

### One tap, formulae named for the repository

The binaries are built and released from each driver's own repository;
the *formulae* all live in the one existing tap. Eleven taps would mean
eleven `brew tap` commands before anything is installable.

Formulae are named for the **repository**, not for one binary —
`brew install antimatter-studios/tap/rust-fs-btrfs`, not `mkfs-btrfs` —
because a repository grows tools and a binary-named formula goes stale
the moment it ships a second one. The ecosystem agrees: e2fsprogs is one
formula shipping 30 binaries. (An earlier draft named them
`diskjockey-<fs>`; that is superseded by the owner's decision on #235.)

House idiom for this tap is **prebuilt per-platform tarballs from GitHub
Releases** with sha256 (see `chore.rb`), not build-from-source. Tarballs
are named for the crate — `am-fs-btrfs-0.8.0-darwin-arm64.tar.gz` —
with the tools inside: artifact named for the source, binary named for
the user, and no extra dot for a filename parser to trip over. Targets:
`darwin-arm64` and `linux-x86_64`.

### The tarball is the contract; the formula is a template

Every repository's tarball is an install prefix with one layout:

```
bin/<repo>                                  the multi-call binary, the real file
bin/<dotted name>                           -> <repo>, a relative symlink, per tool
share/man/man1/, share/man/man8/            section 8 for mkfs.*/fsck.*, 1 for the rest
share/zsh/site-functions/
share/bash-completion/completions/
share/fish/vendor_completions.d/
share/<repo>/CAVEATS                        at most four lines, shown after install
LICENSE
```

The man pages and completions are generated by the binary itself
(`<repo> generate man|completions`, through `clap_mangen` and
`clap_complete`), so a page cannot describe a flag the program does not
take. Each repository's CI builds the tarball on every pull request and
checks the layout, so a release is not the first time it is put
together.

Every formula is then the same template — `prefix.install Dir["*"]`,
caveats read from `share/<repo>/CAVEATS` — and the tap's CI checks each
`rust-fs-*`/`rust-img-*` formula against it. The tap only syncs
version, URL and sha256.

### Released with the library, attested, synced by hand

- **The CLI rides the library's release, at the same version.** A
  manually pushed `v*` tag runs the repository's `release.yml`, which
  publishes the crate and attaches the tarballs. There is no separate
  trigger for the tools.
- **Every tarball is attested** with build provenance
  (`actions/attest-build-provenance`). Before a formula update merges,
  each asset is checked with

  ```
  gh attestation verify <tarball> --repo <owner>/<repo> \
      --signer-workflow <owner>/<repo>/.github/workflows/release.yml
  ```

  plus its sha256 against the formula and `--version` naming the
  expected crate and version. That proves the binary was built by that
  repository's release workflow from a commit in that repository; it
  does not protect against a malicious commit reaching the tag, which
  review and branch protection still carry.
- **The tap sync stays human-gated.** A release only publishes the
  tarballs. The formula moves when the tap's sync workflow is run by
  hand and its pull request merged; `brew update` then picks it up.
  Nothing in a driver repository triggers the tap.

The release jobs are still **one copy per repository**. The design
asked for one reusable workflow called with the repository's names, and
that is not built yet: see [Still open](#still-open).

### Linking: ours is the default, on macOS and Linux

Formulae **link normally on both platforms**, with no `keg_only` and no
`conflicts_with`: ours is the default on PATH, which is how it gets
used and how its bugs get found. (An earlier draft made the leaves
keg-only on Linux so the system tools would win; that is superseded by
the owner's decision on #235.)

The hazard that draft was guarding against is real — util-linux's `mkfs
-t ext4` resolves `mkfs.ext4` off PATH — and it is answered by making
the winner visible instead of hiding ours:

- **`--version` names the crate** (`mkfs.ext4 (am-fs-ext4) 0.7.0`), so
  which one ran is never a guess.
- **`<repo> doctor`** resolves every dotted name on PATH and says which
  package won, and the exact fix if it is not ours.
- **CAVEATS names the collision where one exists.** Measured: Homebrew's
  `e2fsprogs` is keg-only on macOS, so there is no clash; `erofs-utils`
  is linked and installs `mkfs.erofs`, so `rust-fs-erofs`'s CAVEATS gives
  the `brew unlink erofs-utils` line and where the reference stays;
  `btrfs-progs` is linked, but none of its names ships here.

It is a default, not a lock-in — `brew unlink` and `brew link --force`
both work. And you can add a name later; you cannot take one away, so
ship the minimal set.

### The umbrella, later

A pure meta-formula — `depends_on` lines and no binaries of its own —
comes once three or more drivers ship, which they now do. Because the
leaves are linked, it has no PATH job to do: it is only a one-line
install for the whole set. Its name is not decided; it is a package
name, so it may carry a vendor name, but it must not read as "the CLI
version of the app", which these tools are explicitly not.

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
| `mkfs.*`, `fsck.*`, `fs.*`, `img.*`, `blk.probe` | none — nothing validates them | plain native build + attested tarball |
| `diskjockey` | Developer ID required | signed build, cert in CI |

The filesystem tools stay trivially portable; only the control CLI
inherits Apple's machinery.

---

## Current state

As of 2026-10-02. Each repository's tools, its release with tarballs,
and its formula; the per-repository issues are linked from the tracker,
#235.

| repository | ships | release with tarballs | formula |
|---|---|---|---|
| rust-fs-ext4 | `mkfs.ext4`, `fsck.ext4`, `fs.ext4` | v0.7.0, but its tarball carries only `mkfs.ext4` (christhomas/rust-fs-ext4#475) | `rust-fs-ext4` |
| rust-fs-ntfs | `mkfs.ntfs`, `fsck.ntfs`, `fs.ntfs` | v0.7.0 | `rust-fs-ntfs` |
| rust-fs-xfs | `fs.xfs` | v0.10.0 | pending (homebrew-tap#219) |
| rust-fs-btrfs | `fs.btrfs` | not yet: v0.8.0 attached only the crate (antimatter-studios/rust-fs-btrfs#242) | after that release |
| rust-fs-erofs | `mkfs.erofs`, `fs.erofs` | v0.3.0 | `rust-fs-erofs` |
| rust-fs-squashfs | `fs.squashfs` (replaced `lssquashfs`) | v0.3.0 | `rust-fs-squashfs` |
| rust-img-qcow2 | `img.qcow2` (replaced `qcow2_tool`) | v0.5.1 | `rust-img-qcow2` |
| rust-img-vhd | `img.vhd` (replaced `vhd_tool`) | v0.5.1 | `rust-img-vhd` |
| rust-img-vhdx | `img.vhdx` | v0.5.0 | pending (homebrew-tap#215) |
| rust-img-vmdk | `img.vmdk` | v0.4.0 | pending (homebrew-tap#220) |
| rust-blk-probe | `blk.probe`, internal to the app | v0.1.0 | none, by decision |
| rust-partitions | none: `blk.probe` already prints the table; an editor is `sfdisk`/`gdisk` territory | — | — |

Every `fs.<fs>` carries every verb — `ls`, `read`, `write`, `mkdir`,
`get`/`info`, `set`, `resize` — and answers the ones its driver cannot
do (a read-only format, a write shape the driver refuses, a resize no
driver implements) with a structured error. Every `img.<fmt>` carries
`info`/`get`, `read`, `write`, `create`, `set` and `resize` on the same
terms. `rust-ntfs` stays the Windows harness driver, unshipped.

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

## Settled since the first draft

- **House style for tools with no dispatcher convention.** A tool that
  is one member of a per-format family is `<family>.<format>`, target
  first: `fs.<fs>` and `img.<fmt>`. `lssquashfs` folded into
  `fs.squashfs`, `qcow2_tool` became `img.qcow2`, `vhd_tool` became
  `img.vhd`. The probe is `blk.probe`, dotted like the rest; the
  repository and crate stay `rust-blk-probe`.
- **The image formats join the verb scheme** as `img.<fmt>` — see
  [Disk images](#disk-images-imgfmt).
- **Formula names, linking, attestation and the tap sync** — see
  [Distribution](#distribution).

## Still open

- **One reusable release workflow.** Every repository carries its own
  `package-cli`/`release-cli` jobs and its own `scripts/package-cli.sh`,
  and the copies already differ. They belong once, in `rust-fs-core`,
  called with the repository's names (antimatter-studios/rust-fs-core#193).
- **The cross-repository pipe test.** `fs.<a> src read <path> | fs.<b>
  dst write <path>`, compared by SHA-256 and passed through the
  destination's oracle, plus `img.qcow2 … read` into `fs.ext4` and
  `blk.probe` into `fs.<fs> --offset`. Proposed as a `chore
  test:cli-pipe` task in this repository, run against Homebrew-installed
  formulae on a schedule or by dispatch. It cannot be a required check,
  because it depends on releases from several repositories (#292).
- **A `blk.<fmt>` family for partition tables** (`blk.gpt`, `blk.mbr`:
  `ls`, `info`, `read <n>` streaming one partition's bytes), which would
  complete `img.qcow2 … read | blk.gpt … read 2 | fs.ext4 … ls`. Not
  decided; revisit after the `fs.`/`img.` tools land.
- **`set label` writers** for ext4, xfs and btrfs, and **resize** for
  every filesystem: the verbs exist and answer "not implemented" until
  the drivers can do it.
