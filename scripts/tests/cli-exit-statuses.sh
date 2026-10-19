#!/usr/bin/env bash
# The CLI contract names one exit status per kind of answer, for fs.<fs> too.
#
# fsck.* had its statuses written down; fs.<fs> did not, and the drivers
# drifted: a non-empty `rmdir` exited 1 from fs.ext4 and 3 from fs.btrfs, so a
# script driving both could not tell a refusal from a failure (#390). The
# contract's table is what every driver is held to, so it has to name each
# status, and the refusal a volume's state causes has to be its own row,
# covering every namespace verb.
#
# The statuses are rust-fs-core's: `cli::output` exports one `EXIT_*`
# constant per row. An operation that completed with data it could not
# recover exits 5, `partial` (rust-fs-core#357), and its row names the
# constant. Every constant in the core checkout beside this one
# ($FS_CORE_ROOT, else ../rust-fs-core) must have a row carrying its value.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DOC="$REPO/docs/cli-tooling-design.md"
OUTPUT="${FS_CORE_ROOT:-$REPO/../rust-fs-core}/src/cli/output.rs"
fails=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1" >&2; fails=$((fails + 1)); }

row() { grep -E "^ *\| *\`?$1\`? *\|" "$DOC" | head -n 1; }

for status in 0:success 1:failed 2:usage 3:unsupported 4:refused 5:partial; do
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

if grep -qF '`cli::output::EXIT_PARTIAL`' <<<"$(row 5)"; then
    ok "the partial row names \`cli::output::EXIT_PARTIAL\`"
else
    bad "the partial row does not name \`cli::output::EXIT_PARTIAL\`"
fi

if [ ! -f "$OUTPUT" ]; then
    bad "$OUTPUT does not exist: check rust-fs-core out beside this repository, or set FS_CORE_ROOT"
else
    constants="$(grep -E '^pub const EXIT_[A-Z_]+: u8 = [0-9]+;' "$OUTPUT")"
    if [ -z "$constants" ]; then
        bad "$OUTPUT exports no EXIT_* constant"
    fi
    while read -r _ _ name _ _ value; do
        [ -n "${name:-}" ] || continue
        name="${name%:}" value="${value%;}"
        if [ -n "$(row "$value")" ]; then
            ok "core's $name ($value) has a row in the fs.<fs> exit table"
        else
            bad "core's $name ($value) has no row in the fs.<fs> exit table"
        fi
    done <<<"$constants"
fi

[ "$fails" -eq 0 ] || exit 1
echo "cli-exit-statuses: all checks passed"
