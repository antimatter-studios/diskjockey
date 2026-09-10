#!/usr/bin/env bash
#
# library-tests-need-no-host.sh — the library gate runs nothing and signs nothing.
#
# WHAT THIS PROTECTS, AND WHY IT IS NOT OBVIOUS.
#
# `xcodebuild test` cannot run a test bundle without launching a process to
# host it. An .xctest bundle is a dylib: with TEST_HOST set the host is
# DiskJockey.app, and without it xcodebuild substitutes its own `xctest`
# runner and launches THAT through RunningBoard. On 2026-09-10 both were
# refused on the CI runner:
#
#     Could not launch "DiskJockeyTests".      Runningboard returned error 5
#     Could not launch "DiskJockeyLibraryTests". Runningboard returned error 5
#       (Underlying Error: Launchd job spawn failed)
#
# The second line is the load-bearing one. DiskJockeyLibraryTests has no app,
# no UI and no extensions, and it still failed to launch — so the first
# attempt at this gate, an `xcodebuild test -scheme DiskJockeyLibraryOnly`
# job, failed for exactly the reason it was written to avoid. The launch is
# xcodebuild's, not the app's, and no arrangement of schemes or signing flags
# removes it.
#
# `swift test` links the test code into a binary and runs it: no launch
# service, no launchd job, nothing to sign. That is the property this file
# defends, because it is easy to "fix" a red library job by reaching for
# xcodebuild again.
#
# TEXT ONLY, DELIBERATELY. This runs in the `Shell scripts` job on ubuntu,
# where there is no Swift toolchain and no Xcode. It asserts what the
# workflow and the manifest SAY, not what a build does; the build is the
# `Library tests` job's own business.
#
#   bash scripts/tests/library-tests-need-no-host.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORKFLOW="$REPO/.github/workflows/ci.yml"
MANIFEST="$REPO/Package.swift"
PBXPROJ="$REPO/DiskJockey.xcodeproj/project.pbxproj"
fails=0

ok()   { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1" >&2; fails=$((fails + 1)); }

command -v ruby >/dev/null 2>&1 || {
    echo "library-tests-need-no-host: ruby is required to parse the workflow" >&2
    exit 1
}

# ------------------------------------------------------------- the manifest
if [ -f "$MANIFEST" ]; then
    ok "Package.swift exists"
else
    fail "no Package.swift: without it there is no way to run the library suite that does not launch a test runner"
    echo "library-tests-need-no-host: $fails check(s) failed" >&2
    exit 1
fi

manifest="$(cat "$MANIFEST")"

# The paths are what make this a mirror of the Xcode targets rather than a
# copy of them. A `path:` naming a directory that does not exist is a manifest
# that fails to resolve, and the failure reads as a toolchain problem.
for dir in DiskJockeyLibrary DiskJockeyLibraryTests; do
    case "$manifest" in
        *"path: \"$dir\""*)
            if [ -d "$REPO/$dir" ]; then
                ok "the manifest points at $dir/, which exists"
            else
                fail "the manifest names path \"$dir\" but $REPO/$dir is not a directory"
            fi ;;
        *) fail "the manifest declares no target at path \"$dir\": the SwiftPM targets are meant to be the same source as the Xcode ones, not a second copy" ;;
    esac
done

# ----------------------------------------------- and it does not drift apart
# THE TWO SETTINGS THAT MATTER ARE NOT CHOICES. They mirror the Xcode library
# target, and both were measured wrong on the first attempt:
#
#   platforms — at .macOS(.v15) the library did not compile at all, because
#               FSItem and FSStatFSResult are macOS 15.4+. Six errors of the
#               form "'FSItem' is only available in macOS 15.4 or newer" on
#               sources that build fine in Xcode.
#   language  — swift-tools-version 6.0 defaults to Swift 6 language mode,
#               which rejected FileIDCache ("type 'Item' does not conform to
#               the 'Sendable' protocol"). The Xcode target is SWIFT_VERSION
#               5.0, so Swift 6 mode here is a stricter gate than the product
#               is built with, and its failures are not defects.
#
# So both are read out of project.pbxproj and compared, target setting first
# and project-level fallback second — which is how Xcode resolves them.
resolve_setting() {
    # $1 = setting name. Prints the DiskJockeyLibrary target's value if it
    # sets one, else the project-level value.
    python3 - "$PBXPROJ" "$1" <<'PY'
import re, sys
src, setting = sys.argv[1], sys.argv[2]
s = open(src).read()
def settings_of(bid):
    m = re.search(re.escape(bid) + r' /\* \w+ \*/ = \{\n\t+isa = XCBuildConfiguration;\n\t+buildSettings = \{(.*?)\n\t+\};', s, re.S)
    return m.group(1) if m else ""
def value(body):
    m = re.search(re.escape(setting) + r' = ([^;]+);', body)
    return m.group(1).strip('"') if m else None
target = re.search(r'/\* DiskJockeyLibrary \*/ = \{\n\t+isa = PBXNativeTarget;\n\t+buildConfigurationList = ([0-9A-F]{24})', s)
got = None
if target:
    lst = re.search(re.escape(target.group(1)) + r' /\*.*?\*/ = \{\n\t+isa = XCConfigurationList;\n\t+buildConfigurations = \((.*?)\);', s, re.S)
    for bid, _ in re.findall(r'([0-9A-F]{24}) /\* (\w+) \*/', lst.group(1) if lst else ""):
        got = got or value(settings_of(bid))
# The DEFINITION of the project's configuration list, not the reference to it
# from PBXProject: both lines carry the same comment, and matching the
# reference walks forward into whichever target happens to be declared next.
proj = re.search(r'\n\t+[0-9A-F]{24} /\* Build configuration list for PBXProject [^*]*\*/ = \{.*?buildConfigurations = \((.*?)\);', s, re.S)
if got is None and proj:
    for bid, _ in re.findall(r'([0-9A-F]{24}) /\* (\w+) \*/', proj.group(1)):
        got = got or value(settings_of(bid))
print(got if got else "")
PY
}

want_deploy="$(resolve_setting MACOSX_DEPLOYMENT_TARGET)"
if [ -z "$want_deploy" ]; then
    fail "could not read MACOSX_DEPLOYMENT_TARGET for the DiskJockeyLibrary target out of project.pbxproj, so the drift check below asserted nothing"
elif grep -qF ".macOS(\"$want_deploy\")" "$MANIFEST"; then
    ok "the manifest's macOS floor is $want_deploy, the same as the Xcode library target"
else
    got="$(grep -oE '\.macOS\([^)]*\)' "$MANIFEST" | head -1)"
    fail "the manifest says ${got:-nothing} where the Xcode library target says $want_deploy: a lower floor rejects FSKit calls Xcode accepts, and a higher one hides them"
fi

# EVERY TARGET, NOT ONE. This was first written as a single grep for
# `.swiftLanguageMode(.v5)` anywhere in the manifest, and the arm that removed
# it from one of the two targets passed the check: the other occurrence
# satisfied the grep. The mode is per-target in SwiftPM, so a test target left
# in Swift 6 mode compiles under different rules from the library it tests.
# Count both and require them equal.
want_swift="$(resolve_setting SWIFT_VERSION)"
declared_targets="$(grep -cE '^[[:space:]]+\.(target|testTarget)\(' "$MANIFEST")"
declared_v5="$(grep -cF ".swiftLanguageMode(.v5)" "$MANIFEST")"
case "$want_swift" in
    "")  fail "could not read SWIFT_VERSION for the DiskJockeyLibrary target out of project.pbxproj" ;;
    5*)  if [ "$declared_targets" -gt 0 ] && [ "$declared_v5" -eq "$declared_targets" ]; then
             ok "all $declared_targets manifest targets build in Swift 5 language mode, matching SWIFT_VERSION $want_swift"
         else
             fail "SWIFT_VERSION is $want_swift in Xcode but only $declared_v5 of $declared_targets manifest targets set .swiftLanguageMode(.v5): swift-tools-version 6.0 defaults to Swift 6 mode, which rejects code the product is built with"
         fi ;;
    6*)  if [ "$declared_v5" -gt 0 ]; then
             fail "Xcode has moved to SWIFT_VERSION $want_swift but $declared_v5 manifest target(s) still pin Swift 5 language mode, so this gate is now weaker than the build"
         else
             ok "both are on Swift 6 language mode"
         fi ;;
    *)   fail "unrecognised SWIFT_VERSION '$want_swift'; teach this check what to compare against" ;;
esac

# ------------------------------------------------------------------ the job
run="$(ruby -ryaml -e '
  d = YAML.safe_load(File.read(ARGV[0]), aliases: true)
  job = (d["jobs"] || {})["library-tests"]
  abort unless job
  s = (job["steps"] || []).find { |x| x["run"].to_s.include?("swift test") }
  print s ? s["run"] : ""
' "$WORKFLOW" 2>/dev/null)"

if [ -n "$run" ]; then
    ok "the library-tests job runs \`swift test\`"
else
    fail "the library-tests job has no step running \`swift test\`: every other way of running this bundle launches a test runner, which is the failure it exists to avoid"
fi

# THE POINT OF THE WHOLE FILE. Reaching for xcodebuild in this job puts the
# RunningBoard launch back, and the job goes red for a reason that has nothing
# to do with the library.
whole_job="$(ruby -ryaml -e '
  d = YAML.safe_load(File.read(ARGV[0]), aliases: true)
  job = (d["jobs"] || {})["library-tests"] || {}
  print (job["steps"] || []).map { |s| s["run"].to_s }.join("\n")
' "$WORKFLOW" 2>/dev/null)"
case "$whole_job" in
    *"xcodebuild test"*)
        fail "the library-tests job runs \`xcodebuild test\` again: that launches a test runner through RunningBoard, which is what error 5 refused on 2026-09-10 even for the host-free bundle" ;;
    *)  ok "and does not launch anything through xcodebuild" ;;
esac

# Nothing here should be signing, because nothing here is launched. An ad-hoc
# identity was tried on the app-hosted job the same day and made it worse:
# CODE_SIGN_IDENTITY="-" applies the entitlements, and a sandboxed app whose
# entitlements are not authorised is refused at spawn.
case "$whole_job" in
    *CODE_SIGN*) fail "the library-tests job passes a code-signing setting; a \`swift test\` binary is not signed and not launched, so a signing flag here is cargo" ;;
    *)           ok "and signs nothing" ;;
esac

# ------------------------------------------------------------ and it is bound
job_bound="$(ruby -ryaml -e 'd=YAML.load_file(ARGV[0]); print(((d["jobs"]||{})["library-tests"]||{})["timeout-minutes"].to_i)' "$WORKFLOW" 2>/dev/null)"
if [ "${job_bound:-0}" -gt 0 ] 2>/dev/null; then
    ok "the library-tests job has a ceiling of ${job_bound} minutes"
else
    fail "the library-tests job has no timeout-minutes: a hang outside a bounded step runs to GitHub's 360-minute default at 10x macOS billing"
fi

step_bound="$(ruby -ryaml -e '
  d = YAML.load_file(ARGV[0])
  s = (((d["jobs"]||{})["library-tests"]||{})["steps"]||[]).find { |x| x["run"].to_s.include?("swift test") }
  print s ? s["timeout-minutes"].to_i : 0
' "$WORKFLOW" 2>/dev/null)"
if [ "${step_bound:-0}" -gt 0 ] 2>/dev/null; then
    ok "and the step that runs the suite is bounded at ${step_bound} minutes"
else
    fail "the step running \`swift test\` has no timeout-minutes, so a bound that fires cannot say which step it was"
fi

# ------------------------------------------------------------- and it counts
# A run that builds and executes nothing exits 0 with no failures reported,
# which reads as a pass. Only a count sees it. ASSERT THE COMPARISON, NOT THE
# MESSAGE: the same check written against the words "floor is 85" survives
# replacing the whole `if` with `if false`.
case "$run" in
    *'"$total" -lt 85'*) ok "the executed-case floor compares against 85" ;;
    *) fail "no live comparison against a case floor: 90 cases ran on 2026-09-10, and a run that executes none of them exits 0 reporting no failures" ;;
esac
case "$run" in
    *"floor is 85"*) ok "and it names itself when it fires" ;;
    *) fail "the floor fires without saying what it is, so a red run will not explain what it caught" ;;
esac

# Both frameworks are in this target, and each prints only its own total.
# Counting one of them silently halves the floor's reach.
for pattern in 'Executed [0-9]+ tests' 'Test run with [0-9]+ tests'; do
    case "$run" in
        *"$pattern"*) ok "the count reads '$pattern'" ;;
        *) fail "the count does not read '$pattern': XCTest and swift-testing each report only their own total, so missing one undercounts by that framework's whole suite" ;;
    esac
done

# ------------------------------------- and the two builds see the same files
# THIS IS WHAT MAKES "the same tests" TRUE, and it is a property of the Xcode
# project rather than of anything written here. Both targets take a whole
# DIRECTORY rather than a list of files: Xcode through
# `fileSystemSynchronizedGroups`, SwiftPM through `path:`. So a test file
# added to DiskJockeyLibraryTests/ joins both builds at once and neither can
# silently miss it.
#
# If the Xcode target ever goes back to an explicit PBXSourcesBuildPhase that
# stops being true: the two builds would compile lists that drift, and
# `swift test` could report a full green while the file nobody added to the
# Xcode target is the broken one. Assert the synchronised group, not the file
# count -- the count is what would be equal right up until somebody adds a
# file.
synchronised_with_its_directory() {
    python3 -c '
import re, sys
src, name = sys.argv[1], sys.argv[2]
s = open(src).read()
m = re.search(r"/\* " + re.escape(name) + r" \*/ = \{\n\t+isa = PBXNativeTarget;(.*?)\n\t+name = " + re.escape(name) + ";", s, re.S)
if not m:
    sys.exit(2)
g = re.search(r"fileSystemSynchronizedGroups = \((.*?)\);", m.group(1), re.S)
sys.exit(0 if g and name in g.group(1) else 1)
' "$PBXPROJ" "$1"
}
for target in DiskJockeyLibrary DiskJockeyLibraryTests; do
    case "$(synchronised_with_its_directory "$target"; echo $?)" in
        0) ok "the Xcode $target target is synchronised with its directory, so both builds see the same files" ;;
        2) fail "no Xcode target named $target: this check compared nothing" ;;
        *) fail "the Xcode $target target no longer takes its whole directory; with an explicit source list the SwiftPM and Xcode builds compile different files, and \`swift test\` can go green over a file only Xcode was missing" ;;
    esac
done

# ------------------------------------------------ the dead route stays dead
# DiskJockeyLibraryOnly.xcscheme was the first attempt and it does not work.
# Leaving it in the project invites the next person to wire it up again.
if [ -e "$REPO/DiskJockey.xcodeproj/xcshareddata/xcschemes/DiskJockeyLibraryOnly.xcscheme" ]; then
    fail "DiskJockeyLibraryOnly.xcscheme is back: a library-only scheme still launches xcodebuild's own test runner, which is what failed with RunningBoard error 5"
else
    ok "no library-only xcscheme, which was the route that did not work"
fi

if [ "$fails" -eq 0 ]; then
    echo "library-tests-need-no-host: all checks passed"
else
    echo "library-tests-need-no-host: $fails check(s) failed" >&2
fi
exit $(( fails > 0 ))
