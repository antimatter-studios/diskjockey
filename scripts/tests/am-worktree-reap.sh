#!/usr/bin/env bash
#
# am-worktree-reap.sh — the reaper keeps what it cannot prove is idle.
#
# am-worktree-reap is a DELETION tool. Every defect pinned here is a case
# where it answered "nothing there" without having measured it:
#
#   #126  a claim made as `<wt>/`, or through a symlink, is filed under a
#         different key from the one the reaper looks up, so a live owner
#         reads as unowned;
#   #127  the owner record is read twice while the writer truncates it, so
#         a refresh mid-read becomes epoch 0 — "silent for 29 million
#         minutes" — and an empty timestamp is treated the same way;
#   #131  the in-use probe matches only a cwd EQUAL to the worktree root,
#         and a host with no lsof gets the answer an idle tree gets;
#   #144  `awk $2` truncates a path at its first space, so a present
#         worktree is reported PRUNE, and a prune that removed nothing is
#         still counted;
#   #86   the "ahead of a tracking ref" keep-reason lost the branch name.
#
# EVERYTHING RUNS IN A SCRATCH ROOT. The repositories live under a
# temporary AM_REAP_ROOT, named after a constellation repository (the
# reaper refuses anything else), HOME and AM_WORKTREE_STATE are scratch,
# and `lsof` is a stub on PATH unless a case says otherwise. `run_reap`
# refuses to start if the root is not inside the sandbox.
#
#   bash scripts/tests/am-worktree-reap.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REAPER="$REPO/scripts/am-worktree-reap"
OWN="$REPO/scripts/am-worktree-own"
fails=0

sandbox="$(mktemp -d)"
sandbox="$(cd "$sandbox" && pwd -P)"
cleanup() {
    [ -n "${live_pid:-}" ] && kill "$live_pid" 2>/dev/null
    rm -rf "$sandbox"
}
trap cleanup EXIT

ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fails=$((fails + 1)); }
# has <haystack> <fixed-string> <name>
has()    { if printf '%s\n' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3: expected output to contain [$2], got:"; printf '%s\n' "$1" | sed 's/^/         | /'; fi; }
has_line() { if printf '%s\n' "$1" | grep -qxF -- "$2"; then ok "$3"; else bad "$3: expected a line exactly [$2], got:"; printf '%s\n' "$1" | sed 's/^/         | /'; fi; }
hasnt()  { if printf '%s\n' "$1" | grep -qF -- "$2"; then bad "$3: output must not contain [$2], got:"; printf '%s\n' "$1" | sed 's/^/         | /'; else ok "$3"; fi; }

# A private, predictable git: no user config, no system config.
export HOME="$sandbox/home"
mkdir -p "$HOME"
export GIT_CONFIG_NOSYSTEM=1
cat > "$HOME/.gitconfig" <<'EOF'
[user]
    name = reaper test
    email = reaper-test@example.invalid
[init]
    defaultBranch = main
[advice]
    detachedHead = false
EOF

# THE lsof STUB. Emulates the two lsof forms the reaper could use:
#   lsof -a -d cwd -- <dir>   lists a process only when its cwd EQUALS <dir>
#   lsof -d cwd -Fn           lists every process cwd, as p/f/n lines
# with a single pretend process whose cwd is $FAKE_CWD. The enumeration
# exits 1 on purpose: real lsof does that while still printing matches
# (measured on #131), so the exit status must not be the signal.
# FAKE_LSOF_EMPTY=1 makes it print nothing at all.
stubs="$sandbox/stubs"
mkdir -p "$stubs"
cat > "$stubs/lsof" <<'EOF'
#!/usr/bin/env bash
[ "${FAKE_LSOF_EMPTY:-0}" = 1 ] && exit 1
cwd="${FAKE_CWD:-/nonexistent/elsewhere}"
prev=""
for a in "$@"; do
    if [ "$prev" = "--" ]; then
        [ "$a" = "$cwd" ] && { printf 'COMMAND PID USER FD TYPE NAME\nsleep 4242 u cwd DIR %s\n' "$cwd"; exit 0; }
        exit 1
    fi
    prev="$a"
done
case " $* " in
    *" -Fn "*) printf 'p4242\nfcwd\nn%s\n' "$cwd"; exit 1 ;;
esac
exit 1
EOF
chmod +x "$stubs/lsof"
BASE_PATH="$stubs:$PATH"

# A PATH with every tool the scripts need and NO lsof, for #131 gap 2.
nolsof="$sandbox/nolsof-bin"
mkdir -p "$nolsof"
for c in bash env git dirname basename mktemp rm grep cut date find awk tail head \
         sed shasum sha256sum perl mkdir mv cat ls wc tr sleep touch ln readlink \
         stat cp chmod sort uniq pwd printf test expr od; do
    p="$(type -P "$c" 2>/dev/null)" || continue
    [ -n "$p" ] && ln -sf "$p" "$nolsof/$c"
done

# A fresh scratch root per case: a bare remote and a clone at
# $root/rust-img-vhd with one pushed commit.
new_case() {
    case_dir="$sandbox/case-$1"
    root="$case_dir/root"
    state="$case_dir/state"
    main="$root/rust-img-vhd"
    mkdir -p "$root" "$state"
    git init -q --bare "$case_dir/remote.git"
    git clone -q "$case_dir/remote.git" "$main" 2>/dev/null
    git -C "$main" commit -q --allow-empty -m init
    git -C "$main" push -q origin HEAD:main 2>/dev/null
    git -C "$main" fetch -q origin
}

# add_wt <dir> <branch> — a clean worktree whose branch is pushed and tracked.
add_wt() {
    mkdir -p "$(dirname "$1")"
    git -C "$main" worktree add -q -b "$2" "$1" origin/main 2>/dev/null
    git -C "$1" push -q -u origin "$2" 2>/dev/null
    mkdir -p "$1/src"
}

# Make a tree look untouched for days, so only ownership and the in-use
# probe stand between it and removal.
age() { find "$1" -maxdepth 2 -exec touch -h -t 202001010000 {} + 2>/dev/null; }

# run_reap [args...] — always the scratch root and scratch state.
run_reap() {
    case "$root" in "$sandbox"/*) ;; *) echo "refusing: root $root is outside the sandbox" >&2; exit 99 ;; esac
    AM_REAP_ROOT="$root" AM_WORKTREE_STATE="$state" PATH="${RUN_PATH:-$BASE_PATH}" \
        bash "$REAPER" --repo rust-img-vhd "$@" 2>&1
}
own() { AM_WORKTREE_STATE="$state" PATH="$BASE_PATH" bash "$OWN" "$@" 2>&1; }
# The key the pre-fix tools used: a hash of the string exactly as given.
literal_key() { printf '%s' "$1" | shasum -a 256 | cut -c1-32; }

echo "am-worktree-reap: #126 one path, one key"

new_case 126a
wt="$root/wts/rust-img-vhd-126a"
add_wt "$wt" fix-126a
age "$wt"
own "$wt/" agent-1 >/dev/null
who="$(own --who "$wt")"
has "$who" "agent-1" "#126 a claim made as '<wt>/' is found by --who '<wt>'"
out="$(run_reap)"
has "$out" "KEEP    $wt" "#126 a claim made as '<wt>/' keeps the worktree"
has "$out" "owned by agent-1" "#126 ...and the reaper names its owner"
hasnt "$out" "REAP    $wt" "#126 ...and does not list it for removal"

new_case 126b
wt="$root/wts/rust-img-vhd-126b"
add_wt "$wt" fix-126b
own "$wt" agent-2 >/dev/null
who="$(own --who "$wt/")"
has "$who" "agent-2" "#126 --who '<wt>/' finds a claim made as '<wt>'"

new_case 126c
wt="$root/wts/rust-img-vhd-126c"
add_wt "$wt" fix-126c
age "$wt"
ln -s "$root/wts" "$case_dir/link"
own "$case_dir/link/rust-img-vhd-126c" agent-3 >/dev/null
out="$(run_reap)"
has "$out" "owned by agent-3" "#126 a claim made through a symlinked spelling keeps the worktree"

new_case 126d
wt="$root/wts/rust-img-vhd-126d"
add_wt "$wt" fix-126d
age "$wt"
# A record written by the old tool under the literal key of '<wt>/'. The
# fix must not strand claims that already exist.
printf '%s\t%s\t%s\n' legacy-agent "$(date +%s)" "$wt/" > "$state/$(literal_key "$wt/")"
out="$(run_reap)"
has "$out" "owned by legacy-agent" "#126 an existing record under an old non-canonical key is still honoured"

gone="$(own --who "$case_dir/no-such-dir")"; rc=$?
if [ "$rc" != 0 ]; then ok "#126 --who refuses a path it cannot resolve (rc=$rc)"; else bad "#126 --who on an unresolvable path exited 0 with [$gone]"; fi

echo "am-worktree-reap: #127 the owner record"

new_case 127a
wt="$root/wts/rust-img-vhd-127a"
add_wt "$wt" fix-127a
age "$wt"
# The state a reader sees mid-refresh, or a damaged record: a name and
# no timestamp. It must not resolve to epoch 0.
printf 'agent-4\t\t%s\n' "$wt" > "$state/$(literal_key "$wt")"
out="$(run_reap)"
hasnt "$out" "REAP    $wt" "#127 a record with an empty timestamp is not reaped as 'silent for ~29M minutes'"
has "$out" "KEEP    $wt" "#127 ...it is kept"
who="$(own --who "$wt")"; rc=$?
hasnt "$who" "heartbeat 29" "#127 --who does not report an empty timestamp as an epoch-0 heartbeat"
if [ "$rc" != 0 ]; then ok "#127 --who exits non-zero on an unreadable record (rc=$rc)"; else bad "#127 --who exited 0 on an unreadable record: [$who]"; fi

new_case 127b
wt="$root/wts/rust-img-vhd-127b"
add_wt "$wt" fix-127b
own "$wt" agent-5 >/dev/null
f="$state/$(literal_key "$wt")"
ino1="$(ls -i "$f" 2>/dev/null | awk '{print $1}')"
own "$wt" agent-5 >/dev/null
ino2="$(ls -i "$f" 2>/dev/null | awk '{print $1}')"
if [ -n "$ino1" ] && [ -n "$ino2" ] && [ "$ino1" != "$ino2" ]; then
    ok "#127 a heartbeat refresh publishes a new file (rename), not a truncate-in-place ($ino1 -> $ino2)"
else
    bad "#127 a heartbeat refresh rewrote the record in place: inode [$ino1] -> [$ino2], so a reader can see it empty"
fi
leftovers="$(find "$state" -type f ! -name "$(basename "$f")" | wc -l | tr -d ' ')"
if [ "$leftovers" = 0 ]; then ok "#127 the atomic publish leaves no temp files behind"; else bad "#127 the atomic publish left $leftovers stray file(s) in the state dir"; fi

new_case 127c
wt="$root/wts/rust-img-vhd-127c"
add_wt "$wt" fix-127c
age "$wt"
own "$wt" agent-6 >/dev/null
# THE INTERLEAVING, MADE DETERMINISTIC. A `cut` wrapper that behaves as
# the concurrent writer would: the first time anything splits out field 1
# it truncates the record, exactly between a reader's first and second
# open. A reader that opens the record once is unaffected.
race="$case_dir/race-bin"
mkdir -p "$race"
real_cut="$(type -P cut)"
cat > "$race/cut" <<EOF
#!/usr/bin/env bash
"$real_cut" "\$@"; rc=\$?
if [ "\$*" = "-f1" ] && [ ! -e "$case_dir/raced" ]; then
    for r in "$state"/*; do : > "\$r"; done
    : > "$case_dir/raced"
fi
exit \$rc
EOF
chmod +x "$race/cut"
out="$(RUN_PATH="$race:$BASE_PATH" run_reap)"
hasnt "$out" "REAP    $wt" "#127 a record truncated between two reads does not make a live owner reapable"
has "$out" "KEEP    $wt" "#127 ...it is kept"

echo "am-worktree-reap: #131 the in-use probe"

new_case 131a
wt="$root/wts/rust-img-vhd-131a"
add_wt "$wt" fix-131a
age "$wt"
out="$(FAKE_CWD="$wt/src" run_reap)"
has "$out" "KEEP    $wt" "#131 a process whose cwd is a SUBDIRECTORY keeps the worktree"
has "$out" "a process is working in it" "#131 ...and says why"

new_case 131b
wt="$root/wts/rust-img-vhd-131b"
add_wt "$wt" fix-131b
age "$wt"
out="$(RUN_PATH="$nolsof" run_reap)"
if AM_X=1 PATH="$nolsof" bash -c 'command -v lsof' >/dev/null 2>&1; then
    bad "#131 the no-lsof PATH still resolves lsof; case not measurable"
fi
has "$out" "KEEP    $wt" "#131 with no lsof on PATH the worktree is kept, not treated as idle"
has "$out" "lsof" "#131 ...and the report says the in-use proof was unavailable"

new_case 131c
wt="$root/wts/rust-img-vhd-131c"
add_wt "$wt" fix-131c
age "$wt"
out="$(FAKE_LSOF_EMPTY=1 run_reap)"
has "$out" "KEEP    $wt" "#131 an lsof that lists no process at all is not proof of idleness"

new_case 131d
wt="$root/wts/rust-img-vhd-131d"
add_wt "$wt" fix-131d
age "$wt"
out="$(FAKE_CWD="$wt" run_reap)"
has "$out" "a process is working in it" "#131 control: a process whose cwd IS the root keeps it"

new_case 131e
wt="$root/wts/rust-img-vhd-131e"
add_wt "$wt" fix-131e
age "$wt"
mkdir -p "${wt}-sibling"
out="$(FAKE_CWD="${wt}-sibling" run_reap)"
has "$out" "REAP    $wt" "#131 control: a cwd in a sibling that merely shares the prefix does not hold it (the probe is not keep-everything)"

if real_lsof="$(type -P lsof)" && [ -n "$real_lsof" ]; then
    new_case 131f
    wt="$root/wts/rust-img-vhd-131f"
    add_wt "$wt" fix-131f
    mkdir -p "$wt/src/deep"
    age "$wt"
    (cd "$wt/src/deep" && exec sleep 120) &
    live_pid=$!
    sleep 1
    out="$(RUN_PATH="$PATH" run_reap)"
    kill "$live_pid" 2>/dev/null; wait "$live_pid" 2>/dev/null; live_pid=""
    has "$out" "a process is working in it" "#131 real lsof: a live process two levels down keeps the worktree"
else
    echo "  note real lsof absent on this host; the live-process case was not run"
fi

echo "am-worktree-reap: #144 paths and prune"

new_case 144a
wt="$root/wts/has a space"
add_wt "$wt" fix-144a
age "$wt"
out="$(run_reap)"
hasnt "$out" "PRUNE" "#144 a present worktree whose path has a space is not reported PRUNE"
has "$out" "REAP    $wt" "#144 ...it is examined under its full path"

new_case 144b
wt="$root/wts/rust-img-vhd-144b"
add_wt "$wt" fix-144b
git -C "$main" worktree lock "$wt"
rm -rf "$wt"
out="$(run_reap --remove)"
has_line "$out" "  removed/pruned: 0   kept: 1" "#144 a prune that removed nothing (locked entry) is not counted, and the entry is reported kept"
if git -C "$main" worktree list --porcelain | grep -qxF "worktree $wt"; then
    ok "#144 ...and the locked entry is indeed still there"
else
    bad "#144 the locked entry was removed; the case did not measure a declined prune"
fi

new_case 144d
wt="$root/wts/rust-img-vhd-144d"
add_wt "$wt" fix-144d
git -C "$main" worktree lock "$wt"
rm -rf "$wt"
out="$(run_reap)"
hasnt "$out" "PRUNE   $wt" "#144 the dry run does not promise to prune a locked entry"
has "$out" "KEEP    $wt" "#144 ...it reports it kept"

new_case 144e
wt="$root/wts/rust-img-vhd-144e"
add_wt "$wt" fix-144e
rm -rf "$wt"
# A prune that declines for any reason: a git whose `worktree prune`
# does nothing. Only a count taken after the prune can notice.
noprune="$case_dir/noprune-bin"
mkdir -p "$noprune"
printf '#!/usr/bin/env bash\nfor a in "$@"; do [ "$a" = prune ] && exit 0; done\nexec %q "$@"\n' "$(type -P git)" > "$noprune/git"
chmod +x "$noprune/git"
out="$(RUN_PATH="$noprune:$BASE_PATH" run_reap --remove)"
has_line "$out" "  removed/pruned: 0   kept: 1" "#144 an unlocked entry that prune did not remove is not counted as pruned"
hasnt "$out" "PRUNE   $wt" "#144 ...and is not reported PRUNE"

new_case 144c
wt="$root/wts/rust-img-vhd-144c"
add_wt "$wt" fix-144c
rm -rf "$wt"
out="$(run_reap --remove)"
has "$out" "PRUNE   $wt" "#144 control: a genuinely missing directory is reported PRUNE"
has_line "$out" "  removed/pruned: 1   kept: 0" "#144 control: ...and counted once it was pruned"
if git -C "$main" worktree list --porcelain | grep -qxF "worktree $wt"; then
    bad "#144 control: the missing worktree's entry is still listed after --remove"
else
    ok "#144 control: ...and its entry is gone"
fi

echo "am-worktree-reap: #86 keep-reasons name the branch"

new_case 86
wt="$root/wts/rust-img-vhd-86"
add_wt "$wt" fix-86
git -C "$wt" commit -q --allow-empty -m "not pushed"
out="$(run_reap)"
has "$out" "ahead of a tracking ref" "#86 an unpushed commit keeps the worktree"
has "$out" "on 'fix-86'" "#86 ...and the reason names the branch"

echo
if [ "$fails" -ne 0 ]; then
    echo "am-worktree-reap: $fails check(s) FAILED"
    exit 1
fi
echo "am-worktree-reap: all checks passed"
