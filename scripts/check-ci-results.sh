#!/usr/bin/env bash
# Verdict for the three jobs named by ci-ok.needs in ci.yml.
set -uo pipefail

# The second argument is the changes job's `code` output. Only when it is
# `false`, a change to documentation alone, is a skipped job expected rather
# than red: the library tests and the Xcode job are skipped then.
if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    echo 'ci-ok: expected one joined needs-result argument and the code output' >&2
    exit 1
fi
code="${2:-}"

results=()
read -r -a results <<< "$1"
if [ "${#results[@]}" -ne 4 ]; then
    echo "ci-ok: expected four needed jobs, received ${#results[@]} result(s)" >&2
    exit 1
fi

for result in "${results[@]}"; do
    if [ "$result" = skipped ] && [ "$code" = false ]; then
        continue
    fi
    if [ "$result" != success ]; then
        echo "ci-ok: a needed job reported $result instead of success" >&2
        exit 1
    fi
done
echo 'ci-ok: all four needed jobs succeeded, or were skipped for documentation alone'
