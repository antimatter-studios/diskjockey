#!/usr/bin/env bash
# The required-check declaration must describe every pull-request job.
set -uo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
checker="$repo/scripts/check-required-checks.rb"
sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT
fails=0

ok() { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }

case_dir() {
    local name="$1"
    CASE_DIR="$sandbox/$name"
    mkdir -p "$CASE_DIR/.github/workflows"
    cat > "$CASE_DIR/.github-guard" <<'GUARD'
[checks]
    required = Build
GUARD
    cat > "$CASE_DIR/.github/workflows/ci.yml" <<'WORKFLOW'
on:
  pull_request:
jobs:
  build:
    name: Build
    runs-on: ubuntu-latest
    steps:
      - run: 'true'
WORKFLOW
}

run_case() {
    OUT="$(ruby "$checker" "$CASE_DIR" 2>&1)"
    RC=$?
}

case_dir matching
run_case
if [ "$RC" -eq 0 ]; then ok 'matching required job passes'; else fail "matching job refused: $OUT"; fi

case_dir renamed
sed -i 's/name: Build/name: Compile/' "$CASE_DIR/.github/workflows/ci.yml"
run_case
if [ "$RC" -ne 0 ] && [[ "$OUT" == *'no pull-request job produces: Build'* ]] && [[ "$OUT" == *'undeclared pull-request job: Compile'* ]]; then
    ok 'a renamed job reports both sides of the mismatch'
else
    fail "renamed job accepted or poorly diagnosed: $OUT"
fi

case_dir added
cat >> "$CASE_DIR/.github/workflows/ci.yml" <<'WORKFLOW'
  docs:
    name: Docs
    runs-on: ubuntu-latest
    steps:
      - run: 'true'
WORKFLOW
run_case
if [ "$RC" -ne 0 ] && [[ "$OUT" == *'undeclared pull-request job: Docs'* ]]; then
    ok 'a new job must be declared'
else
    fail "new job accepted: $OUT"
fi

git -C "$repo" config -f "$CASE_DIR/.github-guard" --add checks.advisory Docs
run_case
if [ "$RC" -eq 0 ]; then
    ok 'an explicit advisory declaration permits the job'
else
    fail "advisory job refused: $OUT"
fi

case_dir phantom_advisory
git -C "$repo" config -f "$CASE_DIR/.github-guard" --add checks.advisory Missing
run_case
if [ "$RC" -ne 0 ] && [[ "$OUT" == *'advisory check has no pull-request job: Missing'* ]]; then
    ok 'a stale advisory declaration fails'
else
    fail "stale advisory accepted: $OUT"
fi

case_dir tag_only
sed -i 's/pull_request:/push:\n    tags: ["v*"]/' "$CASE_DIR/.github/workflows/ci.yml"
run_case
if [ "$RC" -ne 0 ] && [[ "$OUT" == *'no pull-request job produces: Build'* ]]; then
    ok 'a tag-only job cannot satisfy a required check'
else
    fail "tag-only job accepted: $OUT"
fi

case_dir matrix
cat > "$CASE_DIR/.github-guard" <<'GUARD'
[checks]
    required = Test / ubuntu-latest
    required = Test / macos-latest
GUARD
cat > "$CASE_DIR/.github/workflows/ci.yml" <<'WORKFLOW'
on: [pull_request]
jobs:
  test:
    name: Test / ${{ matrix.os }}
    strategy:
      matrix:
        os: [ubuntu-latest, macos-latest]
    runs-on: ${{ matrix.os }}
    steps:
      - run: 'true'
WORKFLOW
run_case
if [ "$RC" -eq 0 ]; then
    ok 'literal matrix legs match their check names'
else
    fail "matrix legs refused: $OUT"
fi
sed -i 's/required = Test \/ macos-latest/required = Test \/ windows-latest/' "$CASE_DIR/.github-guard"
run_case
if [ "$RC" -ne 0 ] && [[ "$OUT" == *'no pull-request job produces: Test / windows-latest'* ]]; then
    ok 'matrix drift is detected'
else
    fail "matrix drift accepted: $OUT"
fi

case_dir default_matrix_name
cat > "$CASE_DIR/.github-guard" <<'GUARD'
[checks]
    required = test (ubuntu-latest)
    required = test (macos-latest)
GUARD
cat > "$CASE_DIR/.github/workflows/ci.yml" <<'WORKFLOW'
on: [pull_request]
jobs:
  test:
    strategy:
      matrix:
        os: [ubuntu-latest, macos-latest]
    runs-on: ${{ matrix.os }}
    steps:
      - run: 'true'
WORKFLOW
run_case
if [ "$RC" -eq 0 ]; then
    ok 'unnamed matrix legs use GitHub default names'
else
    fail "unnamed matrix legs refused: $OUT"
fi

sed -i '/os: \[ubuntu-latest, macos-latest\]/a\        include: [{os: windows-latest}]' \
    "$CASE_DIR/.github/workflows/ci.yml"
run_case
if [ "$RC" -ne 0 ] && [[ "$OUT" == *'matrix include/exclude needs explicit review'* ]]; then
    ok 'unsupported matrix expansion fails closed'
else
    fail "matrix expansion accepted: $OUT"
fi

case_dir current_repository
cp "$repo/.github-guard" "$CASE_DIR/.github-guard"
cp "$repo/.github/workflows/"*.yml "$CASE_DIR/.github/workflows/"
run_case
if [ "$RC" -eq 0 ]; then
    ok 'the repository declaration matches all PR workflows'
else
    fail "repository declaration drifted: $OUT"
fi

echo
if [ "$fails" -eq 0 ]; then
    echo 'required-checks-match-jobs: all checks passed'
else
    echo "required-checks-match-jobs: $fails check(s) failed" >&2
fi
exit "$((fails > 0))"
