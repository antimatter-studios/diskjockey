#!/usr/bin/env bash
#
# probe-is-pinned.sh — the probe the app runs is the attested release of the
# rust-blk-probe tag SIBLING_PINS.txt names, and nothing else (diskjockey#239).
#
# blk.probe parses untrusted images before anything is mounted, and it was the
# one sibling built from whatever ../rust-blk-probe had checked out: any
# branch, any uncommitted change, and with its six parser crates taken from
# whatever their own checkouts held, because they are path dependencies. So
# scripts/build-blk.probe.sh no longer builds it. It downloads the
# darwin-arm64 tarball from the pinned tag's GitHub release, checks it against
# the release's .sha256, verifies its build-provenance attestation was signed
# by rust-blk-probe's release workflow, and only then stages bin/blk.probe.
#
# Run for real, against a stub `gh` on PATH that serves a fixture tarball, and
# a `cargo` that records being called. Checked:
#
#   1. the pinned tag is the one downloaded, and the probe is staged at
#      lib/blk.probe/blk.probe, executable, beside a record of what it is;
#   2. the attestation is verified against rust-blk-probe's release workflow;
#   3. cargo is never run and ../rust-blk-probe is never read;
#   4. a checksum that does not match, an attestation that does not verify, a
#      tarball without bin/blk.probe and a missing pin each stop the script,
#      and each leaves nothing staged.
#
#   bash scripts/tests/probe-is-pinned.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD="$REPO/scripts/build-blk.probe.sh"
fails=0
ok()   { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }

sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT

sha256() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
    else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# THE PIN IN THIS REPOSITORY. Every run below uses it, so the guard follows a
# re-pin rather than naming a version of its own.
pin="$(awk '$1=="rust-blk-probe"{print $2}' "$REPO/SIBLING_PINS.txt")"
if [ -n "$pin" ]; then
    ok "SIBLING_PINS.txt pins rust-blk-probe at $pin"
else
    fail "SIBLING_PINS.txt names no rust-blk-probe tag"
    pin="v0.0.0"
fi
version="${pin#v}"
asset="rust-blk-probe-${version}-darwin-arm64.tar.gz"

# A fixture release: the tarball the release workflow publishes, and one
# whose layout is wrong.
mkdir -p "$sandbox/release/good/bin" "$sandbox/release/empty/bin"
printf '#!/bin/sh\necho fixture probe\n' > "$sandbox/release/good/bin/blk.probe"
chmod +x "$sandbox/release/good/bin/blk.probe"
printf 'MIT\n' > "$sandbox/release/good/LICENSE"
printf 'MIT\n' > "$sandbox/release/empty/LICENSE"
tar -C "$sandbox/release/good" -czf "$sandbox/release/good.tar.gz" bin LICENSE
tar -C "$sandbox/release/empty" -czf "$sandbox/release/empty.tar.gz" LICENSE

bin="$sandbox/bin"
mkdir -p "$bin"
# gh: `release download` writes the asset and its .sha256 into --dir, as the
# real one does; `attestation verify` answers STUB_ATTEST. Every call is
# logged.
cat > "$bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >> "$STUB_LOG"
case "$1 $2" in
    "release download")
        shift 2
        tag="$1"; shift
        dir="."
        while [ $# -gt 0 ]; do
            case "$1" in --dir|-D) dir="$2"; shift ;; esac
            shift
        done
        [ "$tag" = "$STUB_TAG" ] || { echo "release not found: $tag" >&2; exit 1; }
        cp "$STUB_TARBALL" "$dir/$STUB_ASSET"
        printf '%s  %s\n' "$STUB_SUM" "$STUB_ASSET" > "$dir/$STUB_ASSET.sha256"
        ;;
    "attestation verify")
        [ "$STUB_ATTEST" = ok ] || { echo "no attestation matched" >&2; exit 1; }
        ;;
    *) echo "stub gh: unexpected $*" >&2; exit 1 ;;
esac
EOF
# cargo: this script must never build the probe.
cat > "$bin/cargo" <<'EOF'
#!/usr/bin/env bash
echo "cargo $*" >> "$STUB_LOG"
exit 1
EOF
chmod +x "$bin/gh" "$bin/cargo"

# run <label> <tarball> <sum> <attest> [pins-file] — a fresh app root each
# time; prints the root. A poisoned ../rust-blk-probe sits beside it.
run() {
    local label="$1" tarball="$2" sum="$3" attest="$4" pins="${5:-$REPO/SIBLING_PINS.txt}"
    local root="$sandbox/$label/app"
    mkdir -p "$root" "$sandbox/$label/rust-blk-probe"
    printf 'poison\n' > "$sandbox/$label/rust-blk-probe/Cargo.toml"
    cp "$pins" "$root/SIBLING_PINS.txt"
    : > "$sandbox/$label/log"
    HOME="$sandbox/home" PATH="$bin:$PATH" STUB_LOG="$sandbox/$label/log" \
        STUB_TAG="$pin" STUB_ASSET="$asset" STUB_TARBALL="$tarball" STUB_SUM="$sum" \
        STUB_ATTEST="$attest" SRCROOT="$root" \
        bash "$BUILD" > "$sandbox/$label/out" 2>&1
    echo $? > "$sandbox/$label/status"
}
status() { cat "$sandbox/$1/status"; }
staged() { (cd "$sandbox/$1/app/lib" 2>/dev/null && find . -mindepth 1 | LC_ALL=C sort | tr '\n' ' '); }

good_sum="$(sha256 "$sandbox/release/good.tar.gz")"

# --- 1. The pinned release is staged. -------------------------------------
if [ ! -f "$BUILD" ]; then
    fail "scripts/build-blk.probe.sh is missing"
else
    run good "$sandbox/release/good.tar.gz" "$good_sum" ok
    if [ "$(status good)" -eq 0 ]; then
        ok "the build script succeeds on an attested release"
    else
        fail "the build script failed on an attested release: $(tail -5 "$sandbox/good/out")"
    fi
    if [ "$(staged good)" = "./blk.probe ./blk.probe/VERSION-rust-blk-probe.txt ./blk.probe/blk.probe " ]; then
        ok "it stages lib/blk.probe/blk.probe and its VERSION record, and nothing else"
    else
        fail "it staged [$(staged good)], expected lib/blk.probe/{blk.probe,VERSION-rust-blk-probe.txt}"
    fi
    if cmp -s "$sandbox/good/app/lib/blk.probe/blk.probe" "$sandbox/release/good/bin/blk.probe" \
       && [ -x "$sandbox/good/app/lib/blk.probe/blk.probe" ]; then
        ok "the staged probe is the tarball's bin/blk.probe, executable"
    else
        fail "lib/blk.probe/blk.probe is not the tarball's bin/blk.probe, or is not executable"
    fi
    if grep -qF "gh release download $pin " "$sandbox/good/log" \
       && grep -q "antimatter-studios/rust-blk-probe" "$sandbox/good/log"; then
        ok "the release downloaded is rust-blk-probe $pin"
    else
        fail "gh was not asked for rust-blk-probe's $pin release: $(tr '\n' ';' < "$sandbox/good/log")"
    fi
    record="$sandbox/good/app/lib/blk.probe/VERSION-rust-blk-probe.txt"
    if grep -qF "$pin" "$record" 2>/dev/null && grep -qF "$good_sum" "$record" 2>/dev/null; then
        ok "the VERSION record names the tag and the tarball's sha256"
    else
        fail "the VERSION record does not name $pin and $good_sum"
    fi

    # --- 2. The attestation is checked against the release workflow. -----
    verify="$(grep -F 'gh attestation verify' "$sandbox/good/log" || true)"
    if printf '%s' "$verify" | grep -qF -- "--repo antimatter-studios/rust-blk-probe" \
       && printf '%s' "$verify" | grep -qF -- "--signer-workflow antimatter-studios/rust-blk-probe/.github/workflows/release.yml" \
       && printf '%s' "$verify" | grep -qF "$asset"; then
        ok "the attestation is verified against rust-blk-probe's release workflow"
    else
        fail "gh attestation verify was not run on $asset with --repo and --signer-workflow: [$verify]"
    fi

    # --- 3. Nothing is built, and the sibling checkout is not read. -------
    if grep -q '^cargo' "$sandbox/good/log"; then
        fail "the build script ran cargo: $(grep '^cargo' "$sandbox/good/log" | tr '\n' ';')"
    else
        ok "the build script never runs cargo"
    fi
    # Code, not comments: the header says what the script used to do.
    if grep -v '^[[:space:]]*#' "$BUILD" | grep -qE 'PROBE_SRC|\.\./rust-blk-probe|cargo '; then
        fail "scripts/build-blk.probe.sh still refers to a rust-blk-probe checkout"
    else
        ok "scripts/build-blk.probe.sh names no rust-blk-probe checkout"
    fi

    # --- 4. Every refusal leaves nothing staged. --------------------------
    # A refusal counts only if it names its reason: a script that failed for
    # some other reason first would otherwise pass every one of these.
    refused() { # <label> <what> <reason the output must name>
        if [ "$(status "$1")" -ne 0 ] && [ -z "$(staged "$1" | sed 's|^\./blk\.probe $||')" ] \
           && grep -qiF -- "$3" "$sandbox/$1/out"; then
            ok "$2 stops the script, naming why, and nothing is staged"
        else
            fail "$2: status $(status "$1"), staged [$(staged "$1")], output: $(tail -3 "$sandbox/$1/out" | tr '\n' ' ')"
        fi
    }
    run badsum "$sandbox/release/good.tar.gz" "0000000000000000000000000000000000000000000000000000000000000000" ok
    refused badsum "a tarball that does not match its .sha256" "sha256"
    run unattested "$sandbox/release/good.tar.gz" "$good_sum" no
    refused unattested "a tarball whose attestation does not verify" "attestation"
    run empty "$sandbox/release/empty.tar.gz" "$(sha256 "$sandbox/release/empty.tar.gz")" ok
    refused empty "a tarball with no bin/blk.probe" "bin/blk.probe"
    grep -v '^rust-blk-probe' "$REPO/SIBLING_PINS.txt" > "$sandbox/nopin.txt"
    run nopin "$sandbox/release/good.tar.gz" "$good_sum" ok "$sandbox/nopin.txt"
    refused nopin "a SIBLING_PINS.txt with no rust-blk-probe pin" "SIBLING_PINS.txt"
fi

echo
if [ "$fails" -eq 0 ]; then
    echo 'probe-is-pinned: all checks passed'
else
    echo "probe-is-pinned: $fails check(s) failed" >&2
fi
exit "$((fails > 0))"
