#!/usr/bin/env bash
#
# fskit-volumes-skip-diskutil.sh — the app never mounts or unmounts a volume
# by running diskutil.
#
# WHAT THIS IS ABOUT (#166).
#
# `diskutil mount /dev/diskN` on an ext4 volume stopped with "Volume on diskN
# failed to mount", after the extension had loaded the volume and passed its
# check. Measured on 2026-10-07 (macOS 26.4, the extension enabled), the
# cause is not in the extension and not in DiskArbitration:
#
#   - diskutil hands `mount` and `unmount` to storagekitd
#     (`-[SKHelperClient mountDisk:...]`). StorageKit lists the volume as
#     `kSKDiskTypeUninitalized`, "File System: None", and fails at once with
#     `com.apple.StorageKit Code=124` ("Disk is not mountable"). It never
#     asks DiskArbitration, and no mount request reaches fskitd.
#   - DiskArbitration has the same volume as `DAVolumeKind = ext4`,
#     `DAVolumeMountable = 1`. `DADiskMount` on it succeeds, and so does
#     `mount -F -t ext4 diskNsM <dir>`. That was true for a bare image and
#     for a GPT partition.
#   - `diskutil unmount <mount path>`, with or without `force`, fails on a
#     mounted FSKit volume with `Code=119` ("The volume needs to be
#     mounted"). `DADiskUnmount` on the same volume succeeds.
#   - `diskutil listFilesystems` names Apple's file systems only.
#
# The `fsck.done` that the issue's log ended with is DiskArbitration's
# probe-time check (`staged fsmodule ... success`), not part of a mount.
#
# So any code here that runs diskutil to mount or unmount a volume fails on
# every FSKit volume the app exists to serve. The app's Unmount button and its
# stale-mount cleanup both did. This guard holds every Swift source to
# DiskArbitration for those verbs. diskutil is still fine for reading, as in
# `diskutil list -plist`.
#
# TEXT ONLY. Runs in the ubuntu `Shell scripts` job; it builds nothing.
#
#   bash scripts/tests/fskit-volumes-skip-diskutil.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fails=0
ok()   { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1" >&2; fails=$((fails + 1)); }

command -v python3 >/dev/null || { echo "python3 is required to read the sources" >&2; exit 1; }

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

# One rule, as a program over a tree of Swift files: a file that names the
# diskutil executable must not build an argument list whose first element is
# a mount or unmount verb. Prints `bad <file>:<line>: <verb>` per hit.
cat > "$SANDBOX/rule.py" <<'PY'
import os, re, sys

VERBS = ("mount", "unmount", "mountDisk", "unmountDisk", "eject")
ARGS = re.compile(r'arguments\s*=\s*\[\s*"(%s)"' % "|".join(VERBS))

root = sys.argv[1]
for top in sys.argv[2:]:
    for dirpath, _, files in os.walk(os.path.join(root, top)):
        for name in sorted(files):
            if not name.endswith(".swift"):
                continue
            path = os.path.join(dirpath, name)
            with open(path, encoding="utf-8", errors="replace") as f:
                text = f.read()
            if "/usr/sbin/diskutil" not in text:
                continue
            for n, line in enumerate(text.splitlines(), 1):
                m = ARGS.search(line)
                if m:
                    print("bad %s:%d: diskutil %s" % (os.path.relpath(path, root), n, m.group(1)))
PY

DIRS=(DiskJockeyApplication DiskJockeyLibrary DiskJockeyAgent DiskJockeyFileProvider
      DiskJockeyEXT4 DiskJockeyNTFS DiskJockeyXFS DiskJockeyBTRFS DiskJockeyEROFS DiskJockeySQUASHFS)

for d in "${DIRS[@]}"; do
    [ -d "$REPO/$d" ] || fail "source directory $d is missing, so the rule cannot see it"
done

hits="$(python3 "$SANDBOX/rule.py" "$REPO" "${DIRS[@]}")"
if [ -z "$hits" ]; then
    ok "no Swift source mounts or unmounts through diskutil"
else
    while IFS= read -r line; do
        fail "$line — storagekitd refuses FSKit volumes; use DiskArbitration"
    done <<< "$hits"
fi

# The rule fails on a copy that breaks it, and passes the read-only use.
mkdir -p "$SANDBOX/tree/A"
cat > "$SANDBOX/tree/A/Bad.swift" <<'SWIFT'
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
p.arguments = ["unmount", "force", path]
SWIFT
cat > "$SANDBOX/tree/A/Fine.swift" <<'SWIFT'
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
p.arguments = ["list", "-plist"]
SWIFT
out="$(python3 "$SANDBOX/rule.py" "$SANDBOX/tree" A)"
case "$out" in
    "bad A/Bad.swift:3: diskutil unmount") ok "rejects diskutil unmount and accepts diskutil list" ;;
    *) fail "the rule did not single out the unmount in the fixture (got: ${out:-nothing})" ;;
esac

if [ "$fails" -gt 0 ]; then
    echo "fskit-volumes-skip-diskutil: $fails check(s) failed" >&2
    exit 1
fi
echo "fskit-volumes-skip-diskutil: all checks passed"
