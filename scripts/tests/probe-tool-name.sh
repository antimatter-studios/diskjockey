#!/usr/bin/env bash
#
# probe-tool-name.sh — the probe is staged, found and named as `blk.probe`
# (diskjockey#236).
#
# The tool from rust-blk-probe is `blk.probe` everywhere, by owner decision,
# so there is one name for it. The app finds it by path rather than on PATH,
# so a stale name builds cleanly and fails at run time with "binary not
# found". Three things have to agree and nothing else checks them:
#
#   1. scripts/build-blk.probe.sh builds the sibling's cargo target
#      (`blk_probe`: cargo refuses a dot) and stages lib/blk.probe/blk.probe.
#      Run for real, against stub `cargo` and `lipo` on PATH.
#   2. Both Swift call sites look for that path, and for `blk.probe` in the
#      bundle's Resources.
#   3. No tracked file spells the tool `blk-probe`. The repository is still
#      `rust-blk-probe`, and dated reports record what things were called
#      when they were written; those are the only exceptions.
#
#   bash scripts/tests/probe-tool-name.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SELF="scripts/tests/$(basename "${BASH_SOURCE[0]}")"
BUILD="$REPO/scripts/build-blk.probe.sh"
fails=0
ok()   { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }

sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT

# --- 1. The build script stages lib/blk.probe/blk.probe. -------------------
if [ ! -f "$BUILD" ]; then
    fail "scripts/build-blk.probe.sh is missing"
else
    src="$sandbox/rust-blk-probe"; root="$sandbox/app"; bin="$sandbox/bin"
    mkdir -p "$src" "$root" "$bin" "$sandbox/home/.cargo/bin"
    # cargo: record the arguments, and write the target cargo would write.
    cat > "$bin/cargo" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG"
triple=""; name=""
while [ $# -gt 0 ]; do
    case "$1" in
        --target) triple="$2"; shift ;;
        --bin) name="$2"; shift ;;
    esac
    shift
done
[ -n "$name" ] || { echo "stub cargo: no --bin given" >&2; exit 1; }
mkdir -p "target/$triple/release"
printf '#!/bin/sh\n' > "target/$triple/release/$name"
chmod +x "target/$triple/release/$name"
EOF
    # lipo: -create <in>... -output <out> copies the first input; -info names it.
    cat > "$bin/lipo" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = -info ]; then echo "Architectures in the fat file: $2 are: x86_64 arm64"; exit 0; fi
first=""; out=""
while [ $# -gt 0 ]; do
    case "$1" in
        -create) ;;
        -output) out="$2"; shift ;;
        *) [ -f "$1" ] || { echo "stub lipo: no such input $1" >&2; exit 1; }
           [ -n "$first" ] || first="$1" ;;
    esac
    shift
done
cp "$first" "$out"
EOF
    chmod +x "$bin/cargo" "$bin/lipo"

    if HOME="$sandbox/home" PATH="$bin:$PATH" STUB_LOG="$sandbox/cargo.log" \
        SRCROOT="$root" PROBE_SRC="$src" bash "$BUILD" > "$sandbox/build.out" 2>&1; then
        staged="$(cd "$root/lib" 2>/dev/null && find . -mindepth 1 | LC_ALL=C sort | tr '\n' ' ')"
        if [ "$staged" = "./blk.probe ./blk.probe/blk.probe " ]; then
            ok "the build script stages lib/blk.probe/blk.probe and nothing else"
        else
            fail "the build script staged [$staged], expected lib/blk.probe/blk.probe alone"
        fi
        [ -x "$root/lib/blk.probe/blk.probe" ] && ok "the staged blk.probe is executable" \
            || fail "lib/blk.probe/blk.probe is not executable"
        if [ "$(grep -c -- '--bin blk_probe' "$sandbox/cargo.log")" -eq 2 ]; then
            ok "cargo is asked for the blk_probe target on both architectures"
        else
            fail "cargo was not asked for --bin blk_probe twice: $(tr '\n' ';' < "$sandbox/cargo.log")"
        fi
    else
        fail "the build script failed: $(tail -5 "$sandbox/build.out")"
    fi
fi

# --- 2. The Swift call sites look for blk.probe. --------------------------
agent="$REPO/DiskJockeyAgent/AgentImpl.swift"
mount="$REPO/DiskJockeyApplication/Services/FSKitMountService.swift"
grep -qF '"Resources/blk.probe"' "$agent" && ok "the agent looks in Resources/blk.probe" \
    || fail "DiskJockeyAgent/AgentImpl.swift does not look for Resources/blk.probe"
grep -qF '"lib/blk.probe/blk.probe"' "$agent" && ok "the agent's dev fallback is lib/blk.probe/blk.probe" \
    || fail "DiskJockeyAgent/AgentImpl.swift does not fall back to lib/blk.probe/blk.probe"
grep -qF 'forResource: "blk.probe"' "$mount" && ok "the app looks for the blk.probe resource" \
    || fail "FSKitMountService.swift does not look for the blk.probe resource"
grep -qF '"lib/blk.probe/blk.probe"' "$mount" && ok "the app's dev fallback is lib/blk.probe/blk.probe" \
    || fail "FSKitMountService.swift does not fall back to lib/blk.probe/blk.probe"

# --- 3. Nothing spells the tool blk-probe. --------------------------------
# `rust-blk-probe` is the repository and is fine. The two dated reports are
# records of 2026-08-30 and are not rewritten.
hits="$(git -C "$REPO" grep -nF 'blk-probe' -- . \
    ":(exclude)$SELF" \
    ':(exclude)docs/constellation-report-2026-08-30.md' \
    ':(exclude)docs/constellation/evidence-2026-08-30.md' |
    sed 's/rust-blk-probe//g' | grep -F 'blk-probe' || true)"
if [ -z "$hits" ]; then
    ok "no tracked file names the tool blk-probe"
else
    fail "these still name the tool blk-probe:"$'\n'"$hits"
fi

echo
if [ "$fails" -eq 0 ]; then
    echo 'probe-tool-name: all checks passed'
else
    echo "probe-tool-name: $fails check(s) failed" >&2
fi
exit "$((fails > 0))"
