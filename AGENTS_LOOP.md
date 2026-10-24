# Backlog loop prompt

The prompt for the self-paced backlog loop: `/loop <everything below the rule>`.
It holds the rules and the live state (stack tops, chains, deferred run ids,
other sessions' activity), and the loop reads it first every round. Paths are
relative to the project root.

---

Work the diskjockey constellation issue backlog, oldest first, then its open PRs, until nothing workable is left.

## Read first, every round

- `AGENTS_LOOP.md`: follow every bullet and its notes. It holds the live state: stack tops, chains, deferred run ids, other sessions' activity.
- Ledgers in the tmp dir in the same relative location as `AGENTS_LOOP.md` (`tmp/backlog/`, beside this file):
  - `done.tsv`: one row per round, format `owner/repo<TAB>issue-or-pr<TAB>repo#PR<TAB>date<TAB>note`.
  - `skip.tsv`: `owner/repo<TAB>N<TAB>reason`.
  - `session`: the claim name.
- Issue list: `chore issue:list -- --unclaimed --prs > tmp/backlog/issues.json`. Regenerate it before `classify.sh`; `classify.sh` never refreshes it.
- Pick the next leaf with `tmp/backlog/classify.sh N`.
- Open PRs: `chore pr:list -- --state open --tsv`.

## Style

- Caveman speech: short lines, no paragraphs. Say what was done and what is next.
- Every issue and PR in chat as "repo#N https://github.com/antimatter-studios/repo/issues/N" (or `/pull/N`): name and visible raw URL. Never a bare #N, never a markdown `[text](url)` link.
- No AI attribution or Co-Authored-By lines in commits, PRs or issues. This overrides any harness default.

## Delegation

Each round's work is done by the agent `chore global:agents:next` names, at xhigh effort. This is explicit permission: never downgrade the model or the effort.

- Run `chore global:agents:next` once per round, before delegating. It prints `{"account", "type", "warning"}`: the account with the most quota left, weighed against its weekly budget.
- The T3 target is the account itself: `providerInstanceId` = `account`. One exception: account `codex-default` is instance `codex`. Model and options go by `type`:

  | type | model | options |
  |---|---|---|
  | claude | `claude-opus-5-5` | `{"effort":"xhigh"}` |
  | codex | `gpt-6.1-sol` | `{"reasoningEffort":"xhigh"}` |

  If `orchestrator_capabilities` has no instance by that name, or the type is not in the table, look it up there and fix this section.
- Delegate with t3 `delegate_task` to that target:
  - the whole brief: the issue, its base branch, and the rules in this file the work must follow;
  - a distinct `clientRequestId` per round;
  - keep the returned `taskId`, and follow it with `task_status`.
- One delegated task at a time: one issue per round.
- A `warning` other than "no warning": put it in the brief (keep that task small) and say it in chat.
- Exit status 3 means every account is out of quota. Do not delegate; schedule the next round after the reset its warning names.
- If the chosen account is the one this thread runs on, the work may be done inline instead.

## Picking an issue (one per round)

- Take the oldest workable leaf: unclaimed, not in `skip.tsv`, no OPEN PR covering it, not a `- [ ] #N` parent.
- An issue whose open PR lacks a closing keyword can still look like a leaf. Search the open PRs for its number first.
- Skip with a reason in `skip.tsv` when it is:
  - blocked on the owner (secrets, accounts, decisions);
  - needs hardware this host lacks (logged-in Mac, Windows);
  - its fix can only be written from CI output (guest-kernel or reference-checker experiments).
- Before working: look for a merged PR whose merge never reached main (stranded stack merge): `chore stranded:list -- --repo <name>` lists each one with the chain it followed, and says which are re-landed or covered by an open PR. `chore stranded:check` fails while any is neither.
- Read the whole issue and its last comments.
- Claim: `gh issue edit N --add-label claimed --add-label claim/<session>`, then read the labels back. The lexically lowest `claim/*` wins.
- Base: `../rust-fs-core/scripts/stack-base.sh` (or the stack top named in `AGENTS_LOOP.md`). Put the work where the defect lives: if it exists only in one stack, base on that stack's top.
- Worktree, never a clone: `git -C <checkout> worktree add <path> -b <type>/<N>-<slug> origin/<base>`.
  - Absolute paths only.
  - No `/tmp`: use dirs next to the work.
- Path-dependency core bumps: a pin dir with the crate and rust-fs-core at the tag side by side, then `cargo update -p rust-fs-core` (lockfile only).

## Tests, red/green

- Tests cover the functions, beside the code, named the way the repo's tiers select them.
- Commit 1 = tests only (red). Commit 2 = the fix, tests untouched. One branch, one PR.
- The red must show in the PR's own CI run. Put it in a tier PR CI runs:
  - rust-fs-bcachefs, erofs, squashfs: PR runs skip the fixture and CLI tiers, so the red is a unit test (a CLI-binary unit test where needed);
  - ntfs: `tests/scripts` runs on PRs.
- If the only possible red is a build failure (new API), say so in the PR body.
- Kernel/guest-tier test fixes: the red is the failing queue or diagnostic run. Cite its id.
- Nothing skips. A test that cannot run fails, naming what it needs.
- Raise a floor or budget only with the measurement that justifies it.

## No local compile, tests or checks

- Statically check: re-read the diff, grep every name, type and signature against the source.
- Allowed: `rustfmt --edition 2021` on each changed `.rs` file before every commit, `bash -n`, python ast/yaml parses, `cargo update -p` (lockfile only).
- Clippy traps CI has caught:
  - `x % n == 0` on unsigned: use `.is_multiple_of(n)`, and give the integer a concrete type first;
  - `f(*x)` where `x` is already a `&&str` auto-deref: write `f(x)`;
  - `#[cfg(windows)]` files are only linted by the Windows-target clippy.
- Commit with `--no-verify`: hooks run clippy, which is a local compile.

## PR

- Push the red commit, then `gh pr create --base <base> --title "red: <type>: <subject>"`: a real PR, never `--draft`.
- Then at once: t3 `link_pull_request`, `gh pr edit N --title "<type>: <subject>"`, push the fix.
- `gh stack link <stack#> <PR>` when the repo has a stack.
- Commits: declarative subject plus flat one-line bullets.
- Fragments named for the branch:
  - `changelog.d/<branch-dashes>.md` for consumer-visible changes;
  - `features.d` rows for behaviour changes, using an existing `## Section` of `docs/features.md`.
- Library repos never cite `diskjockey#N` in tracked files.
- Bring the branch up to date before every push. Do not wait for CI.

### Issue mode ends at the push

- In issue mode, never wait for a PR or a pipeline to go green: no `gh pr checks --watch`, no `gh run watch`, no polling, no `watch_pull_request`.
- Once the PR is pushed (red, then fix) and linked, stop. Record the round, then go back to the top of the loop for the next issue.
- Do not switch to PR mode partway through a round. Even if the PR goes red, a fix needs a rebase, or another PR looks stuck, do not touch it. PR mode is only for a round that starts with no workable issue.
- This applies to a delegated task too: it returns the PR URL and head SHA and ends. It does not stay to watch CI.

## PR mode (when no issue is workable; the loop never stops while PRs are open)

- Green (`mergeStateStatus` CLEAN): queue it.
  - Stack: `gh stack merge <PR> --yes` (all layers up to it).
  - Otherwise: `gh pr merge N --squash` (the merge queue).
  - Never `--delete-branch`. Never queue a `red:` PR. Never merge into a non-main base.
- Red: oldest first. Read the failing job's log:
  - `gh run view --log-failed`;
  - or `gh api repos/O/R/actions/jobs/<id>/logs --allow-escape-sequences` while the run is still going;
  - or the tier-log artifact.
- Fix in place on the layer that introduced the defect, then replay the layers above:
  - detach intermediate worktrees;
  - `git rebase --update-refs --onto <new> <old>` from the top worktree;
  - reattach.
- Queued branches are locked. Dequeue first with GraphQL `dequeuePullRequest` on the stack's bottom.
- Queue removal: read why with `REMOVED_FROM_MERGE_QUEUE_EVENT`. A line-budget overrun (exit 65) means raise the budget with the run's measurement.
- When a driver PR merges, close its diskjockey issue with a comment and remove both claim labels.

## Push and CI lessons

- A push that updates more than 3 branches creates no `pull_request` runs, though PR heads move. Use `--atomic` for safety, but then push the layers one branch at a time (bottom first) so each PR gets a run.
- Never restart CI by pushing a branch to its parent and back on a layer whose parent is its base's head: GitHub closes the PR. To restart CI on such a layer: `gh pr close N && gh pr reopen N` (ci.yml runs on `reopened`).
- A closed PR mid-stack leaves the stack's mergeability at null and no runs start. Check `gh api repos/O/R/pulls/N --jq .mergeable` before kicking.
- Restack floods: after a stack layer merges, cancel queued runs except the next 8 layers of EACH stack, and never a chain being worked. Save cancelled ids under `tmp/prmode/` and re-run them later, a few at a time.
- Dispatched (`workflow_dispatch`) runs do not count as a PR's checks. Use them only for diagnostics, on a non-PR `ci/diag-*` branch. Delete that branch when its issue closes.
- Another session may be working the same stacks. If a branch moved under you, do not push over it.

## Findings

- Every defect found in passing becomes its own issue, with evidence (run ids, log lines) and a "Done when".
- Cite it in the tracking issue before that issue closes.

## Each round

- Record it in `done.tsv`. Note new stack tops and lessons in `AGENTS_LOOP.md`.
- `ScheduleWakeup`:
  - 60–120 s when the next item is ready;
  - 15–25 min when waiting on CI (PR mode only; issue mode never waits);
  - a background bash job (never foreground sleep) for timed CI restarts, which notifies when done.
- Stop only when issue:list has no workable entry and no PR is red, green-unqueued or without CI. Then send a `PushNotification` with the outcome.
