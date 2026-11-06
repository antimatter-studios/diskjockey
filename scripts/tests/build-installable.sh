#!/usr/bin/env bash
# scripts/build-installable.sh installs into the Applications folder it is
# asked for, and asks for a password only when it has to.
#
# `--install user` copies the app into ~/Applications, creating the folder,
# and never runs sudo. `--install system` copies it into /Applications, and
# goes through sudo only when this account cannot write there: an
# administrator account can, so a sudo prompt there would be a password asked
# for nothing. Both ask before replacing an existing copy. Anything else after
# --install is refused rather than read as the old bare `--install`.
#
# The script runs from a copy in a sandbox, with xcodebuild, chore, codesign,
# security, xattr, ditto and sudo stubbed on PATH, so nothing is built, signed
# or installed for real. The stubbed sudo logs each command and runs it with
# the read-only folder opened for that one command.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fails=0
ok() { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }

sb="$(mktemp -d)"
trap 'chmod -R u+w "$sb" 2>/dev/null; rm -rf "$sb"' EXIT

mkdir -p "$sb/repo/scripts" "$sb/repo/DiskJockey.xcodeproj" "$sb/bin" "$sb/home"
cp "$ROOT/scripts/build-installable.sh" "$sb/repo/scripts/"
: > "$sb/repo/DiskJockey.xcodeproj/project.pbxproj"
: > "$sb/repo/scripts/ExportOptions-development.plist"

stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$sb/bin/$1"; chmod +x "$sb/bin/$1"; }
stub chore 'exit 0'
stub codesign 'exit 0'
stub security 'echo "  1) ABC \"Apple Development: Test\""'
stub xattr 'exit 0'
stub ditto 'cp -R "$1" "$2"'
# -exportArchive leaves an app, stamped so a test can tell a new copy from an old one.
stub xcodebuild 'while [ $# -gt 0 ]; do [ "$1" = -exportPath ] && out="$2"; shift; done
[ -n "${out:-}" ] && mkdir -p "$out/DiskJockey.app" && echo new > "$out/DiskJockey.app/stamp"
exit 0'
stub sudo 'echo "$*" >> "$SUDO_LOG"
chmod u+w "$DJ_SYSTEM_APPLICATIONS"; "$@"; rc=$?; chmod a-w "$DJ_SYSTEM_APPLICATIONS"; exit $rc'

# run <answer> <args...>: the script's status, with its output in $sb/out.
run() {
    local answer="$1"; shift
    printf '%s\n' "$answer" | env PATH="$sb/bin:$PATH" HOME="$sb/home" \
        DJ_SYSTEM_APPLICATIONS="$sb/system" SUDO_LOG="$sb/sudo.log" \
        bash "$sb/repo/scripts/build-installable.sh" "$@" > "$sb/out" 2>&1
}
stamp() { cat "$1/DiskJockey.app/stamp" 2>/dev/null || echo none; }

# user: ~/Applications does not exist yet, and no sudo.
: > "$sb/sudo.log"
if run y --install user && [ "$(stamp "$sb/home/Applications")" = new ]; then
    ok "--install user creates ~/Applications and installs into it"
else
    fail "--install user did not install into ~/Applications: $(tail -3 "$sb/out")"
fi
[ ! -s "$sb/sudo.log" ] && ok "--install user runs no sudo" \
    || fail "--install user ran sudo: $(head -1 "$sb/sudo.log")"

# user, replacing: n keeps the old copy, y replaces it.
mkdir -p "$sb/home/Applications/DiskJockey.app"
echo old > "$sb/home/Applications/DiskJockey.app/stamp"
run n --install user
[ "$(stamp "$sb/home/Applications")" = old ] && ok "answering n keeps the existing copy" \
    || fail "answering n replaced the existing copy"
run y --install user
[ "$(stamp "$sb/home/Applications")" = new ] && ok "answering y replaces the existing copy" \
    || fail "answering y did not replace the existing copy: $(tail -3 "$sb/out")"

# system, writable (an administrator account): no sudo.
mkdir -p "$sb/system"
: > "$sb/sudo.log"
if run y --install system && [ "$(stamp "$sb/system")" = new ]; then
    ok "--install system installs into a writable system folder"
else
    fail "--install system did not install into a writable folder: $(tail -3 "$sb/out")"
fi
[ ! -s "$sb/sudo.log" ] && ok "a writable system folder needs no sudo" \
    || fail "a writable system folder ran sudo: $(head -1 "$sb/sudo.log")"

# system, read-only (any other account): the copy and the swap go through sudo.
rm -rf "$sb/system/DiskJockey.app"
chmod a-w "$sb/system"
: > "$sb/sudo.log"
if run y --install system && [ "$(stamp "$sb/system")" = new ]; then
    ok "--install system installs into a read-only folder through sudo"
else
    fail "--install system did not install into a read-only folder: $(tail -3 "$sb/out")"
fi
for cmd in ditto mv; do
    grep -q "^$cmd " "$sb/sudo.log" && ok "a read-only system folder runs $cmd through sudo" \
        || fail "a read-only system folder did not run $cmd through sudo"
done
chmod u+w "$sb/system"

# Anything but user or system is refused, the old bare --install included.
for args in "--install" "--install home"; do
    run y $args
    rc=$?
    [ "$rc" = 2 ] && ok "'$args' is refused with status 2" \
        || fail "'$args' exited $rc, not 2"
done

[ "$fails" -ne 0 ] || echo 'build-installable: all checks passed'
exit "$((fails > 0))"
