#!/usr/bin/env bash
# The library tier counts every case `swift test` executed, under the Swift
# that CI uses and under the next one.
#
# scripts/test-library.sh holds the run to a floor of executed cases, read
# from the log: XCTest's "Executed N tests" and swift-testing's "Test run with
# N tests". Swift 6.2 runs the whole package in one process, so each framework
# prints one total and the largest number is it. Swift 6.4 (Xcode 27) runs one
# process per test target, and each prints its own totals: a run of 841 cases
# printed nine swift-testing totals and was counted as its largest, 314, plus
# 65 XCTest -- 379 against a floor of 720, a full pass reported as a run that
# stopped early (#579).
#
# The logs below keep the lines the count reads, in each Swift's shape, and
# test-library.sh --count reads them the way it reads a real run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fails=0
ok() { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }

sb="$(mktemp -d)"
trap 'rm -rf "$sb"' EXIT

# Swift 6.2: one XCTest tree under 'All tests', then one swift-testing run.
cat > "$sb/swift-6.2.log" <<'EOF'
Test Suite 'All tests' started at 2026-10-12 10:00:00.000.
Test Suite 'DiskJockeyLibraryTests.xctest' started at 2026-10-12 10:00:00.001.
Test Suite 'BlockDeviceTests' started at 2026-10-12 10:00:00.002.
Test Suite 'BlockDeviceTests' passed at 2026-10-12 10:00:00.010.
	 Executed 40 tests, with 0 failures (0 unexpected) in 0.008 (0.009) seconds
Test Suite 'MountTests' started at 2026-10-12 10:00:00.011.
Test Suite 'MountTests' passed at 2026-10-12 10:00:00.020.
	 Executed 25 tests, with 0 failures (0 unexpected) in 0.009 (0.010) seconds
Test Suite 'DiskJockeyLibraryTests.xctest' passed at 2026-10-12 10:00:00.021.
	 Executed 65 tests, with 0 failures (0 unexpected) in 0.017 (0.019) seconds
Test Suite 'All tests' passed at 2026-10-12 10:00:00.021.
	 Executed 65 tests, with 0 failures (0 unexpected) in 0.017 (0.020) seconds
◇ Test run started.
↳ Testing Library Version: 1400
✔ Test run with 603 tests in 80 suites passed after 20.000 seconds.
EOF

# Swift 6.4: one process per test target. Targets with no XCTest cases still
# print an empty 'All tests'; each target with swift-testing cases prints its
# own run. The last target's run fails, which is still a count.
cat > "$sb/swift-6.4.log" <<'EOF'
Test Suite 'All tests' started at 2026-11-06 10:14:32.737.
Test Suite 'All tests' passed at 2026-11-06 10:14:32.740.
	 Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.002) seconds
Test Suite 'All tests' started at 2026-11-06 10:14:34.395.
Test Suite 'DiskJockeyLibraryTests.xctest' started at 2026-11-06 10:14:34.396.
Test Suite 'BlockDeviceTests' started at 2026-11-06 10:14:34.397.
Test Suite 'BlockDeviceTests' passed at 2026-11-06 10:14:34.410.
	 Executed 40 tests, with 0 failures (0 unexpected) in 0.012 (0.013) seconds
Test Suite 'MountTests' started at 2026-11-06 10:14:34.411.
Test Suite 'MountTests' passed at 2026-11-06 10:14:34.470.
	 Executed 25 tests, with 0 failures (0 unexpected) in 0.058 (0.059) seconds
Test Suite 'DiskJockeyLibraryTests.xctest' passed at 2026-11-06 10:14:34.471.
	 Executed 65 tests, with 0 failures (0 unexpected) in 0.067 (0.075) seconds
Test Suite 'All tests' passed at 2026-11-06 10:14:34.471.
	 Executed 65 tests, with 0 failures (0 unexpected) in 0.067 (0.076) seconds
Test Suite 'All tests' started at 2026-11-06 10:14:35.098.
Test Suite 'All tests' passed at 2026-11-06 10:14:35.100.
	 Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.002) seconds
Test Suite 'All tests' started at 2026-11-06 10:14:35.200.
Test Suite 'DiskJockeyAgentCoreTests.xctest' started at 2026-11-06 10:14:35.201.
Test Suite 'DiskJockeyAgentCoreTests.xctest' failed at 2026-11-06 10:14:35.300.
	 Executed 7 tests, with 1 failure (0 unexpected) in 0.099 (0.099) seconds
Test Suite 'All tests' failed at 2026-11-06 10:14:35.300.
	 Executed 7 tests, with 1 failure (0 unexpected) in 0.099 (0.100) seconds
◇ Test run started.
↳ Testing Library Version: 2403
✔ Test run with 159 tests in 10 suites passed after 1.103 seconds.
◇ Test run started.
↳ Testing Library Version: 2403
✔ Test run with 314 tests in 49 suites passed after 25.596 seconds.
◇ Test run started.
↳ Testing Library Version: 2403
✘ Test run with 30 tests in 1 suite failed after 0.007 seconds with 1 issue.
EOF

for case in "swift-6.2.log|668 = 65 XCTest + 603 swift-testing" \
            "swift-6.4.log|575 = 72 XCTest + 503 swift-testing"; do
    log="${case%%|*}"
    want="${case#*|}"
    got="$(bash "$ROOT/scripts/test-library.sh" --count "$sb/$log" 2>&1)"
    if [ "$got" = "$want" ]; then
        ok "$log counts $want"
    else
        fail "$log counts '$got', not '$want'"
    fi
done

# No log at all is no cases, never an error that reads as a count.
got="$(bash "$ROOT/scripts/test-library.sh" --count "$sb/missing.log" 2>&1)"
if [ "$got" = "0 = 0 XCTest + 0 swift-testing" ]; then
    ok "a missing log counts 0"
else
    fail "a missing log counts '$got', not 0"
fi

[ "$fails" -ne 0 ] || echo 'library-case-count: all checks passed'
exit "$((fails > 0))"
