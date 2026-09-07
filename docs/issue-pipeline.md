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

**Checking that a guard fires is not the same as checking what it is
blind to.** Build the failing case and watch it fail, then build the
cases you did not think of.

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
`<=`, `>` to `>=` — and see which mutations survive. A bound worth
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
