#!/usr/bin/env bash
#
# cli-pipe.sh — the CLI pipe test is wired, refuses what it cannot verify, and
# fails rather than skips when a tool is missing (#292).
#
# scripts/cli-pipe.sh itself needs macOS, the released tools and the image
# tools, so it runs in the CLI pipe workflow, not here. What this job CAN
# prove, with nothing installed:
#
#   1. chore test:cli-pipe runs the script, and the workflow runs it on a
#      schedule and on dispatch, keeps tmp/logs/ whatever the result, and is
#      declared advisory — never required, since it tests other repositories'
#      releases;
#   2. a run with the tools missing FAILS, before any leg, naming every one of
#      ours with its install line: nothing skips;
#   3. the installer, run for real against a stub `gh` and `uname`, verifies
#      each tarball's attestation against its own repository's release
#      workflow, and refuses — linking nothing — a tarball whose attestation
#      does not verify, whose .sha256 disagrees, or that lacks a tool.
#
#   bash scripts/tests/cli-pipe.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO/scripts/cli-pipe.sh"
WORKFLOW="$REPO/.github/workflows/cli-pipe.yml"
fails=0
ok()   { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }

sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT

command -v ruby >/dev/null 2>&1 || { echo "cli-pipe: ruby is required to parse the workflow" >&2; exit 1; }

# The tools the script needs from releases, read from its own table.
ours="$(awk '/^TOOLS=/{on=1; sub(/^TOOLS=./, "")} on{for (i = 3; i <= NF; i++) { t = $i; sub(/'"'"'$/, "", t); print t } } on && /'"'"'$/{exit}' "$SCRIPT" | sort -u)"
n_ours="$(printf '%s\n' "$ours" | grep -c .)"
[ "$n_ours" -ge 8 ] && ok "the script names $n_ours released tools" \
    || fail "could not read the released tools from $SCRIPT's TOOLS table (got $n_ours)"

# --------------------------------------------------------------- 1. wiring
ruby -ryaml -e '
    d = YAML.safe_load(File.read(ARGV[0]), aliases: true)
    t = (d["tasks"] || {})["test:cli-pipe"] or exit 1
    exit(Array(t["cmds"]).any? { |c| c.to_s.include?("scripts/cli-pipe.sh") } ? 0 : 1)
' "$REPO/chores.yml" 2>/dev/null \
    && ok "chore test:cli-pipe runs scripts/cli-pipe.sh" \
    || fail "chores.yml has no test:cli-pipe task running scripts/cli-pipe.sh"

if out="$(ruby -ryaml -e '
    d = YAML.safe_load(File.read(ARGV[0]), aliases: true)
    on = d.key?("on") ? d["on"] : d[true]
    on = { on => nil } if on.is_a?(String)
    on = on.to_h { |e| [e, nil] } if on.is_a?(Array)
    bad = []
    bad << "no schedule" unless on.key?("schedule")
    bad << "no workflow_dispatch" unless on.key?("workflow_dispatch")
    job = (d["jobs"] || {}).values.find { |j| (j["steps"] || []).any? { |s| s["run"].to_s.include?("scripts/cli-pipe.sh") } }
    if job.nil?
      bad << "no job runs scripts/cli-pipe.sh"
    else
      bad << "the job is not named CLI pipe" unless job["name"] == "CLI pipe"
      bad << "no timeout-minutes on the job" unless job["timeout-minutes"]
      bad << "tmp/logs/ is not uploaded with if: always()" unless (job["steps"] || []).any? { |s|
        s["uses"].to_s.include?("actions/upload-artifact") &&
          s["if"].to_s.gsub(/\s/, "") =~ /\A(\$\{\{)?always\(\)(\}\})?\z/ &&
          s.fetch("with", {})["path"].to_s.lines.map(&:strip).include?("tmp/logs/") }
    end
    puts bad.join("; ")
    exit(bad.empty? ? 0 : 1)
' "$WORKFLOW" 2>&1)"; then
    ok "the workflow runs it on a schedule and on dispatch, bounded, and keeps tmp/logs/"
else
    fail "cli-pipe.yml: ${out:-could not be read}"
fi

required="$(git config -f "$REPO/.github-guard" --get-all checks.required 2>/dev/null)"
advisory="$(git config -f "$REPO/.github-guard" --get-all checks.advisory 2>/dev/null)"
if printf '%s\n' "$required" | grep -qx 'CLI pipe'; then
    fail "CLI pipe is a required check, but it tests other repositories' releases"
elif printf '%s\n' "$advisory" | grep -qx 'CLI pipe'; then
    ok ".github-guard declares CLI pipe advisory, not required"
else
    fail ".github-guard does not declare CLI pipe at all"
fi

# --------------------------------------------- 2. missing tools fail, named
# PATH has nothing of ours on it: only the system's own directories.
out="$(cd "$REPO" && PATH=/usr/bin:/bin CLI_PIPE_DIR="$sandbox/state-missing" QUIET_LOG_DIR="$sandbox/logs-missing" \
    bash "$SCRIPT" --no-install 2>&1)"; rc=$?
log="$sandbox/logs-missing/cli-pipe.log"
if [ "$rc" != 0 ]; then ok "a run with the tools missing fails (exit $rc)"
else fail "a run with none of the released tools on PATH passed: $out"; fi
named=0
for tool in $ours; do
    repo="$(awk -v t="$tool" '/^TOOLS=/{on=1} on{for (i = 3; i <= NF; i++) { x = $i; sub(/'"'"'$/, "", x); if (x == t) { r = $1; sub(/^TOOLS=./, "", r); print r; exit } } }' "$SCRIPT")"
    grep -qF "MISSING $tool — from $repo's release" "$log" 2>/dev/null \
        && grep -F "MISSING $tool " "$log" | grep -qF "brew install antimatter-studios/tap/${repo#*/}" \
        && named=$((named + 1)) \
        || fail "the missing $tool is not named with $repo and its brew install line"
done
[ "$named" = "$n_ours" ] && ok "each of the $named missing tools is named with its release and brew install line"
if grep -qE '^ok ' "$log" 2>/dev/null; then fail "a leg reported ok with its tools missing"
else ok "no leg runs, or reports ok, before every tool is present"; fi
printf '%s\n' "$out" | grep -q 'MISSING blk.probe' \
    && ok "and the verdict on the terminal names them, not just the log" \
    || fail "the terminal verdict does not name the missing tools: $out"

# ------------------------------------------------- 3. the installer refuses
stub="$sandbox/stub"
mkdir -p "$stub"
cat > "$stub/uname" <<'EOF'
#!/bin/sh
case "$1" in -s) echo Darwin ;; -m) echo arm64 ;; *) echo Darwin ;; esac
EOF
# gh: `release view` answers v1.2.3; `release download` builds the asked-for
# tarball with every tool but $STUB_DROP, and a .sha256 only when STUB_SHA is
# set (to "bad" or "good"); `attestation verify` exits $STUB_ATTEST.
cat > "$stub/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >> "$STUB_LOG"
case "$1 $2" in
    "release view") echo v1.2.3; exit 0 ;;
    "release download")
        shift 3; pattern="" dir="."
        while [ $# -gt 0 ]; do
            case "$1" in --pattern) pattern="$2"; shift ;; --dir) dir="$2"; shift ;; esac
            shift
        done
        case "$pattern" in
            *.sha256)
                [ -n "${STUB_SHA:-}" ] || exit 1
                asset="${pattern%.sha256}"
                if [ "$STUB_SHA" = good ]; then
                    (sha256sum "$dir/$asset" 2>/dev/null || shasum -a 256 "$dir/$asset") | awk '{print $1}' > "$dir/$pattern"
                else
                    echo 0000000000000000000000000000000000000000000000000000000000000000 > "$dir/$pattern"
                fi ;;
            *)
                t="$(mktemp -d)"; mkdir -p "$t/bin"
                for tool in $STUB_TOOLS; do
                    [ "$tool" = "${STUB_DROP:-}" ] && continue
                    printf '#!/bin/sh\nexit 1\n' > "$t/bin/$tool"; chmod +x "$t/bin/$tool"
                done
                tar -C "$t" -czf "$dir/$pattern" bin; rm -rf "$t" ;;
        esac ;;
    "attestation verify") exit "${STUB_ATTEST:-0}" ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$stub/uname" "$stub/gh"

# install CASE — run the script (installing) against the stubs.
install() {
    local case="$1"; shift
    STATE="$sandbox/state-$case"
    : > "$sandbox/gh-$case.log"
    OUT="$(cd "$REPO" && env PATH="$stub:/usr/bin:/bin" STUB_LOG="$sandbox/gh-$case.log" STUB_TOOLS="$ours" \
        CLI_PIPE_DIR="$STATE" QUIET_LOG_DIR="$sandbox/logs-$case" "$@" bash "$SCRIPT" 2>&1)"; RC=$?
    LOG="$sandbox/logs-$case/cli-pipe.log"
    LINKED="$(find "$STATE/tools/bin" -mindepth 1 2>/dev/null | wc -l | tr -d ' ')"
}

install good STUB_ATTEST=0
installed="$(grep -c '^installed .* attestation verified$' "$LOG" 2>/dev/null)"
n_repos="$(awk '/^TOOLS=/{on=1} on && NF{n++} on && /'"'"'$/{print n; exit}' "$SCRIPT")"
[ "$installed" = "$n_repos" ] && [ "$LINKED" = "$n_ours" ] \
    && ok "verified releases install: $installed repositories, $LINKED tools linked" \
    || fail "a clean install recorded $installed of $n_repos repositories and linked $LINKED of $n_ours tools: $(head -5 "$LOG" 2>/dev/null)"
signed=0
while read -r repo; do
    grep -qF -- "attestation verify" "$sandbox/gh-good.log" \
        && grep "attestation verify" "$sandbox/gh-good.log" | grep -F -- "--repo $repo " | grep -qF -- "--signer-workflow $repo/.github/workflows/release.yml" \
        && signed=$((signed + 1)) || fail "$repo's tarball was not verified against $repo's own release workflow"
done < <(awk '/^TOOLS=/{on=1} on && NF{r = $1; sub(/^TOOLS=./, "", r); print r} on && /'"'"'$/{exit}' "$SCRIPT")
[ "$signed" = "$n_repos" ] && ok "each tarball's attestation is checked against its own repository's release workflow"

install unattested STUB_ATTEST=1
case "$RC:$OUT" in
    0:*) fail "a tarball whose attestation does not verify was accepted" ;;
    *"refusing it"*) [ "$LINKED" = 0 ] && ok "a tarball whose attestation does not verify is refused, and nothing is linked" \
                      || fail "an unattested tarball was refused, but $LINKED tool(s) were linked" ;;
    *) fail "an unattested tarball was refused without saying so: $OUT" ;;
esac

install badsum STUB_SHA=bad
case "$RC:$OUT" in
    0:*) fail "a tarball whose .sha256 disagrees was accepted" ;;
    *"but its .sha256 says"*) [ "$LINKED" = 0 ] && ok "a tarball whose published .sha256 disagrees is refused, and nothing is linked" \
                               || fail "a bad checksum was refused, but $LINKED tool(s) were linked" ;;
    *) fail "a bad checksum was refused without saying so: $OUT" ;;
esac

install short STUB_DROP=fs.ntfs
case "$RC:$OUT" in
    0:*) fail "a tarball without bin/fs.ntfs was accepted" ;;
    *"has no bin/fs.ntfs"*) ok "a tarball without one of its tools is refused, naming it" ;;
    *) fail "a tarball without bin/fs.ntfs was refused without naming it: $OUT" ;;
esac

echo
if [ "$fails" -eq 0 ]; then
    echo 'cli-pipe: all checks passed'
else
    echo "cli-pipe: $fails check(s) failed" >&2
fi
exit "$((fails > 0))"
