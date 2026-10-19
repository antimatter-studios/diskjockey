#!/usr/bin/env bash
# Execute capability rows against prepared images (#401, part of #387).
# --install uses the exact attested releases from SIBLING_PINS.txt (#488).
# Independent fixture construction remains under #402.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
usage() {
    echo 'usage: scripts/cli-capability-matrix.sh --matrix FILE --images DIR [--install] [--verbose]' >&2
    exit 2
}
fails=0
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }

# TSV arguments are literal fields, never shell code. Reject empty fields
# before read: IFS whitespace would otherwise collapse adjacent tabs.
parse_row() {
    local line="$1"
    fields=()
    if [[ "$line" == $'\t'* || "$line" == *$'\t' || "$line" == *$'\t\t'* || "$line" == *$'\r'* ]]; then
        fail "row $number: empty fields or CR characters"; return 1
    fi
    IFS=$'\t' read -r -a fields <<< "$line"
    if [ "${#fields[@]}" -lt 5 ]; then
        fail "row $number: expected tool, fixture, exit, stdin and at least one argument"; return 1
    fi
    if ! [[ "${fields[0]}" =~ ^fs\.[a-z0-9][a-z0-9.-]*$ ]]; then
        fail "row $number: invalid tool name ${fields[0]}"; return 1
    fi
    if ! [[ "${fields[1]}" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
        fail "row $number: fixture must be a filename inside --images"; return 1
    fi
    case "${fields[2]}" in 0|3) ;; *) fail "row $number: capability exit must be 0 or 3"; return 1 ;; esac
    if [ "${fields[3]}" != - ] && ! [[ "${fields[3]}" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
        fail "row $number: stdin must be - or a filename inside --images"; return 1
    fi
}

run_all() {
    local matrix="$1" images="$2" install="${3:-0}" work line number=0 rows=0 ran=0 rc input image before out err prior
    local -a fields
    [ -f "$matrix" ] || { fail "missing matrix $matrix; provide --matrix FILE"; return 1; }
    [ -d "$images" ] || { fail "missing image directory $images; build the independent fixtures (#402)"; return 1; }
    command -v jq >/dev/null 2>&1 || { fail 'missing jq; install jq to validate shared JSON errors'; return 1; }
    WORK="$(mktemp -d)" || return 1
    work="$WORK"
    # The directory is owned by this invocation and contains only its copies.
    trap 'rm -rf "$WORK"' EXIT
    cp "$matrix" "$work/matrix.tsv" || return 1
    IFS= read -r line < "$work/matrix.tsv" || [ -n "$line" ] || { fail 'empty matrix'; return 1; }
    [ "$line" = $'tool\tfixture\texit\tstdin\targv...' ] \
        || { fail 'matrix header must be tool<TAB>fixture<TAB>exit<TAB>stdin<TAB>argv...'; return 1; }

    # Check the entire matrix before starting any command, so a missing
    # prerequisite cannot turn a prefix of the matrix into a passing run.
    while IFS= read -r line || [ -n "$line" ]; do
        number=$((number + 1))
        [ "$number" = 1 ] && continue
        case "$line" in ''|\#*) continue ;; esac
        parse_row "$line" || continue
        rows=$((rows + 1))
        if [ "$install" = 1 ]; then
            case "${fields[0]}" in
                fs.ext4|fs.ntfs|fs.xfs|fs.btrfs|fs.bcachefs|fs.erofs|fs.squashfs) ;;
                *) fail "row $number: no pinned release for ${fields[0]}; add its capability installer mapping (#488)" ;;
            esac
        else
            command -v "${fields[0]}" >/dev/null 2>&1 \
                || fail "row $number: missing tool ${fields[0]}; use --install for its pinned release (#488)"
        fi
        [ -f "$images/${fields[1]}" ] \
            || fail "row $number: missing image ${fields[1]}; build the independent fixtures (#402)"
        if [ "${fields[3]}" != - ] && [ ! -f "$images/${fields[3]}" ]; then
            fail "row $number: missing stdin fixture ${fields[3]}"
        fi
    done < "$work/matrix.tsv"
    [ "$rows" -gt 0 ] || fail 'matrix contains no operations'
    [ "$fails" = 0 ] || return 1

    if [ "$install" = 1 ]; then
        bash "$ROOT/scripts/install-cli-capabilities.sh" --dest "$work/tools" || return 1
        export PATH="$work/tools/bin:$PATH"
        # The private installation is removed on exit; retain its exact
        # release identities and digests in the capability run's log.
        cat "$work/tools/releases.tsv" || return 1
    fi
    number=0
    out="$work/stdout" err="$work/stderr"
    while IFS= read -r line || [ -n "$line" ]; do
        number=$((number + 1))
        [ "$number" = 1 ] && continue
        case "$line" in ''|\#*) continue ;; esac
        parse_row "$line" || return 1
        # A supported mutation must not affect the next operation's fixture.
        image="$work/target-$number.img" before="$work/before-$number.img"
        if ! cp "$images/${fields[1]}" "$image" || ! chmod u+w "$image" || ! cp "$image" "$before"; then
            fail "row $number: could not copy the image"; return 1
        fi
        input=/dev/null
        [ "${fields[3]}" = - ] || input="$images/${fields[3]}"
        rc=0
        "${fields[0]}" "$image" "${fields[@]:4}" < "$input" > "$out" 2> "$err" || rc=$?
        ran=$((ran + 1))
        prior="$fails"
        if [ "$rc" != "${fields[2]}" ]; then
            fail "row $number: ${fields[0]} ${fields[4]} exited $rc, expected ${fields[2]} (usage exit 2 is never a capability)"
        fi
        if [ "$rc" = 3 ]; then
            cmp -s "$image" "$before" || fail "row $number: refused operation changed the image"
            [ ! -s "$out" ] || fail "row $number: refused operation wrote to stdout"
            jq -e -s 'length == 1 and (.[0] | type == "object" and
                (.error | type == "string" and length > 0) and .code == 3)' "$err" >/dev/null 2>&1 \
                || fail "row $number: refusal is not one shared JSON error with code 3"
        fi
        if [ "$fails" != "$prior" ]; then
            sed -n '1,3p' "$err" | cut -c1-300 | sed 's/^/driver stderr: /'
        fi
        printf 'ran row %s: %s %s (exit %s, expected %s)\n' "$number" "${fields[0]}" "${fields[4]}" "$rc" "${fields[2]}"
        # Large filesystem images must not accumulate across all matrix rows.
        rm -f "$image" "$before" || { fail "row $number: could not clean up its image copies"; return 1; }
    done < "$work/matrix.tsv"
    [ "$ran" = "$rows" ] || fail "only $ran of $rows matrix operations ran"
    echo "ran $ran capability operation(s) (matrix requires $rows)"
    [ "$fails" = 0 ]
}

if [ "${1:-}" = --run-all ]; then
    [ "$#" = 3 ] || [ "$#" = 4 ] || usage
    run_all "$2" "$3" "${4:-0}"
    exit $?
fi
matrix='' images='' install=0 verbose=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --matrix) [ "$#" -ge 2 ] || usage; matrix="$2"; shift 2 ;;
        --images) [ "$#" -ge 2 ] || usage; images="$2"; shift 2 ;;
        --install) install=1; shift ;;
        --verbose) verbose=(--verbose); shift ;;
        *) usage ;;
    esac
done
[ -n "$matrix" ] && [ -n "$images" ] || usage
# Initial ceiling: 84 driver/operation cells plus preflight diagnostics.
# The workflow integration (#403) will record its released-tool measurement.
rc=0
"$ROOT/scripts/quiet-run.sh" ${verbose[@]+"${verbose[@]}"} cli-capability-matrix 200 30000 -- \
    bash "$ROOT/scripts/cli-capability-matrix.sh" --run-all "$matrix" "$images" "$install" || rc=$?
exit "$rc"
