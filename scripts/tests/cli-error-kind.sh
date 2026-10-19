#!/usr/bin/env bash
# The CLI contract names one machine-readable way to recognise a missing path.
#
# The drivers word a path that does not exist differently: fs.ext4 and fs.ntfs
# say "not found", fs.xfs and fs.btrfs "no such file or directory" (#502). The
# JSON error object fixes `error` and `code` and nothing else, and status 1 is
# shared by every failure, so a script driving several drivers had to match
# both phrasings. The contract therefore carries a fixed `kind` field,
# `"kind": "not_found"`, set by one core constructor, and binds every verb
# that takes a path to read from it. This guard fails when the contract stops
# naming the field, its value, the constructor or any of those verbs.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DOC="$REPO/docs/cli-tooling-design.md"
fails=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1" >&2; fails=$((fails + 1)); }

# The paragraph (blank-line separated) that states the kind.
para="$(awk -v RS= '/"kind": "not_found"/' "$DOC")"

if [ -n "$para" ]; then
    ok "the contract states \`\"kind\": \"not_found\"\`"
else
    bad "the contract has no paragraph stating \`\"kind\": \"not_found\"\`"
fi

if grep -qF '`cli::output::CliError::not_found`' <<<"$para"; then
    ok "the kind names its constructor, \`cli::output::CliError::not_found\`"
else
    bad "the kind paragraph does not name \`cli::output::CliError::not_found\`"
fi

for verb in ls stat read get export; do
    if grep -qF "\`$verb\`" <<<"$para"; then
        ok "the kind binds \`$verb\`"
    else
        bad "the kind paragraph does not name \`$verb\`"
    fi
done

if grep -qF '{"error": "...", "code": 1, "kind": "not_found"}' "$DOC"; then
    ok "the contract shows the missing-path error object whole"
else
    bad "the contract does not show the missing-path error object"
fi

[ "$fails" -eq 0 ] || exit 1
echo "cli-error-kind: all checks passed"
