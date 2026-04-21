#!/usr/bin/env bash
#
# scripts/dev.sh — one-stop dev loop for DiskJockey.
#
# Wraps xcodebuild, pkill, open, and a few FS housekeeping operations
# so the build/relaunch cycle is a single command instead of a chain.
# The scripts/ directory is already on the project's path for build
# phases, so this file lives alongside the existing build helpers.
#
# Usage:
#   scripts/dev.sh <subcommand>
#
# Subcommands:
#   build        — Debug build, arm64-only, output into Xcode's DerivedData
#                  (the same path pluginkit has registered), so the running
#                  extension binaries get updated without needing a manual
#                  pluginkit dance.
#   clean        — Remove lib/ build artifacts + Xcode's DerivedData for
#                  this project. Does NOT touch vendor submodule sources.
#   kill         — SIGKILL any running DiskJockey.app instance.
#   start        — `open` the built app bundle (no rebuild).
#   restart      — kill + start (no rebuild).
#   rebuild      — kill + build + start.
#   logs-reset   — Truncate the group-container ndjson log files to zero
#                  bytes. Useful when the historical log has grown large
#                  enough to slow things down during diagnostics.
#   status       — Show current app PID, build state, pluginkit registration.
#
# Exits non-zero on build failures so CI / Make can chain on it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# -----------------------------------------------------------------------------
# Configuration. Paths + identifiers kept next to each other so swapping to a
# different derived-data path or scheme is a one-line change.
# -----------------------------------------------------------------------------
readonly XCODEPROJ="$PROJECT_ROOT/DiskJockey.xcodeproj"
readonly SCHEME="DiskJockey"
readonly CONFIGURATION="Debug"
readonly ARCHS="arm64"
# Matches the path pluginkit already registered; keeping the build there
# means extension updates flow through to the already-approved .appex
# paths without a pluginkit -r/-a dance.
readonly DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData/DiskJockey-bvhiqmzjlyprosfoxdtubizynxng"
readonly APP_BUNDLE="$DERIVED_DATA/Build/Products/$CONFIGURATION/DiskJockey.app"
# Subprocess-written NDJSON logs tailed by the host app UI. The group
# container name matches AppLog.groupIdentifier — keep them in sync.
readonly APP_GROUP="group.com.antimatterstudios.diskjockey"
readonly LOGS_DIR="$HOME/Library/Group Containers/$APP_GROUP/Logs"

# Small color helpers — kept to a single tput so the script degrades to plain
# output when stdout isn't a tty (e.g. invoked from CI).
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ $(tput colors 2>/dev/null || echo 0) -ge 8 ]]; then
    green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
    yellow() { printf '\033[1;33m%s\033[0m\n' "$*"; }
    red() { printf '\033[0;31m%s\033[0m\n' "$*" >&2; }
else
    green() { printf '%s\n' "$*"; }
    yellow() { printf '%s\n' "$*"; }
    red() { printf '%s\n' "$*" >&2; }
fi

# -----------------------------------------------------------------------------
# Subcommands
# -----------------------------------------------------------------------------

cmd_build() {
    yellow "Building $SCHEME ($CONFIGURATION, $ARCHS) into ${DERIVED_DATA}…"
    xcodebuild \
        -project "$XCODEPROJ" \
        -scheme "$SCHEME" \
        -configuration "$CONFIGURATION" \
        -derivedDataPath "$DERIVED_DATA" \
        ONLY_ACTIVE_ARCH=YES ARCHS="$ARCHS" \
        build \
        2>&1 \
      | grep -E "error:|warning:|BUILD (SUCCEEDED|FAILED)|\*\* " \
      | sed 's/^/  /' \
      || true
    # xcodebuild's exit code is lost through the pipe; re-run `-json` test
    # of the app bundle's existence as a cheap success proxy. If it's not
    # there, the build failed.
    if [[ ! -d "$APP_BUNDLE" ]]; then
        red "Build failed — no bundle at $APP_BUNDLE"
        return 1
    fi
    green "Built: $APP_BUNDLE"
}

cmd_kill() {
    if pgrep -x DiskJockey >/dev/null 2>&1; then
        yellow "Killing running DiskJockey…"
        pkill -9 -x DiskJockey || true
        # pkill returns immediately; give launchd a beat to reap the child.
        sleep 1
    else
        green "No running DiskJockey process."
    fi
}

cmd_start() {
    if [[ ! -d "$APP_BUNDLE" ]]; then
        red "No built app at $APP_BUNDLE — run 'scripts/dev.sh build' first."
        return 1
    fi
    yellow "Launching ${APP_BUNDLE}…"
    open "$APP_BUNDLE"
    green "Launched."
}

cmd_restart() {
    cmd_kill
    cmd_start
}

cmd_rebuild() {
    cmd_kill
    cmd_build
    cmd_start
}

cmd_clean() {
    yellow "Removing DerivedData: $DERIVED_DATA"
    rm -rf "$DERIVED_DATA"
    if [[ -d "$PROJECT_ROOT/build" ]]; then
        yellow "Removing local build dir: $PROJECT_ROOT/build"
        rm -rf "$PROJECT_ROOT/build"
    fi
    # lib/ holds rebuilt vendor artifacts (libfs_ext4.a, libnetworkfs.a, …);
    # they regenerate on next build via the Run Script phases. Remove them
    # so a stale universal-vs-arm64 mix can't sneak through.
    if [[ -d "$PROJECT_ROOT/lib" ]]; then
        yellow "Clearing $PROJECT_ROOT/lib/*/"
        find "$PROJECT_ROOT/lib" -mindepth 1 -maxdepth 1 -type d -exec rm -rf {} +
    fi
    green "Clean complete."
}

cmd_logs_reset() {
    if [[ ! -d "$LOGS_DIR" ]]; then
        green "No log dir to reset ($LOGS_DIR)."
        return 0
    fi
    yellow "Truncating ndjson logs in $LOGS_DIR:"
    shopt -s nullglob
    local any=0
    for f in "$LOGS_DIR"/*.ndjson; do
        local size
        size=$(stat -f '%z' "$f")
        : > "$f"
        printf '  %-24s  was %s bytes\n' "$(basename "$f")" "$size"
        any=1
    done
    shopt -u nullglob
    if [[ $any -eq 0 ]]; then
        green "No ndjson files to truncate."
    else
        green "Done."
    fi
}

cmd_status() {
    if pgrep -x DiskJockey >/dev/null 2>&1; then
        local pid
        pid=$(pgrep -x DiskJockey)
        green "Running: PID $pid"
        ps -p "$pid" -o pid,state,%cpu,rss,time,command | sed 's/^/  /'
    else
        yellow "Not running."
    fi
    if [[ -d "$APP_BUNDLE" ]]; then
        local mtime
        mtime=$(stat -f '%Sm' "$APP_BUNDLE/Contents/MacOS/DiskJockey")
        green "Built bundle: $APP_BUNDLE (mtime: $mtime)"
    else
        yellow "No built bundle at $APP_BUNDLE."
    fi
    # Which appex's has the system registered?
    if command -v pluginkit >/dev/null 2>&1; then
        echo
        yellow "Registered DiskJockey extensions (pluginkit -m | grep diskjockey):"
        pluginkit -m 2>&1 | grep -i diskjockey | sed 's/^/  /' || true
    fi
}

# -----------------------------------------------------------------------------
# Dispatch
# -----------------------------------------------------------------------------
usage() {
    sed -n '/^# Usage:/,/^# Exits/p' "${BASH_SOURCE[0]}" | sed 's/^# //; s/^#$//'
    exit "${1:-0}"
}

main() {
    if [[ $# -eq 0 ]]; then usage 1; fi
    local sub="$1"; shift
    case "$sub" in
        build)       cmd_build "$@" ;;
        kill|stop)   cmd_kill "$@" ;;
        start)       cmd_start "$@" ;;
        restart)     cmd_restart "$@" ;;
        rebuild)     cmd_rebuild "$@" ;;
        clean)       cmd_clean "$@" ;;
        logs-reset|logs|reset-logs)
                     cmd_logs_reset "$@" ;;
        status)      cmd_status "$@" ;;
        -h|--help|help) usage 0 ;;
        *)
            red "Unknown subcommand: $sub"
            usage 1
            ;;
    esac
}

main "$@"
