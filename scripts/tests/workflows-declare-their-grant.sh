#!/usr/bin/env bash
#
# workflows-declare-their-grant.sh — every workflow states the token it gets,
# and every action it runs is pinned to a commit (diskjockey#283).
#
# A workflow with no `permissions:` inherits the repository's default, so its
# grant is decided by a setting nobody reviews rather than by the file that is
# reviewed: ci.yml carried none on any of its four jobs and was read-only only
# because the default happened to be `read`. Flip the setting, or move the
# repository to an owner whose default is write, and every job gets a write
# token with no change to the code. So each workflow declares `permissions:`
# at the top, or on every one of its jobs.
#
# And an action referenced by a tag (`actions/checkout@v7`) runs whatever that
# tag points at on the day; a commit SHA is the only reference that cannot be
# moved. ci-ok's checkout was the one tag left among SHA-pinned siblings.
#
# Text, not a YAML parser: the Shell scripts job has nothing installed, and
# both rules are about lines at known indentation.
#
#   bash scripts/tests/workflows-declare-their-grant.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fails=0
ok()   { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }

# undeclared FILE -- the jobs with no grant, when the file has none at the top.
undeclared() {
    awk '
        /^permissions:/ { top = 1 }
        /^jobs:/ { in_jobs = 1; next }
        in_jobs && /^[^ #]/ { in_jobs = 0 }
        in_jobs && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ {
            if (job != "" && !granted) missing = missing " " job
            job = $1; sub(/:$/, "", job); granted = 0; next
        }
        in_jobs && /^    permissions:/ { granted = 1 }
        END {
            if (job != "" && !granted) missing = missing " " job
            if (!top) print missing
        }' "$1"
}

# unpinned FILE -- `uses:` lines whose ref is not a 40-hex commit.
unpinned() {
    grep -nE '^\s*(-\s+)?uses:\s*[^.[:space:]][^@[:space:]]*@' "$1" \
        | grep -vE '@[0-9a-f]{40}([[:space:]]|$)' || true
}

# --- 1. both checks refuse what they exist to refuse ---------------------
mkdir -p "$REPO/tmp"
SANDBOX="$(mktemp -d "$REPO/tmp/workflows-grant.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT HUP INT TERM
cat > "$SANDBOX/bad.yml" <<'YML'
on: pull_request
jobs:
  a:
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@v7
  b:
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
YML
cat > "$SANDBOX/good.yml" <<'YML'
on: pull_request
permissions:
  contents: read
jobs:
  a:
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
      - uses: ./.github/actions/local
YML
[ "$(undeclared "$SANDBOX/bad.yml" | xargs)" = "b" ] \
    && ok "a job with no grant, in a file with none at the top, is named" \
    || fail "the grant check missed job b: '$(undeclared "$SANDBOX/bad.yml")'"
[ -z "$(undeclared "$SANDBOX/good.yml" | xargs)" ] \
    && ok "a top-level grant covers every job" \
    || fail "a top-level grant was not accepted"
[ "$(unpinned "$SANDBOX/bad.yml" | grep -c .)" -eq 1 ] \
    && ok "a tag reference is refused, a SHA reference is not" \
    || fail "the pin check got: $(unpinned "$SANDBOX/bad.yml")"
[ -z "$(unpinned "$SANDBOX/good.yml")" ] \
    && ok "SHA-pinned and local actions pass" \
    || fail "a pinned or local action was refused: $(unpinned "$SANDBOX/good.yml")"

# --- 2. this repository's workflows --------------------------------------
shopt -s nullglob
workflows=("$REPO"/.github/workflows/*.yml "$REPO"/.github/workflows/*.yaml)
[ "${#workflows[@]}" -gt 0 ] || fail "no workflows found"
for wf in "${workflows[@]}"; do
    name="${wf#"$REPO"/}"
    missing="$(undeclared "$wf" | xargs)"
    [ -z "$missing" ] && ok "$name declares its grant" \
        || fail "$name has no top-level permissions, and these jobs declare none: $missing"
    loose="$(unpinned "$wf")"
    [ -z "$loose" ] && ok "$name pins every action to a commit" \
        || fail "$name references actions by a movable ref:"$'\n'"$loose"
done

echo
if [ "$fails" -eq 0 ]; then
    echo 'workflows-declare-their-grant: all checks passed'
else
    echo "workflows-declare-their-grant: $fails check(s) failed" >&2
fi
exit "$((fails > 0))"
