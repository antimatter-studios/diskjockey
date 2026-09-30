#!/usr/bin/env bash
#
# dev-registry.sh — `scripts/dev.sh registry` lists every registered path
# for every FSKit extension the app ships, changes nothing without
# `--clear`, and with it removes only the strays (diskjockey#167).
#
# The registry edits are real on a Mac, so the guard never makes one. It
# puts a stub `pluginkit` first on PATH and points DJ_LSREGISTER at a stub
# `lsregister`. Both record every call they get, and the pluginkit stub
# answers `-mAvvv -i <bid>` in the format the real tool printed on
# 2026-09-30 (quoted in docs/ext4-mount-runbook.md).
#
# Also checked: the extension list covers all six FSKit extensions. XFS and
# Btrfs were missing from it, so pluginkit-reload and clean-stale-bundles
# never touched them.
#
#   bash scripts/tests/dev-registry.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEV="$REPO/scripts/dev.sh"
fails=0
ok()   { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }

sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT
mkdir -p "$sandbox/bin"
calls="$sandbox/calls"
: > "$calls"

# Three copies of DiskJockey.app: the one to keep, a live stray, and a
# path that no longer exists.
keep="$sandbox/keep/DiskJockey.app"
stray="$sandbox/stray/DiskJockey.app"
dead="$sandbox/gone/DiskJockey.app"
mkdir -p "$keep/Contents/Extensions/DiskJockeyEXT4.appex" \
         "$stray/Contents/Extensions/DiskJockeyEXT4.appex" \
         "$keep/Contents/Extensions/DiskJockeyXFS.appex"

cat > "$sandbox/bin/pluginkit" <<EOF
#!/usr/bin/env bash
echo "pluginkit \$*" >> "$calls"
if [ "\$1" = "-mAvvv" ] && [ "\$2" = "-i" ]; then
    case "\$3" in
        com.antimatterstudios.diskjockey.ext4)
            for app in "$keep" "$stray" "$dead"; do
                printf '+    com.antimatterstudios.diskjockey.ext4(1.4.0)\n'
                printf '\t            Path = %s/Contents/Extensions/DiskJockeyEXT4.appex\n' "\$app"
                printf '\t            UUID = 036F9228-9B3C-4E61-88E8-B6134C05F598\n'
                printf '\t   Parent Bundle = %s\n' "\$app"
            done
            printf ' (3 plug-ins)\n' ;;
        com.antimatterstudios.diskjockey.xfs)
            printf '+    com.antimatterstudios.diskjockey.xfs(1.4.0)\n'
            printf '\t            Path = %s/Contents/Extensions/DiskJockeyXFS.appex\n' "$keep"
            printf ' (1 plug-in)\n' ;;
        *)  printf '  (no matches)\n' ;;
    esac
fi
exit 0
EOF
cat > "$sandbox/bin/lsregister" <<EOF
#!/usr/bin/env bash
echo "lsregister \$*" >> "$calls"
EOF
chmod +x "$sandbox/bin/pluginkit" "$sandbox/bin/lsregister"

run() { PATH="$sandbox/bin:$PATH" DJ_LSREGISTER="$sandbox/bin/lsregister" bash "$DEV" registry "$@" 2>&1; }

# --- The list, and that it edits nothing. ----------------------------------
out="$(run --keep "$keep")"; rc=$?
[ "$rc" -eq 0 ] && ok "the listing exits 0" || fail "the listing exited $rc: $out"
printf '%s\n' "$out" | grep -qE "keep +com\.antimatterstudios\.diskjockey\.ext4 +$keep/Contents/Extensions/DiskJockeyEXT4\.appex" \
    && ok "the kept bundle's path is marked keep" || fail "the kept path is not marked keep: $out"
printf '%s\n' "$out" | grep -qE "live +com\.antimatterstudios\.diskjockey\.ext4 +$stray/" \
    && ok "a stray that exists is marked live" || fail "the live stray is not marked live: $out"
printf '%s\n' "$out" | grep -qE "dead +com\.antimatterstudios\.diskjockey\.ext4 +$dead/" \
    && ok "a stray that is gone is marked dead" || fail "the dead stray is not marked dead: $out"
printf '%s\n' "$out" | grep -qE "com\.antimatterstudios\.diskjockey\.btrfs.*not registered" \
    && ok "an unregistered module says so" || fail "an unregistered module is not reported: $out"
if grep -qE '^pluginkit -r|^pluginkit -a|^pluginkit -e|^lsregister' "$calls"; then
    fail "the listing edited the registry: $(grep -E '^pluginkit -[rae]|^lsregister' "$calls" | tr '\n' ';')"
else
    ok "the listing makes no registry edit"
fi
for fs in ext4 ntfs xfs btrfs erofs squashfs; do
    grep -qx "pluginkit -mAvvv -i com.antimatterstudios.diskjockey.$fs" "$calls" \
        && ok "the listing reads $fs" || fail "the listing never asked about $fs"
done

# --- --clear removes the strays and only the strays. ------------------------
: > "$calls"
out="$(run --clear --keep "$keep")"; rc=$?
[ "$rc" -eq 0 ] && ok "--clear exits 0" || fail "--clear exited $rc: $out"
for app in "$stray" "$dead"; do
    grep -qxF "pluginkit -r $app/Contents/Extensions/DiskJockeyEXT4.appex" "$calls" \
        && ok "--clear deregisters $(basename "$(dirname "$app")")'s extension" \
        || fail "--clear did not pluginkit -r $app's extension"
    grep -qxF "lsregister -u $app" "$calls" \
        && ok "--clear drops $(basename "$(dirname "$app")")'s app from LaunchServices" \
        || fail "--clear did not lsregister -u $app"
done
if grep -qF "$keep" <(grep -E '^pluginkit -r|^lsregister' "$calls"); then
    fail "--clear touched the kept bundle: $(grep -F "$keep" "$calls" | tr '\n' ';')"
else
    ok "--clear leaves the kept bundle registered"
fi

# --- Arguments. -------------------------------------------------------------
out="$(run --bogus)"; rc=$?
[ "$rc" -ne 0 ] && ok "an unknown option is refused" || fail "an unknown option was accepted: $out"
out="$(run --keep)"; rc=$?
[ "$rc" -ne 0 ] && ok "--keep without a path is refused" || fail "--keep without a path was accepted"

# --- The extension list covers every FSKit extension. -----------------------
for pair in EXT4:ext4 NTFS:ntfs XFS:xfs BTRFS:btrfs EROFS:erofs SQUASHFS:squashfs; do
    dir="${pair%%:*}"; id="${pair##*:}"
    grep -qF "\"Contents/Extensions/DiskJockey$dir.appex|com.antimatterstudios.diskjockey.$id\"" "$DEV" \
        && ok "FSKIT_EXTENSIONS lists $id" || fail "FSKIT_EXTENSIONS in scripts/dev.sh does not list $id"
done

if [ "$fails" -gt 0 ]; then
    echo "dev-registry: $fails check(s) failed"
    exit 1
fi
echo "dev-registry: all checks passed"
