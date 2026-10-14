#!/usr/bin/env bash
# The Linux half of the XFS FSKit mutation oracle, run in
# fs-linux-test-harness's VM (diskjockey#355). It hands <dir> to the guest
# through the shared directory, runs scripts/oracles/xfs-mutations-linux.sh
# there as root, and brings the VM down when it ends, however it ends.
#
#   scripts/xfs-mutations-vm.sh create <dir>   # <dir>/xfs.img and <dir>/features
#   scripts/xfs-mutations-vm.sh verify <dir>   # <dir>/xfs.img against <dir>/expected/
#
# Between the two, scripts/test-xfs-mutations.sh changes the image through
# the FSKit volume on macOS. The XFS mutations workflow runs all three; by
# hand, on a Mac the harness can boot its VM on (`chore vm:host:check`):
#
#   scripts/xfs-mutations-vm.sh create tmp/xfs-mutations
#   mkdir -p tmp/xfs-mutations/expected
#   scripts/test-xfs-mutations.sh tmp/xfs-mutations/xfs.img tmp/xfs-mutations/expected
#   scripts/xfs-mutations-vm.sh verify tmp/xfs-mutations
#
# Nothing here runs an xfsprogs tool or mounts anything on the host. The
# guest is the one Linux, with the one xfsprogs, that judges every run,
# wherever it was started (fs-linux-test-harness.toml).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
usage() { echo 'usage: scripts/xfs-mutations-vm.sh create|verify <dir>' >&2; exit 2; }
[ $# -eq 2 ] || usage
action="$1"
dir="$2"
case "$action" in create | verify) ;; *) usage ;; esac

pin="$(awk '$1=="fs-linux-test-harness"{print $2}' SIBLING_PINS.txt)"
harness="$ROOT/../fs-linux-test-harness"
if [ ! -x "$harness/scripts/vm.sh" ]; then
    echo "FAIL: fs-linux-test-harness is not checked out beside this repository: check out its ${pin:-pinned} tag at ../fs-linux-test-harness (SIBLING_PINS.txt)" >&2
    exit 1
fi
echo "fs-linux-test-harness $(git -C "$harness" describe --tags --always 2>/dev/null || echo '(unknown)'), pinned at $pin"
if [ "$action" = verify ] && [ ! -f "$dir/xfs.img" ]; then
    echo "FAIL: $dir/xfs.img is missing; run scripts/xfs-mutations-vm.sh create $dir first" >&2
    exit 1
fi

# This script is the session: the VM it boots comes down when it exits.
# shellcheck source=/dev/null
. "$harness/scripts/vm-session.sh"
share="$("$harness/scripts/vm.sh" share)"
[ -n "$share" ] || { echo 'FAIL: fs-linux-test-harness names no shared directory' >&2; exit 1; }
rm -rf "$share/xfs-mutations"
mkdir -p "$share/xfs-mutations"
if [ "$action" = verify ]; then
    cp -R "$dir/." "$share/xfs-mutations/"
fi
"$harness/scripts/vm.sh" run "bash /repo/scripts/oracles/xfs-mutations-linux.sh $action /share/xfs-mutations"
if [ "$action" = create ]; then
    mkdir -p "$dir"
    cp -R "$share/xfs-mutations/." "$dir/"
fi
