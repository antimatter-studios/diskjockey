#!/usr/bin/env bash
#
# test-app.sh — the app tier: the app-hosted DiskJockeyTests bundle through
# xcodebuild, the way the `Build & Test` CI job runs it and `chore test:app`
# does (#211). Needs Xcode, a macOS 15.4+ host, the vendored libraries
# (`make vendor-all`) and, locally, a GUI session: app-hosted tests abort in
# a background session.
#
# Quiet by default: the RAW xcodebuild stream goes to tmp/logs/app.log through
# scripts/quiet-run.sh — raw, because when this fails it is as often a link
# error or a signing refusal as a test, and only the raw stream has those. The
# terminal gets the verdict and the count. `--verbose` (or
# OUTPUT_BUDGET_VERBOSE=1) streams the run through xcbeautify when it is
# installed, and is held to the same budget.
#
# The result bundle is written to tmp/logs/app.xcresult and replaced on each
# run: xcodebuild refuses a -resultBundlePath that already exists.
#
# ONLY DiskJockeyTests. The library bundle is covered host-free by
# scripts/test-library.sh; launching it here as well added a second app-hosted
# harness lifecycle, and run 34949058950's bundle showed that one waiting
# 241 seconds and never confirming shutdown before the step ceiling.
#
# UNSIGNED, AND THE AD-HOC ALTERNATIVE WAS MEASURED WORSE. Ad-hoc signing
# APPLIES THE ENTITLEMENTS, DiskJockey's include the App Sandbox, and a
# sandboxed binary no profile authorises is refused at spawn — every time, in
# about five seconds, with RunningBoard error 5. Not signing at all never
# applies them, which is why this launches at least some of the time (#139).
#
# THE COUNT COMES FROM THE RESULT BUNDLE, NOT THE OUTPUT. Two text-derived
# counts were wrong in a row: one matched both renderings of a case and read
# 273 for 250, the other matched only swift-testing's and read 222. The bundle
# carries passedTests / failedTests / result as data. A missing or unreadable
# bundle yields 0, which the floor refuses — the right answer when xcodebuild
# died before writing one. And the bundle's own verdict is compared too: the
# floor and the exit status have disagreed with it before.
#
#   scripts/test-app.sh [--verbose]
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2
mkdir -p "$ROOT/tmp/logs"
rm -rf "$ROOT/tmp/logs/app.xcresult"

render=()
command -v xcbeautify >/dev/null 2>&1 && render=(--render xcbeautify)

rc=0
scripts/quiet-run.sh ${render[@]+"${render[@]}"} "$@" app 20000 3000000 -- \
    xcodebuild test \
        -project DiskJockey.xcodeproj \
        -scheme DiskJockey \
        -destination 'platform=macOS,arch=arm64' \
        -only-testing:DiskJockeyTests \
        -skip-testing DiskJockeyUITests \
        ONLY_ACTIVE_ARCH=YES \
        ARCHS=arm64 \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGN_IDENTITY="" \
        CODE_SIGNING_ALLOWED=NO \
        -resultBundlePath "$ROOT/tmp/logs/app.xcresult" \
    || rc=$?

summary=$(xcrun xcresulttool get test-results summary \
            --path "$ROOT/tmp/logs/app.xcresult" --format json 2>/dev/null || true)
executed=$(printf '%s' "$summary" | jq '(.passedTests//0)+(.failedTests//0)+(.expectedFailures//0)' 2>/dev/null || true)
verdict=$(printf '%s' "$summary" | jq -r '.result // "no result bundle"' 2>/dev/null || true)
echo "executed cases: ${executed:-0} (floor 160), bundle verdict: ${verdict:-unknown}"
if [ "${executed:-0}" -lt 160 ]; then
    echo "::error::only ${executed:-0} app-hosted test cases executed, floor is 160 — 160 ran in the first isolated-bundle measurement (run 34962911163), and a run that stops early reports no failures, so this is the truncation defect (diskjockey#139) rather than a pass"
    exit 1
fi
if [ "${verdict:-}" != "Passed" ]; then
    echo "::error::the result bundle reports ${verdict:-unknown} rather than Passed"
    exit 1
fi
exit "$rc"
