#!/usr/bin/env bash
#
# build-installable.sh — produce a release-configured DiskJockey.app
# that can be installed to /Applications and run like a normal app
# (not out of Xcode DerivedData).
#
# Signed with the team's Apple Development certificate via Xcode's
# automatic signing. Runs on Macs registered to your Apple Developer
# account; Gatekeeper accepts it without notarization.
#
# For external distribution or notarized installs, switch to a
# Developer ID workflow — different cert, different ExportOptions,
# plus a `xcrun notarytool submit` step.
#
# Usage:
#   ./scripts/build-installable.sh           # build only, leave .app in build/export/
#   ./scripts/build-installable.sh --install # build, then copy to /Applications
#   ./scripts/build-installable.sh -h        # help
#
# Exit codes:
#   0  success
#   1  general failure (xcodebuild, ditto, etc.)
#   2  precondition failure (wrong CWD, missing tools)
#

set -euo pipefail

# Resolve project root from this script's location, so the script
# works regardless of CWD.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

BUILD_DIR="$PROJECT_ROOT/build"
ARCHIVE_PATH="$BUILD_DIR/DiskJockey.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
EXPORT_PLIST="$SCRIPT_DIR/ExportOptions-development.plist"
INSTALL_DEST="/Applications/DiskJockey.app"

DO_INSTALL=false

usage() {
    cat <<'EOF'
Usage: scripts/build-installable.sh [--install] [-h|--help]

Builds a Release-configured DiskJockey.app signed with the team's
Apple Development certificate, ready for /Applications.

Without --install, leaves the artifact at build/export/DiskJockey.app.
With --install, copies it to /Applications (replacing any existing
copy) after prompting.

Requires:
  * Xcode + matching Apple Development cert in team 43UMKXZ8P4
  * Vendor libraries built (`make vendor-all` runs automatically if
    `lib/` is missing or stale)
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --install)
            DO_INSTALL=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

# --- precondition checks ------------------------------------------------

if [ ! -f "$PROJECT_ROOT/DiskJockey.xcodeproj/project.pbxproj" ]; then
    echo "ERROR: DiskJockey.xcodeproj not found in $PROJECT_ROOT" >&2
    exit 2
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
    echo "ERROR: xcodebuild not in PATH (Xcode command-line tools missing?)" >&2
    exit 2
fi

# Make sure the team's Apple Development cert is available. We don't
# fail hard on absence — xcodebuild's automatic signing might still
# resolve it via the account credentials — but warn loudly so a
# missing cert doesn't look like a cryptic build error later.
if ! security find-identity -v -p codesigning 2>/dev/null \
    | grep -q '"Apple Development:'; then
    echo "WARNING: no 'Apple Development' code-signing identity found in keychain." >&2
    echo "         Open Xcode > Settings > Accounts and make sure the team is added." >&2
fi

# --- vendor libraries ---------------------------------------------------
#
# The build links against three vendor static libs (lib/fs_ext4,
# lib/fs_ntfs, lib/go-networkfs) plus the four img-* containers
# (lib/img_qcow2, lib/img_vhd, lib/img_vhdx, lib/img_vmdk). Run the
# umbrella `vendor-all` target — its stamp files mean a no-op fast
# path when they're already current.

echo "==> building vendor libraries (lib/)"
make vendor-all

# --- archive ------------------------------------------------------------

echo "==> archiving (Release, ARCHS=arm64)"
rm -rf "$ARCHIVE_PATH"
mkdir -p "$BUILD_DIR"

xcodebuild archive \
    -project DiskJockey.xcodeproj \
    -scheme DiskJockey \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE_PATH" \
    -skipPackagePluginValidation \
    -allowProvisioningUpdates \
    ONLY_ACTIVE_ARCH=YES \
    ARCHS=arm64          # Apple Silicon only — intentional; not a universal build

# --- export -------------------------------------------------------------

echo "==> exporting .app from archive"
rm -rf "$EXPORT_DIR"

xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_PLIST" \
    -allowProvisioningUpdates

if [ ! -d "$EXPORT_DIR/DiskJockey.app" ]; then
    echo "ERROR: exported .app not found at $EXPORT_DIR/DiskJockey.app" >&2
    exit 1
fi

# Verify the exported bundle here so a signing/export problem surfaces on
# EVERY build path, not only when --install is passed (e.g. a developer who
# `ditto`s the built .app manually still gets a checked signature).
echo "==> verifying signature"
codesign --verify --verbose=1 "$EXPORT_DIR/DiskJockey.app"

echo "==> built: $EXPORT_DIR/DiskJockey.app"

# --- install (optional) -------------------------------------------------

if [ "$DO_INSTALL" = true ]; then
    if [ -d "$INSTALL_DEST" ]; then
        # Replacing /Applications/DiskJockey.app — confirm so a stray
        # `--install` flag can't silently overwrite an installed copy
        # that might be from a different signing identity / Xcode
        # version / hand-modified bundle.
        printf "==> %s already exists. Replace it? [y/N] " "$INSTALL_DEST"
        read -r answer
        case "$answer" in
            y|Y|yes|YES) ;;
            *)
                echo "Aborted; leaving existing install in place."
                echo "Built copy is at: $EXPORT_DIR/DiskJockey.app"
                exit 0
                ;;
        esac
    fi

    # Install atomically: stage into a temp path beside the destination,
    # prove it copied and verifies cleanly, and only THEN swap it in. This
    # way a `ditto` failure (disk full, I/O error) can never leave the user
    # with their previous install deleted and no replacement.
    staging="${INSTALL_DEST}.installing.$$"
    rm -rf "$staging"
    # `ditto` preserves code signatures and extended attributes that
    # `cp -R` strips; required for the signed bundle to keep working.
    echo "==> installing to $INSTALL_DEST"
    ditto "$EXPORT_DIR/DiskJockey.app" "$staging"

    # Strip the quarantine attribute LaunchServices applies to anything
    # arriving through "untrusted" channels. Without this, Gatekeeper
    # prompts the user on first launch even though the bundle is
    # validly signed — annoying for a local-build install path.
    xattr -dr com.apple.quarantine "$staging" 2>/dev/null || true

    # Verify the staged copy before the swap so a copy mishap or stripped
    # signature surfaces here, not at first launch.
    echo "==> verifying staged copy"
    codesign --verify --verbose=1 "$staging"

    # Atomic-ish swap: the old install only disappears once the new copy
    # is proven good.
    rm -rf "$INSTALL_DEST"
    mv "$staging" "$INSTALL_DEST"

    echo ""
    echo "Installed: $INSTALL_DEST"
    echo "Open with: open '$INSTALL_DEST'"
else
    echo ""
    echo "Built: $EXPORT_DIR/DiskJockey.app"
    echo "Install to /Applications by re-running with --install,"
    echo "or copy manually:  ditto '$EXPORT_DIR/DiskJockey.app' /Applications/DiskJockey.app"
fi
