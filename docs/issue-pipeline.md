# The issue pipeline

A way of running a large backlog across the twelve repositories of the
constellation using several agents at once, without them treading on
each other and without work going missing.

Written 2026-09-07, from the run that built it. Everything here has been
used; the failure modes described are ones that actually happened rather
than ones that seemed likely.

## The shape

```
  audit ──► triage ×5 ──► fix ×2 ──► verify-pr ──► pr-monitor
              │              ▲                          │
              │              └────── stage=failed ──────┘
              ▼
           am-ledger  (one row per issue, the truth about where it is)
```

Each stage does one thing and hands on. The loop back from
`pr-monitor` to the fixing agents is the important part: a pull request
whose build fails is not an end state, it is work returning to the queue.

| stage | what it does | what it writes |
|---|---|---|
| `audit` | reads code, files issues that do not exist yet | new GitHub issues |
| `triage` | decides whether each issue is true and worth doing | `This issue is selected for development` / `This issue is rejected because of the following reasons` |
| `fix` | reproduces, fixes, pushes a branch | `This issue is ready for testing` |
| `verify-pr` | runs the full test spectrum, opens the PR | `This issue is ready for PR` |
| `pr-monitor` | watches the build, merges or returns it | `The PR failed` + the decisive output |

## The ledger

`scripts/am-ledger`, state in `~/.local/state/am-constellation/issues.tsv`.

One tab-separated row per issue: repository, number, stage, owner,
branch, pull request, timestamp, title.

    am-ledger refresh                    rebuild from GitHub, keeping stages
    am-ledger next <stage> [repo]        claim one row atomically
    am-ledger set <repo> <n> stage=...   record progress
    am-ledger list [filter]              rows, optionally filtered
    am-ledger stats                      counts by stage
    am-ledger stale [hours]              claimed rows that stopped moving
    am-ledger start <project> <owner/name>...
    am-ledger projects                   every project that exists

### Projects

A **project is a pipeline scope, not a repository**: one project has one
ledger and spans as many repositories as it likes. `diskjockey` is the
controlling project for the twelve-repository constellation — the place
the stages are run from and the statistics are read, even though the
work itself lands in other repositories.

    am-ledger start acme acme/api acme/web
    export AM_LEDGER_PROJECT=acme && am-ledger refresh

`AM_LEDGER_PROJECT` selects the ledger; unset, every command behaves
exactly as it always has. That is deliberate, and is what allowed this
to be added **while the pipeline was running**: no agent's command line
changes.

It is also why the project is *not* a leading argument. `am-ledger set
rust-fs-ntfs 168 stage=pr` would still parse under a signature that took
the project first — it would simply write to a project named
`rust-fs-ntfs`. A silent misfile is worse than a breakage, and a
positional argument would have made every running agent do it at once.

### `failed` and `blocked` are different work

Both return a row to a fixer, and they are kept apart because what the
fixer must do differs:

- `failed` — a build ran and said no. Diagnose the failure.
- `blocked` — **nothing ran.** The pull request is DIRTY, its branch is
  behind, or an oracle was unavailable. There is no test failure to
  find; the work is rebase, resolve, re-verify, push.

Someone who picks up a blocked row expecting a failure hunts a defect
that does not exist. This is the marker-overload lesson again, in the
ledger rather than in comments: when two things need different work,
they need different words, and a stage that nobody drains strands its
rows — so say which agents drain each.

**Verification does not survive a rebase.** Mutation testing, negative
controls and arm-by-arm reverts are evidence about *one tree*. If the
code around the fix has been rewritten since, that evidence is stale and
must be re-established rather than inherited: a fix can be correct
before a rebase and wrong after it, with every earlier tick still green.

**Look for the collision at branch level, not pull-request level.** By
the time two pull requests are open the damage is already scheduled, and
sometimes the sibling does not exist yet: one collision here was between
a merged pull request and a branch that had not been proposed. The
overlap was visible, though — the branch was sitting at `fixing` in the
ledger with its name recorded, touching the same file.

The ledger carries a `branch` field for exactly this. Before merging,
compare against every branch the ledger has in flight for that
repository:

    am-ledger list <repo> | awk -F'\t' '$3=="fixing" || $3=="testing" {print $5}'
    gh api repos/<slug>/compare/main...<branch> -q '.files[].filename'

Where the file lists intersect, say so in the merge comment. It does not
prevent the collision; it turns a surprise into a note, and tells the
next fixer their evidence is stale before they discover it.

This is the second-order cost of a stack, and it is easy to miss.
`rust-fs-core` #55 was made un-runnable by #54 merging — nothing was
wrong with #55. **When two pull requests touch the same file, merging
one invalidates the other's evidence as well as its mergeability.** Land
a stack in order and re-verify each after its parent lands, rather than
preparing them in parallel.

A conflict that is textual — two documentation paragraphs that both
belong — can be resolved by whoever finds it. A conflict that is
semantic goes back to the author. Where a refusal sits relative to a
pre-write sweep, a post-write sweep and a generation counter is not a
merge decision; get it wrong by one line and the result merges green and
is quietly wrong. Resolving a conflict you cannot verify is the one
irreversible step in the pipeline taken on its weakest evidence.

### Finding what has stopped

    am-ledger stale [hours]      claimed rows that have not moved
    am-ledger stale --all [hours]  include unclaimed rows too

Every stall in the first run looked identical from `stats`: a count that
did not move. A row claimed by an agent that had died, a row waiting on
a message that never arrived, a row left `pending` while GitHub moved
on — none are visible until you ask **how long a row has been where it
is**.

By default this lists only rows with an owner, and the distinction
matters: two hundred `accepted` issues waiting for a free fixer are
queue depth, not stalls, and listing them buries the handful that are
genuinely stuck. In this run the honest answer was four rows out of two
hundred and sixty-four.

**GitHub remains the truth for what an issue says. The ledger is the
truth for where it is.** That split is what makes the pipeline cheap:
without it, every agent re-listed every issue in every project to find
out what was left — twelve API calls to answer one question, repeated
per agent per decision.

`next` is the part that matters. It finds an unclaimed row at a stage,
writes the caller's name into it, and prints it — all under a directory
lock, so two agents polling the same instant cannot both start the same
issue. Every write goes through that lock, because a read-modify-write
on a shared file from several agents is the textbook lost update.

Set `AM_LEDGER_OWNER` to the agent's name, and release rows with
`owner=-` when handing on, or the next stage cannot claim them.

## Messaging, and why the ledger exists anyway

Agents message the next stage as they finish — per repository, not per
batch, so a fixing agent can start on one repository while another is
still being triaged.

Messaging is the fast path. **The ledger is the reliable one.** During
the first run an agent was given an address for a stage that had not yet
been launched; its messages went nowhere. It kept working and recorded
state in the ledger, and the next stage picked the work up regardless.
Had the pipeline depended on messaging alone, that would have been a
silent stall.

Use both. Message for latency, ledger for truth, and never let a stage
block on a message that may not arrive.

## The rule about comments

An issue accumulates comments across cycles: accepted, ready for
testing, PR failed, ready for testing again. **Sort by time and act only
on the newest status marker.** An older comment that a newer one
supersedes is history, not state.

This matters most in the failure loop, where an issue carries several
`ready for testing` comments and only the last names the branch worth
looking at.

### Each stage has its own words, and may not borrow another's

| stage | markers |
|---|---|
| triage | `This issue is selected for development` / `This issue is rejected because of the following reasons` |
| fixing | `This issue is ready for testing` |
| verification | `This issue is ready for PR` / `Verification found defects in the branch` / `Verification is blocked` |
| PR monitoring | `The PR failed` |

Because the newest marker is read as the truth, a stage that reuses
another's vocabulary rewrites a decision it never made.

That is not hypothetical. A verification agent needed to say that a
branch could not be verified yet — it was stacked on two unmerged
branches and would be rebuilt when they landed — and the only negative
marker available was triage's. It wrote `This issue is rejected because
of the following reasons`, and `rust-img-vhd` #43 then read as a
rejected issue when it was accepted and its fix was sound. The
verification agent's reasoning and decision were both correct; the
vocabulary was the defect.

The lesson is that this was **a missing marker rather than a careless
agent**. Verification has three outcomes and had words for one, so the
other two were forced into the nearest wrong phrase. All three now
exist:

- `This issue is ready for PR` — verified, pull request opened;
- `Verification found defects in the branch` — verified, and the branch
  is wrong; back to fixing, the issue still accepted;
- `Verification is blocked` — the fix is sound and something in the
  environment prevents proving it: a stacked branch, an absent fixture,
  a VM in use. It parks an issue where a rejection would have sent it
  backwards.

The middle one is the most common outcome of that stage, and was the
last to be noticed — because an agent with no word for its usual result
does not complain, it improvises, and the improvisation reads as
something else entirely.

When adding a stage, enumerate its outcomes and give each one a sentence
before giving it any work.

## What went wrong, and what to keep

These are the failures worth designing against, because each cost real
time on the first run.

**Agents in the same checkout.** One agent ran `git stash -u` while
another was mid-edit in the same repository, sweeping up its untracked
work. Give each stage **exclusive ownership of a set of repositories**,
and have the fixing stage wait until triage of a repository is finished
before editing it.

**Heavy jobs in parallel.** Two 4–8 GB oracle VMs plus concurrent
`cargo test` runs filled the machine, and it did not fail cleanly — it
killed background work, with nothing connecting the deaths to the cause.
Contention on this hardware also produces test failures that are not
real, and several hours went into chasing them.

The first attempt at a fix was to tell every agent **one `cargo test` at
a time**. That does not work, and why it does not work is the more
useful lesson: every agent obeyed the instruction, and none of them
could see the others. Five obedient agents produced five concurrent
runs. An instruction that each party can follow individually and none
can enforce collectively is not a limit — it is a wish.

So both limits now live outside the agents, where something can count:

- oracle VMs, one at a time, through `scripts/vm-slot.sh` in each
  repository that has one — taken by `vm.sh up`, released by `down`;
- builds and tests, two at a time, through `scripts/am-slot` (put it on
  your PATH, or in `~/.local/bin`):

      am-slot cargo cargo test --locked

`am-slot` runs the command and exits with the command's status, so
nothing about reading a result changes and a wrapper can never turn a
failure into a pass. A test that needs a VM takes both slots.

Work now queues instead of overlapping, and a run waits for the ones
ahead of it. That is slower on a good day and much better on a bad one,
because the failure it removes was silent and the cost it adds is
visible. Re-running a failure alone before believing it remains good
practice regardless.

**Guards that are themselves unguarded.** The recurring defect of this
whole codebase, and the pipeline reproduced it twice in its own
tooling:

- A dependency-pin check passed as soon as *one* workflow named the
  right version, so a repository with two pins was told it was fine
  while only one had been read. Three successive fixes each closed one
  spelling and left another, because each was verified against the case
  it had just added.
- A test asserting CI had built its fixtures was added to a job that
  invokes suites by name — and was never named. The check written to
  catch silently-skipping suites was itself silently skipped, in the
  commit that introduced it, and reported green.

- The one-VM-at-a-time slot, written to stop two virtual machines
  running at once, would free a lock that was in the middle of being
  taken. Its release path checks that the caller owns the slot, and
  falls through to an unconditional `rm -rf` when *no holder is recorded
  yet* — which is exactly the state `acquire` occupies between creating
  the lock directory and writing its holder file. `vm.sh down` calls
  release unconditionally from repositories that never booted, so the
  collision is ordinary rather than exotic, and the result is two
  holders, two `acquire` calls returning success, and two VMs.

  The comment directly above that code reads *"Only the holder may
  release... otherwise a script that never took the slot can free
  somebody else's, which is the same bug as not having a lock at all."*
  **The comment states the rule correctly and the code does not
  implement it.** That is worse than an unguarded path, because it
  reassures every reader who checks — including the person who wrote
  both.

**Checking that a guard fires is not the same as checking what it is
blind to.** Build the failing case and watch it fail, then build the
cases you did not think of. And when a comment asserts an invariant,
test the invariant rather than reading the comment — the two are
independent claims, and the comment is the one that cannot fail.

**A broken harness looks exactly like a clean bill of health.** When
both sides of a comparison agree and the evidence says they should not,
suspect the harness before the claim. Three times in one run a null or
symmetric result was a rig that had not run:

- worktrees that vanished mid-run, so the write under test never
  happened and both sides returned the original byte;
- a local run without `CI` set, which took a different path from the one
  being reproduced and reported no defect;
- a hand-built fixture whose checksum covered fewer bytes than the
  reader reads, because a Python slice assignment with a short value
  silently shrank the array — failing identically on both sides, which
  reads as "the crate rejects my input" rather than "my input is
  malformed".

Each would have been reported as *no defect found*. The tell in all
three was agreement that the prior evidence made implausible. Before
believing a negative, prove the setup did what it claimed: assert the
file exists, the write landed, the sizes are what you meant.

This is the same defect as a suite that skips and reports `ok`, moved
from the code being tested into the thing doing the testing.

**A finding gets its own issue.** Not a trailing paragraph on whatever
is being closed. A finding attached to an unrelated issue cannot be
found by anyone searching for it, misleads everyone reading the issue it
landed on, and — worst — never passes through triage, so its framing is
never checked. One did exactly that: a note about an inert test suite
rode along on a merge comment for an unrelated fix, carrying a remedy
that would have made things worse, and no stage saw it.

**An empty search result is not evidence unless you know what the search
covers.** `gh issue list --search` does not index comment bodies. A
search for a term that lives in a comment returns nothing, which reads
identically to the term not existing. To ask whether something is
already recorded:

    gh issue view <n> --repo <slug> --json comments \
      -q '.comments[] | select(.body | test("<term>"; "i"))'

This is the guard-that-is-itself-unguarded defect again, in the act of
checking: it is possible to confirm a search ran and never establish
what it was blind to.

**State the scope of a survey with its result.** Two agents surveyed the
same question and got different answers: one read `ci.yml`, the other
read all of `.github/workflows/`. Both were correct answers to the
question each had actually asked, and neither was the question that
mattered — *can the gate that decides a merge see this defect?* Each
then read the other's number as an answer to their own question, and
four issues were filed on the wrong claim before the disagreement
surfaced.

One line of scope in each report would have made the conflict visible
immediately. "Across `ci.yml` on main" and "across every workflow file"
are different findings even when the number is the same.

**Two agents disagreeing is a control worth arranging.** The
reconciliation produced a better answer than either had: five
repositories affected rather than four or one, and two distinct remedies
— one group has no debug run at all, the other has one on the wrong side
of the merge, triggered by `push: tags` rather than `pull_request`. That
distinction is invisible unless someone asks why the two surveys differ.

For a finding that will drive work across several repositories, having
two agents reach it independently costs less than either one being more
careful, and catches a class of error that care does not.

**Ask whether the gate's profile can observe *this* defect.** Not
whether CI runs both profiles — whether the one it gates on could fail
for the reason under test.

Every `cargo test` in one crate's CI is `--release`, and its
`[profile.release]` sets no `overflow-checks`, so the default applies
and arithmetic overflow wraps silently instead of panicking. A fix for
an overflow defect merged there with four tests that ran, passed, and
**could not fail**: in release the old code returned the right answer by
accident. The tests were real, the run was real, the green tick was
real, and it certified nothing.

This is the strongest form of the pattern. Not a suite that skipped, not
a job that never ran, not a result nothing read — a test that executed
and whose outcome was independent of the bug. It generalises past
overflow: any defect whose symptom depends on build configuration —
`debug_assert!`, bounds behaviour, sanitisers, timing — needs its gate
checked against the specific failure, not against a coverage policy.

**Reproducing CI means reproducing its environment, not its command.**
`CI=true` changes behaviour in several of these repositories. A local
run without it answers a different question, and answers it more
permissively — which manufactures false findings rather than missing
real ones.

**Three ways a build lies.** A conflicting pull request gets no CI at
all and looks like a slow runner. A run held at `action_required` has
not executed either. A fixture-gated suite skips and reports `ok`.
Teach the monitoring stage all three, because from the checks list they
are indistinguishable from success.

## Verification, which is the whole value

The single most useful thing any stage does is the **negative control**:
revert only the source change, leave the test, and confirm the test
fails. A test that passes with and without the fix proves nothing, and
this catches it in one step.

A negative control proves something about the *harness* as well as the
fix: that the checking method can report a failure at all. That is not a
given. A verification step built on `awk '/^test result:/{...}'` reads
what the harness printed and never asks whether it finished — a compile
error in one target, a panic outside a test, a signal, an aborted binary
all leave a clean-looking count. Two of us ran that pattern for most of
a session; what made the results trustworthy was watching a reverted arm
actually fail. Capture the status where it cannot be omitted:

    am-slot cargo cargo test --locked; echo "EXIT=$?"

The general shape is worth naming, because it is the same defect the
whole pipeline hunts for: **a check whose output does not depend on the
failure it exists to detect.** A test that passes with the fix reverted
is one instance. A verification step that cannot see a crash is the same
thing, one level up, in the thing doing the checking.

**Revert each arm separately, not the whole file.** A fix usually has
several mechanisms, and a whole-file revert asks only "does anything
here matter?" — to which the answer is nearly always yes. That proves
nothing about the parts, and it is also the most natural control for the
author to run, which is why the gap survives their own check.

The recurring shape is a fix with several mechanisms covered by one test
that would pass with most of them gone: the suite tests one mechanism
and is credited for all of them. Three instances in one run —

- a cache fix where the generation counter alone passed the test and the
  post-write sweep was free;
- a partition-table fix where four mechanisms shared one fixture, which
  reached only the neighbour pass and only the upper bound; **two of the
  four could be deleted outright with 83 tests green**;
- a bounds fix tested far outside the boundary on one side, so neither
  edge was exercised.

Two habits catch all three. Delete each arm on its own and see which
deletions stay green. Then **mutate each comparison by one** — `<` to
`<=`, `>` to `>=` — and see which mutations survive.

**Assert the expression is unique before mutating it.** A guard's
comparison is often written twice: once in the guard, once in a test's
own assertion about it. A blind substitution then edits the *test*,
which goes green, and the guard is reported as pinned when nothing
touched it. One mutation here failed to apply for exactly that reason
and only the uniqueness check made the near-miss visible. Count the
occurrences first; if there is more than one, name the file and line. A bound worth
fixing is worth testing from both sides: the last accepted value must
still be accepted, or a correction that overshoots by one rejects
legitimate input everywhere and no test notices.

This is the codebase's recurring defect one level up: the second pass
exists because the first has a blind spot, and nothing checks that the
check-of-the-check is reachable.

The second most useful is **reproducing before fixing**. A large number
of filed issues turn out to be false — the case was already handled, the
arithmetic could not overflow, the guard was already correct. Finding
that out costs one test; implementing a fix for a defect that does not
exist costs a great deal more, and leaves a worse codebase.

Across the first run, every *numeric* claim that was independently
re-derived held. Every failure was in the **prose** — which job runs
what, what a tool's default is, whether a hook can see a spelling. That
is where to point the scepticism.

## Dispatch: who wakes a fixing agent

The first version of this pipeline partitioned repositories between two
fixing agents. That was wrong in a way that took a day to see: three
repositories were assigned to nobody, and **52 of 187 accepted issues
sat unowned rather than merely slow** — a gap invisible from `stats`,
because an unclaimed row looks the same whether it is queued or
orphaned.

Assignment belongs to the issue, not the repository. Every stage that
produces work for a fixer sends it:

| stage | when it messages a fixer |
|---|---|
| triage | an issue reaches `accepted` |
| verification | `Verification found defects in the branch` |
| PR monitoring | a build fails, or a pull request is `blocked` |
| review | a bot finding becomes an issue worth fixing now |

**Verification is the one most easily forgotten.** It returns work at
least as often as the monitoring stage does, and it sits in the middle
of the pipeline rather than at either end, so it is not where anyone
looks for a producer.

### A message enqueues; it does not interrupt

Each agent keeps its own list of what it has been given, and works
through it. A message **appends to that list** — it is not an
instruction to drop what is in hand, and the work it carries may wait
behind several other items before it is started.

That distinction is what makes the rest safe. An agent busy on one issue
does not lose the message about the next, because arrival and execution
are separate: arrival is cheap and immediate, execution is ordered. It
also means a sender must not infer anything from silence. A stage that
has handed off and heard nothing back has no evidence about whether the
work has started, and asking is more expensive than waiting.

Three lists, and they are not the same list:

- **the agent's queue** — what it intends to do, in order. Fast, private,
  and **lost if the agent dies**.
- **the ledger** — what is claimed and at what stage. Durable, shared,
  and the only one that survives an agent.
- **GitHub** — what each issue says. The truth about content, never
  about position.

An agent should record a claim in the ledger when it *starts* an item,
not when it queues one. A row claimed on receipt would show as in
progress while it sat fifth in a list, and `am-ledger stale` could not
tell that from an agent that had stopped.

**Messages are the fast path and the ledger is the reliable one.** A
message already went nowhere in this run — a stage was given an address
that did not resolve, and it flagged the failure rather than dropping
it, which is the only reason anyone noticed. If dispatch is purely
event-driven, a lost message is a silently stalled row; polling used to
cover for that. So a periodic sweep re-dispatches anything at
`accepted`, `failed` or `blocked` with no owner, and anything claimed
that has stopped moving (`am-ledger stale`). That makes a lost message a
delay rather than a stall.

### A worktree per issue

Two agents in one checkout is a real collision — one ran `git stash -u`
over another's in-flight work. The fix is not to serialise the
repository, which would throw away the concurrency dispatch just bought.
It is to give each issue its own worktree:

    git worktree add <scratch>/<repo>-<issue> -b fix/<issue>-<slug> origin/main

Two obligations come with it, and neither is optional.

**A worktree holds its branch.** Nothing else can check that branch out
while the worktree exists. So a finished issue must be committed,
pushed, **and its worktree removed** — `git worktree remove`, then
`git worktree prune`. An agent that finishes and walks away leaves a
branch nobody else can touch, and the deadlock is silent.

**Sibling path dependencies must exist beside it.** These crates resolve
`am-fs-core` through `../rust-fs-core` at a pinned tag, so a worktree in
a scratch directory does not build until that sibling is provisioned
there too. Discovered the hard way mid-rebase; provision it with the
worktree rather than at first build failure.

Each worktree carries its own `target/`, roughly 120 MB. That is the
running cost, and it is why they get removed rather than accumulate: one
agent's scratch reached 845 MB across seven of them before anyone looked.

### An orphaned worktree is evidence that outlives the agent

The agent's queue dies with the agent. A worktree does not — and that
makes it the second detector for abandoned work, independent of the
first.

A worktree left behind with commits that were never pushed is on-disk
proof that an issue was started and not finished. Nobody has to remember
it, and no message has to have arrived. Any stage that trips over one —
the monitoring stage looking for a branch, a sweep, another fixer
claiming the same issue — can hand the issue back for dispatch.

The two detectors catch different failures, which is the point of having
both:

- **`am-ledger stale`** finds a claim that has stopped moving. It sees an
  agent that died *before* producing anything, where no worktree exists.
- **An orphaned worktree** finds work that was done and stranded. It sees
  the case where the row was released, or never claimed, but commits
  exist.

Neither subsumes the other, and each is cheap. Scan for both.

What gets resurrected is the **issue**, not the agent. A dead agent's
queue is not recoverable and should not be reconstructed; the issue goes
back to `accepted` or `failed`, the surviving branch is named in the
handoff so the work is not repeated, and whichever fixer picks it up
decides whether to build on that branch or start again.

**A worktree with work in it is never discarded.** Half-finished code is
not waste to be swept up — it is the most expensive thing in the
pipeline, because it is the part that was hard enough to still be
unfinished. It gets resurrected and completed, and then goes through the
ordinary path to a pull request like anything else.

So on finding an orphaned worktree, **preserve before judging**:

    git -C <worktree> add -A
    git -C <worktree> commit -m "wip: recovered from an abandoned worktree"
    git -C <worktree> push -u <remote> HEAD:<branch>

Commit and push first, whatever state it is in. That costs nothing, it
cannot lose anything, and it converts a deadlock that lives on one
machine's disk into a branch anyone can pick up. Only then look at
whether the work is any good.

Judging first is the mistake, and it is tempting because a half-written
change often does not compile. **A branch that does not build is still
worth more than the absence of it**, because it carries the shape of an
attempt: which files the author had decided to touch, what they had
already ruled out. Reconstructing that costs far more than reading it.

Two constraints on the agent that picks it up. It must **read the
recovered state before continuing** — a worktree abandoned mid-refactor
can be internally inconsistent in ways that are invisible if you only
read the diff of the last file touched. And it must **re-verify from
scratch**: whatever the previous agent proved, it proved about a tree
that has since had `main` move underneath it.

Remove a worktree only once its work is pushed, and pruned only once
the branch is merged or a person has said to abandon it.

    git worktree list                 # in each repo
    git worktree prune                # after removing stale ones

Prune is not optional housekeeping. A worktree entry that points at a
deleted directory still holds its branch, so the deadlock survives the
directory that caused it.

### Concurrent branches will conflict, and that is ordinary

Several issues in one repository, worked at once, will touch the same
code. The second branch to reach a pull request finds its base changed
underneath it, and its author has to rebase and resolve in a way that
satisfies both changes.

This is not a hypothetical cost of the design — it happened twice in one
day before the design existed. `rust-fs-core` #55 was made un-runnable by
#54 merging; `rust-fs-ext4` #101 by #100. **Both times nothing was wrong
with the child.**

Three things make it survivable:

- **The fixer that wrote the change resolves it.** A textual conflict can
  be settled by whoever finds it; a semantic one — where a refusal sits
  relative to two sweeps and a generation counter — cannot.
- **Verification does not survive the rebase.** Mutation evidence and
  arm-by-arm reverts describe one tree. Re-establish them, do not
  inherit them.
- **Check for the collision before merging, at branch level.** The
  ledger records each row's branch, so the overlap is visible before the
  second pull request exists — which is earlier than the pull-request
  list can see it.

## Pull requests from outside contributors

A fork pull request is the one case where the pipeline stops and a
person decides. Merging it runs someone else's code in the project and,
before that, on the project's runners. The order below is the order the
checks have to happen in, because each step invalidates the one before.

**1. Audit the diff before touching the branch.** Read it, then scan it
systematically rather than by impression:

    git diff --name-only $BASE $HEAD | grep -Ei 'Cargo\.(toml|lock)|rust-toolchain|chores\.yml'
    git diff $BASE $HEAD | grep '^+' | grep -Ei \
      'curl|wget|/dev/tcp|base64|eval|openssl|secrets\.|GITHUB_TOKEN|
       pull_request_target|uses:|cargo install|unsafe|transmute|Command::new'

What matters most is what the change *adds to the supply chain*: a new
dependency, a new third-party action, a workflow trigger change, a
network call, a reference to a secret. A diff that touches only tests,
CI steps and source, introduces no dependency and reaches no network is
a small surface however large it is.

Read the shell too. `read -r -a args <<< "$VAR"` word-splits without
evaluating, so it passes arguments; that is not the same as `eval`, and
the difference is the whole question.

**2. A green tick belongs to a commit, not to a pull request.** Before
believing one, ask what it ran on:

    gh api repos/$SLUG/actions/runs/$ID -q .head_sha

Then ask whether that combination still exists. If the branch is behind
and main has since changed the same files, the passing run tested a tree
that will not exist after the merge. In one case here every file the
pull request touched had also changed on main; the tick was real and
meaningless.

**3. Update the branch, then re-run.** `gh pr update-branch --rebase`
where it works. Where it conflicts, resolve locally in a worktree — not
in a checkout an agent may be using — and force-push with a lease naming
the sha you actually fetched:

    git push --force-with-lease=<branch>:<sha-you-fetched> <fork-url> HEAD:<branch>

A bare `--force` will silently discard a commit the contributor pushed
while you were working. `--force-with-lease` with no tracking ref fails
open with "stale info", so name the sha explicitly and refuse if the
remote has moved.

**4. Cherry-picking "the one real commit" can lose work.** If the branch
carries a merge commit, the contributor may have added things *inside*
it. Replaying only the fix commit drops those, and the suite still
reports green because what is missing is a test. Compare the function
lists of their final tree against your rebased one:

    diff <(git show $THEIRS:$FILE | grep -o 'fn [a-z_0-9]*' | sort -u) \
         <(grep -o 'fn [a-z_0-9]*' $FILE | sort -u)

That is how one restored test was found — a single name absent from a
filtered run.

**4a. Two checks on a resolution, and neither substitutes for the
other.** The function-set comparison above answers *"was anything
dropped"* — the invisible failure, since a missing test still reports
green. It says nothing about whether the file is well-formed.

A conflict boundary can bisect a function: one side ending inside one
test before its closing brace, the other ending inside a different test,
with exactly one trailing `}` that both sides want. A keep-both
resolution then passes the set comparison — 53 functions on main, 56 on
the branch, 61 in the result, nothing missing — and does not compile.
Worse, the near-miss version *does* compile: one test's body ending up
inside another passes, and is wrong.

So pair them. Set comparison for silent loss, compilation for structural
damage:

    am-slot cargo cargo test --locked --no-run

`--no-run` builds the test binaries without running them, which is the
cheap half and catches this in seconds.

The general point is worth more than the recipe: **a check can be sound
for its own question and unsound as a proxy for a larger one.** Treating
"nothing was dropped" as "this resolution is good" is the same
substitution the pipeline keeps finding elsewhere.

**5. Resolve conflicts semantically.** When main has added a guard since
the branch was cut, a textual resolution keeps one side and silently
drops the other. The right answer is often a change neither side wrote:
main's guard, with the contributor's parameter threaded through it.
Then revert each arm separately to prove both survived.

**6. Approving a held run is a decision, not a formality.** A fork's
workflow waits for approval, and approving it runs their code on your
runners. Check the held run's sha is the one you reviewed:

    gh api "repos/$SLUG/actions/runs?status=action_required" -q '.workflow_runs[0].head_sha'

Refuse if it is not. A stale held run from an older sha is common after
a rebase, and approving it runs code you did not audit.

**7. `action_required` is a claim about a moment.** A run held when you
looked may have been approved and completed hours later under the same
run id. Re-check before reporting it as blocked — twice here a stage
carried "held for approval" as a standing fact long after it had run.

## Starting a run

1. `am-ledger refresh` — populate from GitHub.
2. Launch the triage agents over disjoint repository sets, sized by
   issue count.
3. Launch the fixing agents with disjoint ownership, told to wait for
   triage per repository.
4. Launch `verify-pr` and `pr-monitor`; they idle until work arrives.
5. Launch `audit` if you want new issues discovered as the backlog
   drains.
6. Watch with `am-ledger stats`.

Completion is every row at `merged` or `rejected`. Rows at `failed` are
in flight, not finished.
