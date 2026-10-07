#!/usr/bin/env bash
#
# cli-pipe.sh — the CLI pipe test is wired, refuses what it cannot verify, and
# fails rather than skips when a tool is missing (#292).
#
# scripts/cli-pipe.sh itself needs macOS, the released tools and the image
# tools, so it runs in the CLI pipe workflow, not here. What this job CAN
# prove, with nothing installed:
#
#   1. chore test:cli-pipe runs the script, through quiet-run.sh with the
#      budget chores.yml's table records, and the workflow runs it on a
#      schedule and on dispatch, keeps tmp/logs/ whatever the result, and is
#      declared advisory — never required, since it tests other repositories'
#      releases;
#   2. a run with the tools missing FAILS, before any leg, naming every one of
#      ours with its install line: nothing skips;
#   3. the installer, run for real against a stub `gh` and `uname`, verifies
#      each tarball's attestation against the workflow that signs it
#      (rust-fs-core's release-cli.yml, or the repository's own release.yml), and refuses — linking nothing — a tarball whose attestation
#      does not verify, whose .sha256 disagrees, or that lacks a tool, and
#      names the issue tracking every release it is still waiting for;
#   4. the pairs #296 asks for are in the script's tables — ext4 both ways,
#      XFS and EROFS into ext4, Btrfs into NTFS — with the floor counting
#      them, and a Linux leg runs it beside the macOS one, with the oracles
#      only Linux has (xfsprogs, btrfs-progs, ntfs-3g).
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

# table NAME — the rows of one of the script's quoted tables (TOOLS, PAIRS,
# LAYOUT, AWAITING), quotes and blank lines dropped.
table() {
    awk -v name="$1" -v q="'" '
        index($0, name "=" q) == 1 { on = 1; $0 = substr($0, length(name) + 3) }
        on { end = (substr($0, length($0)) == q); gsub(q, ""); if (NF) print; if (end) exit }' "$SCRIPT"
}
# TOOLS rows are "repository prefix on tools...", where `on` is all or linux.
tools_on() { table TOOLS | awk -v p="$1" '$3 == "all" || $3 == p { for (i = 4; i <= NF; i++) print $i }' | sort -u; }
repos_on() { table TOOLS | awk -v p="$1" '$3 == "all" || $3 == p { print $1 }'; }
repo_of()  { table TOOLS | awk -v t="$1" '{ for (i = 4; i <= NF; i++) if ($i == t) { print $1; exit } }'; }
# signer_of REPO — the workflow whose attestation a release of REPO carries:
# rust-fs-core's shared release-cli.yml, unless the script's OWN_ATTESTED
# table lists REPO as attesting its tarballs from its own release.yml.
signer_of() {
    if table OWN_ATTESTED | grep -qx "$1"; then echo "$1/.github/workflows/release.yml"
    else echo "antimatter-studios/rust-fs-core/.github/workflows/release-cli.yml"; fi
}

case "$(uname -s)" in Darwin) here=darwin ;; *) here=linux ;; esac

# The tools the script needs from releases on this host, read from its table.
ours="$(tools_on "$here")"
n_ours="$(printf '%s\n' "$ours" | grep -c .)"
[ "$n_ours" -ge 8 ] && ok "the script names $n_ours released tools for $here" \
    || fail "could not read the released tools from $SCRIPT's TOOLS table (got $n_ours)"

# ------------------------------------------------- 0. the repositories' names
# Every repository is antimatter-studios', and a release names its tarballs
# after the repository: the am-* prefixes and christhomas/ paths of before the
# rename find no asset at all (the CLI pipe run of 2026-10-06).
renamed=0
while read -r repo prefix _; do
    [ -n "$repo" ] || continue
    if [ "${repo%%/*}" = antimatter-studios ] && [ "$prefix" = "${repo#*/}" ]; then renamed=$((renamed + 1))
    else fail "TOOLS row $repo $prefix: the repository must be antimatter-studios', and its tarballs are named after it"; fi
done < <(table TOOLS)
[ "$renamed" -gt 0 ] && [ "$renamed" = "$(table TOOLS | grep -c .)" ] \
    && ok "all $renamed TOOLS rows are antimatter-studios repositories whose tarballs carry the repository's name"

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
    jobs = (d["jobs"] || {}).values.select { |j| (j["steps"] || []).any? { |s| s["run"].to_s.include?("scripts/cli-pipe.sh") } }
    { "macos" => "CLI pipe", "ubuntu" => "CLI pipe (Linux)" }.each do |os, name|
      job = jobs.find { |j| j["runs-on"].to_s.start_with?(os) }
      if job.nil?
        bad << "no #{os} job runs scripts/cli-pipe.sh"
        next
      end
      bad << "the #{os} job is named #{job["name"].inspect}, not #{name}" unless job["name"] == name
      bad << "no timeout-minutes on the #{os} job" unless job["timeout-minutes"]
      bad << "the #{os} job does not upload tmp/logs/ with if: always()" unless (job["steps"] || []).any? { |s|
        s["uses"].to_s.include?("actions/upload-artifact") &&
          s["if"].to_s.gsub(/\s/, "") =~ /\A(\$\{\{)?always\(\)(\}\})?\z/ &&
          s.fetch("with", {})["path"].to_s.lines.map(&:strip).include?("tmp/logs/") }
      if os == "ubuntu"
        runs = (job["steps"] || []).map { |s| s["run"].to_s }.join("\n")
        %w[xfsprogs btrfs-progs ntfs-3g e2fsprogs].each { |pkg|
          bad << "the Linux job does not install #{pkg}" unless runs =~ /apt-get install[^\n]*\b#{Regexp.escape(pkg)}\b/ }
      end
    end
    names = jobs.map { |j| j["name"] }
    bad << "two jobs share a name: #{names.inspect}" unless names.uniq.size == names.size
    puts bad.join("; ")
    exit(bad.empty? ? 0 : 1)
' "$WORKFLOW" 2>&1)"; then
    ok "the workflow runs it on macOS and on Linux, on a schedule and on dispatch, bounded, keeping tmp/logs/"
else
    fail "cli-pipe.yml: ${out:-could not be read}"
fi

# The run is budgeted like a tier, and chores.yml's table records the numbers.
budget="$(grep -oE 'quiet-run\.sh.* cli-pipe [0-9]+ [0-9]+ --' "$SCRIPT" | head -1 | awk '{for (i = 1; i <= NF; i++) if ($i == "cli-pipe") { print $(i + 1), $(i + 2); exit }}')"
row="$(grep -E '^#[[:space:]]+cli-pipe[[:space:]]+[0-9]+[[:space:]]+[0-9]+' "$REPO/chores.yml" | head -1 | awk '{print $3, $4}')"
if [ -n "$budget" ] && [ "$row" = "$budget" ]; then ok "it runs through quiet-run.sh with budget $budget, as chores.yml's table records"
else fail "chores.yml's cli-pipe row says '${row:-nothing}' where the script enforces '${budget:-nothing}'"; fi

required="$(git config -f "$REPO/.github-guard" --get-all checks.required 2>/dev/null)"
advisory="$(git config -f "$REPO/.github-guard" --get-all checks.advisory 2>/dev/null)"
for name in 'CLI pipe' 'CLI pipe (Linux)'; do
    if printf '%s\n' "$required" | grep -qxF "$name"; then
        fail "$name is a required check, but it tests other repositories' releases"
    elif printf '%s\n' "$advisory" | grep -qxF "$name"; then
        ok ".github-guard declares $name advisory, not required"
    else
        fail ".github-guard does not declare $name at all"
    fi
done

# --------------------------------------------- 2. missing tools fail, named
# PATH has nothing of ours on it: only the system's own directories.
out="$(cd "$REPO" && PATH=/usr/bin:/bin CLI_PIPE_DIR="$sandbox/state-missing" QUIET_LOG_DIR="$sandbox/logs-missing" \
    bash "$SCRIPT" --no-install 2>&1)"; rc=$?
log="$sandbox/logs-missing/cli-pipe.log"
if [ "$rc" != 0 ]; then ok "a run with the tools missing fails (exit $rc)"
else fail "a run with none of the released tools on PATH passed: $out"; fi
named=0
for tool in $ours; do
    repo="$(repo_of "$tool")"
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
# uname: the platform is $STUB_OS/$STUB_ARCH, Darwin/arm64 unless set.
cat > "$stub/uname" <<'EOF'
#!/bin/sh
case "$1" in -m) echo "${STUB_ARCH:-arm64}" ;; *) echo "${STUB_OS:-Darwin}" ;; esac
EOF
# gh: `release view` answers v1.2.3; `release download` builds the asked-for
# tarball with every tool but $STUB_DROP, has no asset at all for the
# repository $STUB_NOASSET, and a .sha256 only when STUB_SHA is set (to "bad"
# or "good"); `attestation verify` exits $STUB_ATTEST.
cat > "$stub/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >> "$STUB_LOG"
case "$1 $2" in
    "release view") echo v1.2.3; exit 0 ;;
    "release download")
        shift 3; pattern="" dir="." repo=""
        while [ $# -gt 0 ]; do
            case "$1" in --pattern) pattern="$2"; shift ;; --dir) dir="$2"; shift ;; --repo) repo="$2"; shift ;; esac
            shift
        done
        [ "$repo" != "${STUB_NOASSET:-}" ] || exit 1
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

# install CASE [VAR=value...] — run the script (installing) against the stubs.
install() {
    local case="$1"; shift
    STATE="$sandbox/state-$case"
    : > "$sandbox/gh-$case.log"
    OUT="$(cd "$REPO" && env PATH="$stub:/usr/bin:/bin" STUB_LOG="$sandbox/gh-$case.log" STUB_TOOLS="$(tools_on linux)" \
        CLI_PIPE_DIR="$STATE" QUIET_LOG_DIR="$sandbox/logs-$case" "$@" bash "$SCRIPT" 2>&1)"; RC=$?
    LOG="$sandbox/logs-$case/cli-pipe.log"
    LINKED="$(find "$STATE/tools/bin" -mindepth 1 2>/dev/null | wc -l | tr -d ' ')"
}

# One clean install per platform: each installs that platform's tarballs of
# exactly the repositories its legs use.
for plat in darwin:Darwin:arm64 linux:Linux:x86_64; do
    p="${plat%%:*}" os="${plat#*:}"; os="${os%%:*}" arch="${plat##*:}"
    case "$p" in darwin) label=darwin-arm64 ;; linux) label=linux-x86_64 ;; esac
    install "good-$p" STUB_ATTEST=0 STUB_OS="$os" STUB_ARCH="$arch"
    want_repos="$(repos_on "$p" | grep -c .)" want_tools="$(tools_on "$p" | grep -c .)"
    installed="$(grep -c '^installed .* attestation verified$' "$LOG" 2>/dev/null)"
    [ "$installed" = "$want_repos" ] && [ "$LINKED" = "$want_tools" ] \
        && ok "$p: verified releases install: $installed repositories, $LINKED tools linked" \
        || fail "$p: a clean install recorded $installed of $want_repos repositories and linked $LINKED of $want_tools tools: $(head -5 "$LOG" 2>/dev/null)"
    other="$(grep 'release download' "$sandbox/gh-good-$p.log" | grep -v -- "-$label.tar.gz" | head -1)"
    [ -z "$other" ] && ok "$p: every tarball asked for is the $label one" \
        || fail "$p: the installer asked for another platform's tarball: $other"
    signed=0
    while read -r repo; do
        signer="$(signer_of "$repo")"
        grep "attestation verify" "$sandbox/gh-good-$p.log" | grep -F -- "--repo $repo " | grep -qF -- "--signer-workflow $signer" \
            && signed=$((signed + 1)) || fail "$p: $repo's tarball was not verified against $signer, the workflow that signs it"
    done < <(repos_on "$p")
    [ "$signed" = "$want_repos" ] && ok "$p: each tarball's attestation is checked against the workflow that signs it"
done

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

# A release that is still to come is named with the issue tracking it, and
# every one of them in the same run, not only the first the loop met.
# The rows are given to the script here, because no release is outstanding
# when every one the script needs has landed.
awaiting_rows='antimatter-studios/rust-fs-ext4     all    a release with fs.ext4, antimatter-studios/rust-fs-ext4#9001
antimatter-studios/rust-fs-btrfs    all    a release with tarballs, antimatter-studios/rust-fs-btrfs#9002'
install awaited STUB_OS=Linux STUB_ARCH=x86_64 STUB_DROP=fs.ext4 STUB_NOASSET=antimatter-studios/rust-fs-btrfs \
    CLI_PIPE_AWAITING="$awaiting_rows"
case "$RC:$OUT" in
    0:*) fail "a run with fs.ext4 and the Btrfs tarball missing passed" ;;
    *"has no bin/fs.ext4"*"antimatter-studios/rust-fs-ext4#9001"*)
        case "$OUT" in
            *"rust-fs-btrfs"*"antimatter-studios/rust-fs-btrfs#9002"*)
                ok "each release still to come is refused, every one in the same run, naming the issue that tracks it" ;;
            *) fail "the missing fs.ext4 was named, but the missing Btrfs tarball was not, with antimatter-studios/rust-fs-btrfs#9002: $OUT" ;;
        esac ;;
    *) fail "the missing fs.ext4 was not named with antimatter-studios/rust-fs-ext4#9001: $OUT" ;;
esac

# ------------------------------------------ 4. the pairs #296 asks for
for want in antimatter-studios/rust-fs-ext4:fs.ext4 antimatter-studios/rust-fs-ext4:fsck.ext4 \
            antimatter-studios/rust-fs-xfs:fs.xfs antimatter-studios/rust-fs-btrfs:fs.btrfs; do
    [ "$(repo_of "${want#*:}")" = "${want%%:*}" ] \
        && ok "${want#*:} is installed from ${want%%:*}'s release" \
        || fail "the TOOLS table installs no ${want#*:} from ${want%%:*}"
done
tools_on linux | grep -qx blk.probe \
    && ok "the Linux leg installs blk.probe" \
    || fail "the Linux leg does not install blk.probe, so it could probe nothing"

# PAIRS rows are "from to on". Each pair must run on Linux at least, where
# every oracle it needs is installable.
for pair in squashfs:ntfs erofs:ntfs ext4:ntfs ntfs:ext4 xfs:ext4 erofs:ext4 btrfs:ntfs; do
    from="${pair%%:*}" to="${pair#*:}"
    on="$(table PAIRS | awk -v f="$from" -v t="$to" '$1 == f && $2 == t { print $3; exit }')"
    case "$on" in
        all|linux) ok "the $from -> $to pipeline runs ($on)" ;;
        "") fail "the PAIRS table has no $from -> $to pipeline" ;;
        *) fail "the $from -> $to pipeline runs on '$on', not on Linux" ;;
    esac
done

# Every endpoint of a pair has a partition on the disk, on every platform
# the pair runs on; and each platform's floor counts every pipeline it has:
# each partition read through the raw disk and four containers, and each pair.
for p in darwin linux; do
    kinds="$(table LAYOUT | awk -v p="$p" '$6 == "all" || $6 == p { print $5 }')"
    parts="$(printf '%s\n' "$kinds" | grep -c .)"
    pairs="$(table PAIRS | awk -v p="$p" '$3 == "all" || $3 == p' | grep -c .)"
    while read -r from to _; do
        for k in "$from" "$to"; do
            printf '%s\n' "$kinds" | grep -qx "$k" || fail "$p: the $from -> $to pipeline needs a $k partition, and the $p layout has none"
        done
    done < <(table PAIRS | awk -v p="$p" '$3 == "all" || $3 == p')
    floor="$(grep -E "^FLOOR_$(printf '%s' "$p" | tr '[:lower:]' '[:upper:]')=[0-9]+" "$SCRIPT" | head -1 | cut -d= -f2)"
    need=$((parts * 5 + pairs))
    [ -n "$floor" ] && [ "$floor" -ge "$need" ] && [ "$pairs" -gt 0 ] \
        && ok "$p: the floor of $floor counts $parts partitions through 5 readers and $pairs pairs" \
        || fail "$p: the floor is '${floor:-missing}', below the $need pipelines of $parts partitions and $pairs pairs"
done

echo
if [ "$fails" -eq 0 ]; then
    echo 'cli-pipe: all checks passed'
else
    echo "cli-pipe: $fails check(s) failed" >&2
fi
exit "$((fails > 0))"
