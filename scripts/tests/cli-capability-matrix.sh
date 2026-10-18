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
if cmp -s "$sandbox/images/seed.img" "$sandbox/original"; then
    ok 'the supplied fixture is unchanged'
else fail 'the supplied fixture changed'; fi
header
# shellcheck disable=SC2016 # Command-substitution text must remain literal.
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

# Release installation is a separate boundary: these are archive/gh doubles,
# not filesystem fixtures or claims about a released driver's capabilities.
installer="$ROOT/scripts/install-cli-capabilities.sh"
drivers='ext4 ntfs xfs btrfs bcachefs erofs squashfs'
mkdir -p "$sandbox/package/bin" "$sandbox/package/libexec" "$sandbox/empty"
cat > "$sandbox/package/libexec/driver" <<'SH'
#!/usr/bin/env bash
echo executed >> "$STUB_EXEC"
exit 0
SH
chmod +x "$sandbox/package/libexec/driver"
for driver in $drivers; do
    ln -s ../libexec/driver "$sandbox/package/bin/fs.$driver"
    pin="$(awk -v repo="rust-fs-$driver" '$1==repo{print $2}' "$ROOT/SIBLING_PINS.txt")"
    if [[ "$pin" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then ok "$driver has one exact release pin"
    else fail "$driver lacks one exact release pin"; fi
done
tar -czf "$sandbox/package.tar.gz" -C "$sandbox/package" bin libexec
tar -czf "$sandbox/empty.tar.gz" -C "$sandbox/empty" .
cat > "$sandbox/bin/gh" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG"
case "$1 $2" in
    'release download')
        tag="$3"; shift 3
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --repo) repo="$2" ;;
                --pattern) asset="$2" ;;
                --dir) dest="$2" ;;
                *) exit 1 ;;
            esac
            shift 2
        done
        pin="$(awk -v repo="${repo#*/}" '$1==repo{print $2}' "$STUB_PINS")"
        [ "$tag" = "$pin" ] && [ "$asset" = "${repo#*/}-${pin#v}-$STUB_PLATFORM.tar.gz" ] || exit 1
        [ "$STUB_MODE" != missing-asset ] || exit 1
        cp "$STUB_ARCHIVE" "$dest/$asset"
        ;;
    'attestation verify')
        [ "$STUB_MODE" != unverified ] || exit 1
        case "$*" in *'--repo antimatter-studios/rust-fs-'*'--signer-workflow antimatter-studios/rust-fs-core/.github/workflows/release-cli.yml --source-ref refs/tags/v'*) ;;
            *) exit 1 ;;
        esac
        ;;
    *) exit 1 ;;
esac
SH
chmod +x "$sandbox/bin/gh"
case "$(uname -s)/$(uname -m)" in
    Darwin/arm64) export STUB_PLATFORM=darwin-arm64 ;;
    Linux/x86_64) export STUB_PLATFORM=linux-x86_64 ;;
    *) fail 'release guard needs a supported release platform'; export STUB_PLATFORM=unsupported ;;
esac
export STUB_LOG="$sandbox/release.log" STUB_EXEC="$sandbox/executed"
export STUB_PINS="$ROOT/SIBLING_PINS.txt" STUB_ARCHIVE="$sandbox/package.tar.gz" STUB_MODE=good
install_case() {
    local name="$1" want="$2" reason="${3:-}" rc=0
    : > "$STUB_LOG"
    bash "$installer" --dest "$sandbox/$name" --pins "$STUB_PINS" > "$sandbox/install.out" 2>&1 || rc=$?
    if [ "$rc" = "$want" ] && { [ -z "$reason" ] || grep -qF "$reason" "$sandbox/install.out"; }; then
        ok "release $name exits $want with its reason"
    else fail "release $name exits $rc, wanted $want ($reason): $(head -2 "$sandbox/install.out")"; fi
    if [ "$want" != 0 ] && [ -e "$sandbox/$name" ]; then fail "$name stages no partial installation"; fi
}
install_case installed 0
for driver in $drivers; do
    pin="$(awk -v repo="rust-fs-$driver" '$1==repo{print $2}' "$STUB_PINS")"
    if [ -x "$sandbox/installed/bin/fs.$driver" ] \
        && grep -qF "release download $pin --repo antimatter-studios/rust-fs-$driver " "$STUB_LOG" \
        && grep -qF -- "--source-ref refs/tags/$pin" "$STUB_LOG" \
        && grep -qF "rust-fs-$driver" "$sandbox/installed/releases.tsv" 2>/dev/null; then
        ok "$driver stages its pinned binary and provenance record"
    else fail "$driver lacks its pinned binary or provenance record"; fi
done
[ ! -f "$STUB_EXEC" ] || fail 'installation executes no driver'
STUB_MODE=missing-asset; install_case missing-asset 1 'release asset'
STUB_MODE=unverified; install_case unverified 1 'attestation'
if grep -qF 'attestation verify' "$STUB_LOG"; then ok 'unverified archive reaches the attestation boundary'
else fail 'unverified archive was not checked'; fi
STUB_MODE=good; STUB_ARCHIVE="$sandbox/empty.tar.gz"
install_case missing-binary 1 'bin/fs.ext4'
STUB_ARCHIVE="$sandbox/package.tar.gz"
awk '$1!="rust-fs-ext4"' "$ROOT/SIBLING_PINS.txt" > "$sandbox/missing-pins"
STUB_PINS="$sandbox/missing-pins"; install_case missing-pin 1 'SIBLING_PINS'
if [ ! -s "$STUB_LOG" ]; then ok 'all pins are checked before downloads'
else fail 'missing pin reached gh'; fi
cp "$ROOT/SIBLING_PINS.txt" "$sandbox/duplicate-pins"
printf 'rust-fs-ext4 v99.0.0\n' >> "$sandbox/duplicate-pins"
STUB_PINS="$sandbox/duplicate-pins"; install_case duplicate-pin 1 'SIBLING_PINS'
STUB_PINS="$ROOT/SIBLING_PINS.txt"
header; row fs.ext4 0 ok
rc=0
QUIET_LOG_DIR="$sandbox/installed-run" bash "$SCRIPT" --matrix "$matrix" \
    --images "$sandbox/images" --install > "$sandbox/installed-run.out" 2>&1 || rc=$?
if [ "$rc" = 0 ] && [ -s "$STUB_EXEC" ]; then ok 'matrix --install runs the verified tool'
else fail "matrix --install failed: $(head -2 "$sandbox/installed-run.out")"; fi
: > "$STUB_EXEC"
STUB_MODE=unverified
rc=0
QUIET_LOG_DIR="$sandbox/refused-run" bash "$SCRIPT" --matrix "$matrix" \
    --images "$sandbox/images" --install > "$sandbox/refused-run.out" 2>&1 || rc=$?
if [ "$rc" = 1 ] && [ ! -s "$STUB_EXEC" ]; then ok 'failed verification executes no matrix operation'
else fail 'failed verification did not stop matrix execution'; fi

if [ "$fails" = 0 ]; then echo 'cli-capability-matrix: all checks passed'
else echo "cli-capability-matrix: $fails check(s) failed" >&2; fi
exit $(( fails > 0 ))
