#!/usr/bin/env bash
#
# test-tiers.sh — CI and a developer run the same three test tiers, quietly,
# and every run keeps its logs (#211).
#
# Before this, `swift test` and `xcodebuild test` printed ~900 lines each on a
# green run, tee'd them to $RUNNER_TEMP and threw them away, and chores.yml had
# no test task at all, so a developer got the firehose and CI's floors lived
# only inside ci.yml. What is asserted:
#
#   - each tier is a script, and chores.yml and ci.yml both run THAT script,
#     so there is one command per tier rather than two that drift;
#   - each tier runs its suite through scripts/quiet-run.sh with a numeric
#     line and byte budget, and those budgets are the ones chores.yml's table
#     records, so the measurement and the number enforced cannot part;
#   - all three CI jobs upload tmp/logs/ with `if: always()`, so a green run
#     keeps its log as well as a red one;
#   - the scripts tier refuses a failing script, a truncated one and a glob
#     under its floor, driven below in a scratch tree.
#
#   bash scripts/tests/test-tiers.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORKFLOW="$REPO/.github/workflows/ci.yml"
CHORES="$REPO/chores.yml"
fails=0
sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT

ok()   { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }

command -v ruby >/dev/null 2>&1 || { echo "test-tiers: ruby is required to parse the workflow" >&2; exit 1; }

echo "test-tiers: one script per tier, run by CI and chore alike, logs always kept"

# tier  script                  CI job           chore task
tiers='scripts  scripts/test-scripts.sh  scripts        check:scripts
library  scripts/test-library.sh  library-tests  test:library
app      scripts/test-app.sh      test           test:app'

while read -r tier script job task; do
    [ -n "$tier" ] || continue
    if [ -x "$REPO/$script" ]; then ok "$tier: $script exists and is executable"
    else fail "$tier: $script is missing or not executable"; continue; fi

    # The suite goes through the wrapper with two numeric budgets.
    budget="$(grep -oE "quiet-run\.sh[^\\\\]* $tier [0-9]+ [0-9]+ --" "$REPO/$script" | head -1 | awk '{for (i = 1; i <= NF; i++) if ($i == "'"$tier"'") { print $(i + 1), $(i + 2); exit }}')"
    if [ -n "$budget" ]; then ok "$tier: runs through quiet-run.sh with budget $budget"
    else fail "$tier: $script does not run its suite through quiet-run.sh with a line and byte budget"; fi

    # chores.yml's budget table names the same numbers.
    row="$(grep -E "^#[[:space:]]+$tier[[:space:]]+[0-9]+[[:space:]]+[0-9]+" "$CHORES" | head -1 | awk '{print $3, $4}')"
    if [ -n "$budget" ] && [ "$row" = "$budget" ]; then ok "$tier: chores.yml's table records the same budget"
    else fail "$tier: chores.yml's budget table says '${row:-nothing}' where $script enforces '${budget:-nothing}'"; fi

    # CI runs the script.
    if ruby -ryaml -e '
        d = YAML.safe_load(File.read(ARGV[0]), aliases: true)
        steps = ((d["jobs"] || {})[ARGV[1]] || {})["steps"] || []
        exit(steps.any? { |s| s["run"].to_s.lines.reject { |l| l.lstrip.start_with?("#") }.join.include?(ARGV[2]) } ? 0 : 1)
    ' "$WORKFLOW" "$job" "$script" 2>/dev/null; then ok "$tier: the '$job' CI job runs $script"
    else fail "$tier: the '$job' CI job does not run $script, so CI and a developer run different things"; fi

    # CI keeps the logs whatever the result.
    if ruby -ryaml -e '
        d = YAML.safe_load(File.read(ARGV[0]), aliases: true)
        steps = ((d["jobs"] || {})[ARGV[1]] || {})["steps"] || []
        exit(steps.any? { |s| s["uses"].to_s.include?("actions/upload-artifact") &&
                              s["if"].to_s.gsub(/\s/, "") =~ /\A(\$\{\{)?always\(\)(\}\})?\z/ &&
                              s.fetch("with", {})["path"].to_s.lines.map(&:strip).include?("tmp/logs/") } ? 0 : 1)
    ' "$WORKFLOW" "$job" 2>/dev/null; then ok "$tier: the '$job' job uploads tmp/logs/ with if: always()"
    else fail "$tier: the '$job' job does not upload tmp/logs/ with if: always(), so a green run keeps nothing"; fi

    # chore runs the script.
    if ruby -ryaml -e '
        d = YAML.safe_load(File.read(ARGV[0]), aliases: true)
        t = (d["tasks"] || {})[ARGV[1]] or exit 1
        exit(Array(t["cmds"]).any? { |c| c.to_s.include?(ARGV[2]) } ? 0 : 1)
    ' "$CHORES" "$task" "$script" 2>/dev/null; then ok "$tier: chore $task runs $script"
    else fail "$tier: chore $task does not run $script"; fi
done <<EOF
$tiers
EOF

# `chore test` is all three, in the order a failure is cheapest to find.
if ruby -ryaml -e '
    d = YAML.safe_load(File.read(ARGV[0]), aliases: true)
    t = (d["tasks"] || {})["test"] or exit 1
    cmds = Array(t["cmds"]).map(&:to_s)
    want = %w[scripts/test-scripts.sh scripts/test-library.sh scripts/test-app.sh]
    idx = want.map { |w| cmds.index { |c| c.include?(w) } }
    exit(idx.none?(&:nil?) && idx == idx.sort ? 0 : 1)
' "$CHORES" 2>/dev/null; then ok "chore test runs scripts, then library, then app"
else fail "chore test does not run all three tiers in order"; fi

# ---------------------------------------------- the scripts tier, driven
# A scratch tree with its own scripts/tests/. The floor is read from the
# script, so the passing case builds exactly that many passing tests.
floor="$(grep -oE '^FLOOR=[0-9]+' "$REPO/scripts/test-scripts.sh" 2>/dev/null | cut -d= -f2)"
if [ -n "$floor" ] && [ "$floor" -ge 24 ]; then ok "the scripts tier's floor is $floor, not under the 24 measured on 2026-09-29"
else fail "the scripts tier has no FLOOR= at or above 24 (got '${floor:-nothing}')"; floor=24; fi

# tree <case> <passing count>: a scratch tree with that many passing tests.
tree() {
    local d="$sandbox/$1" i
    mkdir -p "$d/scripts/tests"
    cp "$REPO/scripts/test-scripts.sh" "$REPO/scripts/quiet-run.sh" "$d/scripts/" 2>/dev/null
    for i in $(seq 1 "$2"); do
        printf 'echo "t%s: all checks passed"\n' "$i" > "$d/scripts/tests/t$i.sh"
    done
    D="$d"
}
tier() { OUT="$(cd "$D" && bash scripts/test-scripts.sh 2>&1)"; RC=$?; }

tree pass "$floor"; tier
if [ "$RC" = 0 ] && [ "$(printf '%s\n' "$OUT" | grep -c .)" -le 3 ]; then ok "a tree of $floor passing tests passes, in at most three lines"
else fail "the scripts tier refused $floor passing tests or was loud (rc=$RC): $OUT"; fi
[ -s "$D/tmp/logs/scripts.log" ] && ok "and keeps the whole transcript in tmp/logs/scripts.log" || fail "the scripts tier kept no log"

tree short "$((floor - 1))"; tier
case "$RC:$OUT" in 0:*) fail "$((floor - 1)) tests passed a floor of $floor" ;;
    *"floor is $floor"*) ok "a glob under the floor is refused, naming the floor" ;;
    *) fail "a glob under the floor was refused without naming it: $OUT" ;; esac

tree broken "$floor"; printf 'echo "FAIL  something real"\nexit 3\n' > "$D/scripts/tests/t1.sh"; tier
case "$RC:$OUT" in 0:*) fail "a script exiting 3 passed the tier" ;;
    *"t1.sh exited 3"*"FAIL  something real"*) ok "a failing script is refused, naming it and its FAIL line" ;;
    *) fail "a failing script was refused without naming it: $OUT" ;; esac

tree truncated "$floor"; printf 'echo "ok    half of it"\nexit 0\n' > "$D/scripts/tests/t2.sh"; tier
case "$RC:$OUT" in 0:*) fail "a script that exited 0 without its summary line passed the tier" ;;
    *"t2.sh"*"truncated"*) ok "a script that exits 0 without 't2: all checks passed' is refused as truncated" ;;
    *) fail "a truncated script was refused without saying so: $OUT" ;; esac

echo
if [ "$fails" -eq 0 ]; then
    echo 'test-tiers: all checks passed'
else
    echo "test-tiers: $fails check(s) failed" >&2
fi
exit "$((fails > 0))"
