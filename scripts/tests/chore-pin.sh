#!/usr/bin/env bash
#
# chore-pin.sh (test) — the chore this repository installs is named once, and
# SIBLING_PINS.txt says what that pin is for (diskjockey#79).
#
# check-chore-pin.sh derives its root from its own path, so each case copies it
# into a scratch tree with fixture files. The real repository runs first.
#
#   bash scripts/tests/chore-pin.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fails=0
sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT

ok()   { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }

# The install step as ci.yml and release.yml write it.
good_step() {
    cat <<'EOF'
jobs:
  build:
    steps:
      - name: Install chore
        run: |
          ver=$(awk '$1=="chore"{print $2}' SIBLING_PINS.txt)
          curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 \
            "https://github.com/antimatter-studios/chore/releases/download/v${ver}/chore-${ver}-darwin-arm64.tar.gz" \
            | tar -xz -C /usr/local/bin chore
EOF
}

# tree <case> <pins body> <floor line> <workflow body>: run the checker there.
tree() {
    local d="$sandbox/$1"
    mkdir -p "$d/scripts" "$d/.github/workflows"
    cp "$REPO/scripts/check-chore-pin.sh" "$d/scripts/" 2>/dev/null
    printf '%s\n' "$2" > "$d/SIBLING_PINS.txt"
    printf 'version: "3"\n%s\n' "$3" > "$d/chores.yml"
    printf '%s\n' "$4" > "$d/.github/workflows/ci.yml"
    OUT="$(bash "$d/scripts/check-chore-pin.sh" 2>&1)"; RC=$?
}
refused() { # label, expected fragment
    if [ "$RC" != 0 ] && [[ "$OUT" == *"$2"* ]]; then ok "$1"
    else fail "$1 (rc=$RC): $OUT"; fi
}

echo "chore-pin: SIBLING_PINS.txt names the chore this repository installs, once"

OUT="$(bash "$REPO/scripts/check-chore-pin.sh" 2>&1)"; RC=$?
[ "$RC" = 0 ] && ok "this repository passes: $OUT" || fail "this repository was refused (rc=$RC): $OUT"

tree control 'chore 0.8.0' 'chore_min_version: 0.6.0' "$(good_step)"
[ "$RC" = 0 ] && ok "control: a pinned install above the floor passes" || fail "control refused (rc=$RC): $OUT"

tree at-floor 'chore 0.6.0' 'chore_min_version: 0.6.0' "$(good_step)"
[ "$RC" = 0 ] && ok "a pin equal to the floor passes" || fail "a pin equal to the floor was refused: $OUT"

tree quoted-floor 'chore 0.8.0' 'chore_min_version: "0.6.0"' "$(good_step)"
[ "$RC" = 0 ] && ok "a quoted floor is read" || fail "a quoted floor was refused: $OUT"

tree below-floor 'chore 0.8.0' 'chore_min_version: 0.10.0' "$(good_step)"
refused "a pin below the floor is refused, compared numerically not as text" "below chores.yml's chore_min_version 0.10.0"

tree no-pin 'go-networkfs v0.1.4' 'chore_min_version: 0.6.0' "$(good_step)"
refused "a missing pin is refused" "exactly once, found 0"

tree two-pins "$(printf 'chore 0.8.0\nchore 0.9.0')" 'chore_min_version: 0.6.0' "$(good_step)"
refused "a second pin is refused" "exactly once, found 2"

tree branch-pin 'chore main' 'chore_min_version: 0.6.0' "$(good_step)"
refused "a pin that is not a release is refused" "not a release version"

tree no-floor 'chore 0.8.0' '' "$(good_step)"
refused "a missing floor is refused" "no chore_min_version"

tree literal 'chore 0.8.0' 'chore_min_version: 0.6.0' "$(good_step)
      - run: curl -fsSL https://github.com/antimatter-studios/chore/releases/download/v0.9.0/chore-0.9.0-darwin-arm64.tar.gz | tar -xz"
refused "a workflow downloading a literal version is refused" "by a literal version"

tree unread 'chore 0.8.0' 'chore_min_version: 0.6.0' 'jobs:
  build:
    steps:
      - run: curl -fsSL "https://github.com/antimatter-studios/chore/releases/download/v${CHORE}/chore-${CHORE}-darwin-arm64.tar.gz"'
refused "a workflow that does not read the pin is refused" "without reading its version from SIBLING_PINS.txt"

tree brew 'chore 0.8.0' 'chore_min_version: 0.6.0' "$(good_step)
      - run: brew install antimatter-studios/tap/chore"
refused "a tap install beside the pinned one is refused" "from a tap"

tree cargo 'chore 0.8.0' 'chore_min_version: 0.6.0' "$(good_step)
      - run: cargo install --git https://github.com/antimatter-studios/chore chore"
refused "a cargo install is refused" "cargo install"

# GitHub's release download answers an occasional HTTP 500, and a download
# with no retry turns that one answer into a red job before anything under
# test has run (rust-fs-ext4#494, rust-fs-btrfs#286).
tree no-retry 'chore 0.8.0' 'chore_min_version: 0.6.0' 'jobs:
  build:
    steps:
      - run: |
          ver=$(awk '"'"'$1=="chore"{print $2}'"'"' SIBLING_PINS.txt)
          curl -fsSL "https://github.com/antimatter-studios/chore/releases/download/v${ver}/chore-${ver}-darwin-arm64.tar.gz" \
            | tar -xz -C /usr/local/bin chore'
refused "a download that does not retry a transient server error is refused" "transient HTTP 5xx"

tree few-retries 'chore 0.8.0' 'chore_min_version: 0.6.0' "$(good_step | sed 's/--retry 5/--retry 1/')"
refused "a download that retries fewer than three times is refused" "transient HTTP 5xx"

tree some-errors-only 'chore 0.8.0' 'chore_min_version: 0.6.0' "$(good_step | sed 's/--retry-all-errors //')"
refused "a download that retries only some errors is refused" "transient HTTP 5xx"

tree nothing 'chore 0.8.0' 'chore_min_version: 0.6.0' 'jobs: {}'
refused "a pin no workflow installs is refused" "honoured by nothing"

# The pin is diskjockey's, not the family's (#79 took the per-repository floor
# remedy). SIBLING_PINS.txt has to say so, or it goes on asserting a version
# for projects that never read it.
if grep -q "^# This pin is this repository's own" "$REPO/SIBLING_PINS.txt" \
   && grep -q "^# not a version for the family" "$REPO/SIBLING_PINS.txt"; then
    ok "SIBLING_PINS.txt scopes the chore pin to this repository"
else
    fail "SIBLING_PINS.txt does not say the chore pin is this repository's own, not the family's"
fi

echo
if [ "$fails" -eq 0 ]; then
    echo 'chore-pin: all checks passed'
else
    echo "chore-pin: $fails check(s) failed" >&2
fi
exit "$((fails > 0))"
