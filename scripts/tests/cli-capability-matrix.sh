#!/usr/bin/env bash
# The capability executor checks real process exits and image bytes, without
# needing released drivers or filesystem builders in the Shell scripts tier.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/scripts/cli-capability-matrix.sh"
fails=0
ok() { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }
sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT
mkdir -p "$sandbox/bin" "$sandbox/images"
printf 'original image\n' > "$sandbox/images/seed.img"
printf 'input bytes\n' > "$sandbox/images/input.bin"
cp "$sandbox/images/seed.img" "$sandbox/original"
cat > "$sandbox/bin/fs.stub" <<'SH'
#!/usr/bin/env bash
image="$1"
case "$2" in
    ok) printf '{"size":14}\n'; exit 0 ;;
    change) printf 'changed\n' >> "$image"; exit 0 ;;
    pristine) cmp -s "$image" "$ORIGINAL"; exit $? ;;
    literal)
        [ "$3" = 'a name with spaces' ] && [ "$4" = '$(not-a-command)' ] \
            && [ "$(cat)" = 'input bytes' ]; exit $? ;;
    usage) printf '{"error":"usage","code":2}\n' >&2; exit 2 ;;
    failed) printf '{"error":"failed","code":1}\n' >&2; exit 1 ;;
    dirty) printf 'changed\n' >> "$image" ;;
    leak) printf 'leaked output\n' ;;
    bad-json) printf 'not JSON\n' >&2; exit 3 ;;
    wrong-code) printf '{"error":"refused","code":1}\n' >&2; exit 3 ;;
esac
printf '{"error":"refused","code":3}\n' >&2
exit 3
SH
chmod +x "$sandbox/bin/fs.stub"
export ORIGINAL="$sandbox/original"
export PATH="$sandbox/bin:$PATH"
matrix="$sandbox/matrix.tsv"
header() { printf 'tool\tfixture\texit\tstdin\targv...\n' > "$matrix"; }
row() { printf '%s\tseed.img\t%s\t-\t%s\n' "$1" "$2" "$3" >> "$matrix"; }
run_case() {
    local name="$1" want="$2" rc=0
    QUIET_LOG_DIR="$sandbox/log-$name" bash "$SCRIPT" --matrix "$matrix" \
        --images "$sandbox/images" > "$sandbox/output" 2>&1 || rc=$?
    if [ "$rc" = "$want" ]; then ok "$name exits $want"
    else fail "$name exits $rc, wanted $want: $(head -2 "$sandbox/output")"; fi
}

header; row fs.stub 0 ok; row fs.stub 3 refused
run_case supported-and-refused 0
header; row fs.stub 0 change; row fs.stub 0 pristine
run_case each-row-has-a-fresh-image 0
cmp -s "$sandbox/images/seed.img" "$sandbox/original" \
    && ok 'the supplied fixture is unchanged' || fail 'the supplied fixture changed'
header
printf 'fs.stub\tseed.img\t0\tinput.bin\tliteral\ta name with spaces\t$(not-a-command)\n' >> "$matrix"
run_case literal-arguments-and-stdin 0

for verb in usage failed refused; do
    header; row fs.stub 0 "$verb"
    run_case "supported-verb-returns-$verb" 1
done
header; row fs.stub 3 ok
run_case refused-verb-succeeds 1
for verb in dirty leak bad-json wrong-code; do
    header; row fs.stub 3 "$verb"
    run_case "invalid-refusal-$verb" 1
done
header; row fs.missing-capability-tool 0 ok
run_case missing-tool 1
header
printf 'fs.stub\tmissing.img\t0\t-\tok\n' >> "$matrix"
run_case missing-image 1
header
printf 'fs.stub\tseed.img\t0\tmissing.bin\tok\n' >> "$matrix"
run_case missing-stdin 1
header; row fs.stub 2 usage
run_case usage-is-never-a-capability 1
header
run_case empty-matrix 1
printf 'not a matrix\n' > "$matrix"
run_case malformed-header 1
header
printf 'fs.stub\t../original\t0\t-\tok\n' >> "$matrix"
run_case fixture-outside-image-directory 1

if [ "$fails" = 0 ]; then echo 'cli-capability-matrix: all checks passed'
else echo "cli-capability-matrix: $fails check(s) failed" >&2; fi
exit $(( fails > 0 ))
