#!/usr/bin/env bash
# Install only the pinned, attested filesystem CLIs for capability checks.
# No driver is executed here; even version/help output must wait for trust.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
usage() { echo 'usage: install-cli-capabilities.sh --dest NEW_DIR [--pins FILE]' >&2; exit 2; }
die() { echo "cli-capability-install: $*" >&2; exit 1; }
dest='' pins="$ROOT/SIBLING_PINS.txt"
while [ "$#" -gt 0 ]; do
    case "$1" in
        --dest) [ "$#" -ge 2 ] || usage; dest="$2"; shift 2 ;;
        --pins) [ "$#" -ge 2 ] || usage; pins="$2"; shift 2 ;;
        *) usage ;;
    esac
done
[ -n "$dest" ] || usage
[ -f "$pins" ] || die 'missing SIBLING_PINS file; supply the capability release pins (#488)'
[ ! -e "$dest" ] && [ ! -L "$dest" ] || die "destination already exists: $dest; use a new directory"
case "$(uname -s)/$(uname -m)" in
    Darwin/arm64) platform=darwin-arm64 ;;
    Linux/x86_64) platform=linux-x86_64 ;;
    *) die 'no release platform; use darwin-arm64 or linux-x86_64' ;;
esac
command -v gh >/dev/null 2>&1 || die 'missing gh; install GitHub CLI with attestation verification support'
command -v tar >/dev/null 2>&1 || die 'missing tar; install tar to unpack verified releases'
sha256() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
    else shasum -a 256 "$1" | cut -d' ' -f1; fi
}
drivers=(ext4 ntfs xfs btrfs bcachefs erofs squashfs)
tags=()
# Validate every pin before making any network request. A duplicate pin is
# ambiguous, even when its two values happen to agree.
for driver in "${drivers[@]}"; do
    tag="$(awk -v repo="rust-fs-$driver" '$1==repo{if(NF!=2) print "invalid"; else print $2}' "$pins")"
    [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
        || die "SIBLING_PINS must name one exact rust-fs-$driver tag; add its published CLI release (#488)"
    tags+=("$tag")
done
parent="$(dirname "$dest")"
mkdir -p "$parent"
parent="$(cd "$parent" && pwd)"
dest="$parent/$(basename "$dest")"
work="$(mktemp -d "$parent/.cli-releases.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/downloads" "$work/packages"
printf 'repository\ttag\tasset\tsha256\tsigner\tsource_ref\n' > "$work/releases.tsv"
signer=antimatter-studios/rust-fs-core/.github/workflows/release-cli.yml
for index in "${!drivers[@]}"; do
    driver="${drivers[$index]}" tag="${tags[$index]}"
    repo="antimatter-studios/rust-fs-$driver"
    asset="rust-fs-$driver-${tag#v}-$platform.tar.gz"
    archive="$work/downloads/$asset"
    gh release download "$tag" --repo "$repo" --pattern "$asset" --dir "$work/downloads" \
        || die "missing release asset $repo $tag $asset; publish the pinned CLI release (#488)"
    [ -f "$archive" ] || die "missing release asset $asset; publish the pinned CLI release (#488)"
    # gh checks the archive digest against signed provenance. Checking the
    # source ref also rejects an attested artifact from a different release.
    gh attestation verify "$archive" --repo "$repo" \
        --signer-workflow "$signer" --source-ref "refs/tags/$tag" >/dev/null \
        || die "attestation failed for $repo $tag $asset; publish provenance for this exact tag (#488)"
    digest="$(sha256 "$archive")"
    pkg="$work/packages/$driver"
    mkdir -p "$pkg"
    tar -xzf "$archive" -C "$pkg" || die "release asset $asset cannot be unpacked"
    [ -f "$pkg/bin/fs.$driver" ] && [ -x "$pkg/bin/fs.$driver" ] \
        || die "release asset $asset lacks executable bin/fs.$driver; publish the CLI archive (#488)"
    # Preserve the release's relative multicall symlinks. Expose only fs.*,
    # so bundled mkfs tools cannot shadow the independent fixture builders.
    ln -s "../packages/$driver/bin/fs.$driver" "$work/bin/fs.$driver"
    printf '%s\t%s\t%s\t%s\t%s\trefs/tags/%s\n' \
        "$repo" "$tag" "$asset" "$digest" "$signer" "$tag" >> "$work/releases.tsv"
    echo "verified $repo $tag: $asset sha256 $digest"
done
# Publish the directory only after every release passed. A failed install
# leaves no destination and cannot reuse a previously installed binary.
mv "$work" "$dest"
echo "installed seven verified filesystem CLIs in $dest/bin; provenance: $dest/releases.tsv"
