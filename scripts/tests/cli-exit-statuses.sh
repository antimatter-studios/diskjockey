#!/usr/bin/env bash
# The CLI contract names one exit status per kind of answer, for fs.<fs> too.
#
# fsck.* had its statuses written down; fs.<fs> did not, and the drivers
# drifted: a non-empty `rmdir` exited 1 from fs.ext4 and 3 from fs.btrfs, so a
# script driving both could not tell a refusal from a failure (#390). The
# contract's table is what every driver is held to, so it has to name each
# status, and the refusal a volume's state causes has to be its own row,
# covering every namespace verb.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DOC="$REPO/docs/cli-tooling-design.md"
fails=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1" >&2; fails=$((fails + 1)); }

row() { grep -E "^ *\| *\`?$1\`? *\|" "$DOC" | head -n 1; }

for status in 0:success 1:failed 2:usage 3:unsupported 4:refused; do
    code="${status%%:*}" name="${status#*:}"
    line="$(row "$code")"
    if [ -n "$line" ] && grep -qi "$name" <<<"$line"; then
        ok "the fs.<fs> exit table names $code as $name"
    else
        bad "the fs.<fs> exit table has no $code ($name) row: '${line}'"
    fi
done

refused="$(row 4)"
for verb in rm rmdir mv ln mkdir truncate 'write --at'; do
    if grep -qF "\`$verb\`" <<<"$refused"; then
        ok "the refused row covers \`$verb\`"
    else
        bad "the refused row does not name \`$verb\`"
    fi
done

[ "$fails" -eq 0 ] || exit 1
echo "cli-exit-statuses: all checks passed"
