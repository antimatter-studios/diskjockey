#!/usr/bin/env bash
# Verdict for the three jobs named by ci-ok.needs in ci.yml.
set -uo pipefail

if [ "$#" -ne 1 ]; then
    echo 'ci-ok: expected one joined needs-result argument' >&2
    exit 1
fi

results=()
read -r -a results <<< "$1"
if [ "${#results[@]}" -ne 3 ]; then
    echo "ci-ok: expected three needed jobs, received ${#results[@]} result(s)" >&2
    exit 1
fi

for result in "${results[@]}"; do
    if [ "$result" != success ]; then
        echo "ci-ok: a needed job reported $result instead of success" >&2
        exit 1
    fi
done
echo 'ci-ok: all three needed jobs succeeded'
