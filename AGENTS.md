# Working in diskjockey (agent guide)

The macOS application, and the constellation's coordination layer. Two halves
that share a checkout:

- **The app.** A SwiftUI host (`DiskJockeyApplication/`), an unsandboxed XPC
  helper (`DiskJockeyAgent/`), a File Provider extension and six FSKit
  extensions (`DiskJockeyEXT4/`, `DiskJockeyNTFS/`, `DiskJockeyXFS/`,
  `DiskJockeyBTRFS/`, `DiskJockeyEROFS/`, `DiskJockeySQUASHFS/`), over a shared
  Swift framework (`DiskJockeyLibrary/`). **It links static libraries built
  from the Rust driver crates** — one per filesystem, from
  `rust-bundles/dj-<fs>-bundle` into `lib/bundle_<fs>/` — plus the Go
  network drivers' archives from the `../go-networkfs` sibling.
- **The coordination layer.** `scripts/am-*` (`am-overview`, `am-ledger`,
  `am-prs`, `am-worktree-reap`, `am-slot`, `am-cost`, `am-tokens`),
  `docs/constellation/`, `chores.yml` and the `scripts/tests/*.sh` suites that
  gate them. This is the only repository in the family that knows the family
  exists: `scripts/constellation-repositories.sh` is the canonical list.

This file is the fast path for an agent picking up work here, so the workflow
does not have to be re-derived each time. It points at the existing docs rather
than duplicating them:

- **README** → `## Architecture`, `## Project layout`, `## Build`,
  `## What works` / `## What doesn't work`.
- **`SIBLING_PINS.txt`** → which ref of each sibling the app is built against,
  and why they are tags.
- **`.github-guard`** → the three required checks, and what each one is for.
- **`docs/constellation/`** → the scan, the plan and the evidence behind them.

The section between the BEGIN/END markers below is **shared, byte-identical,
with every repository in this family**. Do not edit it here: change the
canonical copy and propagate it, or `scripts/agents-core-check.sh` will fail.
Everything after the END marker is specific to this repository.

<!-- BEGIN SHARED BLOCK: agent-core v1 sha256:60fad6dd98e9da3e9256d38728b02ac189dca0d04fc98c13e2c67de3f3103319 -->
## Claiming work

Several agents work these repositories at the same time. Before you start on
an issue, claim it, so nobody else spends a session on what you are already
doing. The lock is a **GitHub label**, because labels are shared state that
every agent can read and change without posting comments into the thread.

**Before starting.** Check, claim, then read back:

```sh
gh issue view <N> --json labels                      # holds `claimed`? pick another
gh issue edit <N> --add-label claimed --add-label claim/<session>
gh issue view <N> --json labels                      # read back and confirm
```

`<session>` is your session name — `agent-<random4>-<isodate>`, e.g.
`agent-3f7c-2026-09-22`. Create the `claim/<session>` label if it does not
exist.

**Resolving a race.** Adding a label is not compare-and-swap: two agents can
both add `claimed` and both believe they won. That is what the read-back is
for. If it shows more than one `claim/*` label, the **lexically lowest**
session keeps the issue; every other agent removes its own `claim/*` label and
picks different work. Each racer computes the same answer independently, so no
further coordination is needed.

**When you finish or stop.** Remove both labels — on merge, or the moment you
abandon the work:

```sh
gh issue edit <N> --remove-label claimed --remove-label claim/<session>
```

Delete your `claim/<session>` label from the repository at the end of your
session so they do not accumulate.

**Reclaiming a stale claim.** An agent that dies holding a claim would block an
issue forever. If `claimed` was applied more than 12 hours ago and the holder's
branch has no commits since, any agent may take it: remove the stale `claim/*`,
add your own, and say so in the issue.

**This is a convention, not a fence.** Nothing enforces it. An agent that
ignores it duplicates work; it cannot corrupt anything. Honour it anyway.

## Skills to use

- **`dev-loop`** — the required loop for any non-trivial change: baseline the
  full suite → change → re-run (no baseline test may regress) → enhance tests →
  vet. Always run it.
- **`commit`** / **`pr`** — for grouping commits and opening pull requests.

Each repository names any further skills of its own below.

## A bug fix starts with a red

**Prove it is broken first** — a failing check or test — *then* fix it, *then*
prove that same check is green, *then* confirm the full baseline still passes.
Never write the fix before you have a red. A fix with no failing test to its
name is a claim, not a result.

## Nothing skips

A test that cannot run **fails**, naming the task that would provide what it
needed. Never add an early return for a missing fixture, tool or VM: a skipped
test reads exactly like a passing one, and a suite that quietly declines to run
is indistinguishable from a suite that passes.

Where a tier reports skips or ignored tests, that is a gate, not a note.

## Validate against something that is not us

A driver's own readers share its interpretation of the format, so they cannot
catch a misreading: the mistake is baked into the fixture *and* the parser, and
they agree with each other while disagreeing with every real filesystem. Unit
tests over self-built fixtures prove self-consistency, not correctness.

Every structure that is parsed or written gets a cross-validation test against
an **independent oracle** — the platform's own tools, a real kernel, or a third
implementation — before it is considered done. Each repository names its
oracles below.

## Output is budgeted

Test tiers run through `scripts/tier.sh`, which runs the suite **quietly**: the
whole run goes to `tmp/logs/<tier>.log`, a pass prints one verdict line naming
that log, and a failure prints its tail. CI keeps the logs as an artifact, so
the detail is always retrievable.

The budget caps the log, not merely what is shown, and every number in the
table was measured. A run that passes but prints more than its budget **fails**.

The reader who pays most for a noisy suite is an agent that re-reads its whole
transcript on every step, and so pays for one loud run many times over. If a
tier legitimately grows, raise its row **with the measurement that justifies
it**. Do not silence output to fit, and do not route around `tier.sh`.

## Commits and branches

- Branches are `<type>/<name>`, matching the commit type: `fix/`, `feat/`,
  `ci/`, `docs/`, `chore/`, `test/`.
- A commit is a subject plus flat one-sentence bullets. Subjects are
  declarative, not imperative: "the run-end bound is checked", not "check the
  run-end bound".
- **No AI attribution and no co-author trailers**, in commits or in pull
  request descriptions.
- `main` takes **squash merges only**.

## Project rules

- **No GPL/LGPL/AGPL dependencies.** Permissive only (MIT/BSD/Apache).
  Shelling out to a copyleft CLI as a *test oracle* is fine — linking or
  copying it is not.
- **Each of these is a standalone project.** Never mention a consuming
  application in the README, the source, or CLI help.
<!-- END SHARED BLOCK: agent-core v1 -->

## Where the shared block does not map cleanly

Two clauses above are written for a Rust driver crate, and reading them
literally here gets the wrong answer. Both still bind; what changes is where.

- **"Output is budgeted"** names `scripts/tier.sh`. **There is no `tier.sh` in
  this repository** and nothing here calls one. The same intent is served by
  three other things, and they are the ones to keep honest: the `::group::`
  framing around each shell test in `ci.yml`, `xcbeautify` on the `xcodebuild`
  stream, and the executed-case floors below. If a suite here starts printing
  a transcript, fix it in this repository rather than reaching for the
  harness's wrapper — see the rule about shared tools below.
- **"Never mention a consuming application"** is a rule for the libraries.
  **This repository is the consuming application**, so it is the one place in
  the family that names them all — `SIBLING_PINS.txt`, `rust-bundles/`, and
  `scripts/constellation-repositories.sh` exist precisely to do that. The rule
  still binds you when you are working in a sibling: do not fix a diskjockey
  problem by teaching a driver crate about diskjockey.

## Never grow a shared tool to solve a problem here

**Never grow a shared tool to solve a problem in this repository.** `chore` is
a general-purpose task runner this project merely consumes; the same goes for
`github-guard` and the agent-skills hooks. If something needed here looks like
it belongs inside one of them, it does not. Solve it here, or ask first. The
tell is a release: if a shared tool needs a new version cut whose only purpose
is to unblock this project, the code is in the wrong repository.

The pinned `chore` version is in `SIBLING_PINS.txt` and `chores.yml` declares
`chore_min_version`. A change here that forces either of those to move is the
signal, not a detail of the change.

## The tasks

`chores.yml` is deliberately thin: every task names a script in `scripts/` and
nothing else, because the script is what can be tested, reviewed and run
without `chore` at all. A task that grows a pipeline of its own is a task
nobody can test.

```sh
chore overview:summary   # counts only, one row per project
chore overview:list      # every project in turn, with issue numbers and titles
chore overview:tsv       # the detail rows as TSV
chore pr:list            # every pull request across the constellation
chore pr:external        # only those opened by external contributors
chore check:scripts      # every scripts/tests/*.sh guard
chore check:agents-core  # AGENTS.md still carries the shared block, unmodified
```

Note what is **not** here. diskjockey orchestrates the twelve library
repositories rather than being one of them, so it has no `staticlib` and no
`artifact` — the two tasks every sibling exposes. A task named after something
this repository does not do would be a lie a reader could act on.

The neighbouring tasks take no `sources:` on purpose: their answer lives on
GitHub and moves when somebody files an issue, so a fingerprint would let
`chore` report them up to date while the backlog changed underneath.

## Running tests

Three suites, three different reasons, and CI runs all three:

```sh
swift test                              # DiskJockeyLibraryTests, host-free
bash scripts/tests/<name>.sh            # one shell guard
chore check:scripts                     # all of them, the way CI does
```

and the app-hosted target, which needs Xcode and a macOS 15.4+ host:

```sh
xcodebuild test -project DiskJockey.xcodeproj -scheme DiskJockey \
  -destination 'platform=macOS,arch=arm64' -only-testing:DiskJockeyTests
```

- **`swift test` (job `Library tests`, `macos-26`).** `Package.swift` exists
  for exactly one reason and its header says so: `xcodebuild test` cannot run a
  test bundle without launching a process to host it, and on the CI runner that
  launch is refused often enough to matter (diskjockey#139). `swift test` links
  the test code into a binary — no launch service, no launchd job, nothing to
  sign. `Package.swift`'s `platforms` and `language` settings mirror
  `project.pbxproj`'s `MACOSX_DEPLOYMENT_TARGET` and `SWIFT_VERSION` and must
  move with them.
- **`xcodebuild test` (job `Build & Test`, `macos-26`).** The app-specific
  target only — the library suite is not run twice, because the redundant
  second app/harness lifecycle is what actually timed out. Built unsigned:
  `CODE_SIGNING_ALLOWED=NO`, because ad-hoc signing *applies* the entitlements
  and a sandboxed binary no profile authorises is refused at spawn. UI tests
  are excluded; they need a running app and a virtual display.
- **`scripts/tests/*.sh` (job `Shell scripts`, `ubuntu-latest`).** Text-only
  guards over the project file, the workflows and the `am-*` tools. No
  toolchain, seconds to run, so nobody is tempted to make them conditional.

### The floors, and why every suite here has one

The failure this project keeps meeting is an **absence**: a run that stops
early reports no failures at all, so nothing that greps for a failure can see
it. Only a count can. Each of the three jobs therefore refuses a run that did
less than a measured amount of work:

| job | floor | counted from |
|---|---|---|
| `Build & Test` | 160 executed cases | `xcresulttool get test-results summary` on the retained `.xcresult` — **not** the console text, which double-counted once and undercounted once |
| `Library tests` | 215 executed cases | XCTest's `Executed N tests` plus swift-testing's `Test run with N tests`, both frameworks being in that target |
| `Shell scripts` | 18 test files | the glob's own match count |

Every floor is written down beside the measurement and the run that produced
it. **A floor moves up with its suite; it never moves down.** Raising one is a
deliberate edit carrying a new measurement — lowering one to make a run green
is the defect it exists to catch.

### The contract every shell test signs

`ci.yml` requires each `scripts/tests/*.sh` to end by printing

```
<basename>: all checks passed
```

as its **last line**. `exit 0` is not evidence a script finished: an `exit 0`
injected anywhere gives status 0 having run a prefix of its checks, with no
failure named. Measured on `am-ledger-lock.sh` — 13 of 22 checks, exit 0,
accepted. The trailing line turns a truncated run into a failure. A new guard
that does not print it fails the job even when every check inside it passed.

The house style, visible in every file there: `ok`/`fail` helpers, a `fails`
counter, `set -uo pipefail` (not `-e`, so later checks still run), a `mktemp -d`
sandbox when the guard needs a tree to work on, and `exit $(( fails > 0 ))`.

## The oracles are not in this repository

The shared block requires cross-validation against something that is not us.
For the filesystem formats, **that validation lives in the driver repositories
and only there** — `rust-fs-ntfs` against Windows `chkdsk`, `rust-fs-ext4`
against the Linux-side reference validator, and so on. The Swift here is a thin
shim over their C ABIs; adding a fixture-based "does ext4 parse" test to this
repository would test our own reading of our own bytes, which is the exact
self-consistency trap that clause is about.

What this repository can be validated against is **Apple's frameworks and the
build system**: FSKit and File Provider mounting a real volume in Finder, and
`project.pbxproj` read as data rather than assumed. `scripts/tests/` is mostly
the second kind — `the-agent-is-a-target.sh` parses the Xcode project to prove
the XPC helper is a target, is unsandboxed, is embedded where launchd's plist
expects it, and that the two hand-copied `DJAgentProtocol.swift` files still
agree. That last one is a compile-clean, run-time-fatal mismatch, which is
precisely the class a text guard can catch and a build cannot.

## Building

The app does not build from a bare checkout. Two vendoring steps first:

```sh
make vendor-bundles       # scripts/build-bundles.sh: one Rust staticlib +
                          # headers per filesystem, into lib/bundle_<fs>/
make vendor-gonetworkfs   # per-driver Go static libs + libnetworkfs.a,
                          # into lib/go-networkfs/
make vendor-all           # both
make proto                # regenerate protobuf bindings after a .proto change
```

Without `vendor-bundles` the Xcode build fails with `'fs_<fs>.h' file not
found`: the FSKit targets include those headers through
`HEADER_SEARCH_PATHS`.

The Rust drivers are **not checked out** for a normal build — each
`rust-bundles/dj-<fs>-bundle` depends on published crates.io versions.
`go-networkfs` *is* a sibling checkout beside this repository, cloned at the
ref `SIBLING_PINS.txt` names. `scripts/sibling-build.sh` builds a sibling from
its checkout when that is on a clean `main`, and otherwise from a throwaway
worktree of the pinned ref, so a developer's branch cannot reach the app's
binary. A dirty `main` stops the build rather than guessing.

`scripts/check-bundle-core-pin.sh` runs first in CI and needs nothing but the
checkout. It exists because a lockfile can be internally consistent and still
pin a version nobody has verified — `am-fs-core` sat six releases behind for
eight releases, missing a silent-wrong-bytes fix (diskjockey#90).

## What gates a merge

Three required contexts on `main`, and they are **declared** in `.github-guard`
rather than discovered: `Build & Test`, `Library tests`, `Shell scripts`.
Discovery requires checks by job name, which drifts silently as jobs are
renamed or added; a list nobody reviews is a residue, not a decision.

`ci.yml` is the only workflow that runs on `pull_request`. `release.yml` is tag-
and dispatch-driven, so its checks can never report on a PR and **must never be
required** — a required check that never reports is a permanent block, not a
gate.

Two things worth knowing before you read a green tick here:

- CI runs on **every** pull request, not only those targeting `main`. It
  carried `branches: [main]` once, and a PR based on another branch then got no
  run at all — while `gh pr view` called it `CLEAN`, because a PR with no
  checks has no failing checks. Stacked branches are how work arrives here.
- Judging mergeability from check **conclusions** is unreliable: an in-progress
  `CheckRun` reports its conclusion as an empty string, and a `StatusContext`
  has no conclusion field at all. Read `mergeStateStatus` and
  `statusCheckRollup.state`.

`scripts/agents-core-check.sh` verifies the shared block above is intact. It
runs two ways, and neither needed a new CI job: `chore check:agents-core` calls
it directly, and `scripts/tests/agents-core-check.sh` — picked up by the
existing `Shell scripts` glob — runs it against this repository's real
`AGENTS.md` and then proves it *fails* on a modified block, a missing marker, a
marker that disagrees with its content, and an absent file. A gate that cannot
fail is indistinguishable from no gate.
