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
#   kill, killall — SIGKILL the main DiskJockey.app AND every bundled
#                  extension host (DiskJockeyEXT4, DiskJockeyNTFS,
#                  DiskJockeyFileProvider). `killall` is an alias.
#   start        — `open` the built app bundle (no rebuild).
#   restart      — kill + start (no rebuild).
#   rebuild      — kill + build + start.
#   logs-reset   — Truncate the group-container ndjson log files to zero
#                  bytes. Useful when the historical log has grown large
#                  enough to slow things down during diagnostics.
#   reset-daemons — Kill pkd (per-user), fskit_agent (per-user), fskitd
#                  (system, needs sudo — will prompt once), and the
#                  per-user lsd (LaunchServices daemon). launchd respawns
#                  each automatically. Use when macOS is stuck on a stale
#                  extension identity after a rebuild — symptoms are
#                  `_EXExtensionIdentity: Code=5` in the system log or
#                  `diskutil mount` failing without reaching our extension's
#                  probe. Avoids the logout/reboot escape hatch.
#   doctor       — Chained recovery when the FSKit extension won't mount
#                  after a rebuild. Runs clean-stale-bundles →
#                  pluginkit-reload → reset-daemons, then prints the final
#                  step you MUST do by hand (physically eject + reinsert
#                  the disk) and the critical testing rule (`mount -t ext4`
#                  from CLI will stay broken even after doctor succeeds
#                  because LaunchServices caches the fstype → bundle
#                  lookup at a layer none of these resets flushes; the
#                  DiskArbitration-on-reinsert path is a separate route
#                  that does work). Use this in preference to manual
#                  recovery dances.
#   pluginkit-reload — Full deregister / reregister / user-enable / LaunchServices
#                  refresh cycle for the bundled FSKit extensions. Run this
#                  when a `rebuild` produces an extension binary that macOS
#                  refuses to instantiate (`com.apple.extensionKit.errorDomain
#                  error 2` at mount time, probes stop firing), which happens
#                  sporadically when the code signature changes underneath an
#                  already-registered bundle. Covered dance:
#                    pluginkit -r <appex>        (deregister stale entry)
#                    pluginkit -a <appex>        (re-register fresh binary)
#                    pluginkit -e use -i <id>    (enable at pluginkit level)
#                    lsregister -u / -f on app   (refresh LaunchServices)
#                  Note: does NOT flip the per-user FSKit user-approval flag
#                  (System Settings → File System Extensions); do that by hand
#                  if mount still returns "Permission denied" after.
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
# Bundled FSKit extensions that need the pluginkit dance after rebuilds
# that change their code signature. Pair of appex-relative-path and the
# bundle id used for pluginkit -e commands. Add an entry per new
# FSKit extension we ship (no entry needed for FileProvider — it's in
# Contents/PlugIns and follows a different registration path).
readonly FSKIT_EXTENSIONS=(
    "Contents/Extensions/DiskJockeyEXT4.appex|com.antimatterstudios.diskjockey.ext4"
    "Contents/Extensions/DiskJockeyNTFS.appex|com.antimatterstudios.diskjockey.ntfs"
)
readonly LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"

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
    # Capture xcodebuild output to a tmp log so we can read its real
    # exit code directly. Earlier the pipe to grep|sed swallowed the
    # exit code, and the fallback `[[ -d $APP_BUNDLE ]]` check was
    # unreliable: a stale bundle from a prior successful build sticks
    # around even when the current build fails (e.g. an extension
    # target breaking doesn't delete the main .app), so the script
    # silently reported green on real failures.
    local log
    log=$(mktemp -t dev-build) || { red "mktemp failed"; return 1; }
    local rc=0
    xcodebuild \
        -project "$XCODEPROJ" \
        -scheme "$SCHEME" \
        -configuration "$CONFIGURATION" \
        -derivedDataPath "$DERIVED_DATA" \
        ONLY_ACTIVE_ARCH=YES ARCHS="$ARCHS" \
        build \
        >"$log" 2>&1 || rc=$?
    grep -E "error:|warning:|BUILD (SUCCEEDED|FAILED)|\*\* " "$log" \
      | sed 's/^/  /' || true
    rm -f "$log"
    if (( rc != 0 )); then
        red "Build failed (xcodebuild exit=$rc)"
        return $rc
    fi
    if [[ ! -d "$APP_BUNDLE" ]]; then
        red "Build reported success but no bundle at $APP_BUNDLE"
        return 1
    fi
    green "Built: $APP_BUNDLE"
}

cmd_kill() {
    # Main app + every bundled extension's host process. FSKit and
    # FileProvider extensions run out-of-process under their own PIDs
    # named after the appex's executable; a lingering extension host
    # can hold cached state that survives a main-app restart and make
    # the next launch behave oddly. `pkill -f` matches the full
    # command line so we catch them even when a parent daemon launched
    # them rather than `open`.
    local targets=(
        DiskJockey
        DiskJockeyEXT4
        DiskJockeyNTFS
        DiskJockeyFileProvider
    )
    local killed=0
    for name in "${targets[@]}"; do
        if pgrep -x "$name" >/dev/null 2>&1; then
            yellow "Killing ${name}…"
            pkill -9 -x "$name" || true
            killed=1
        fi
    done
    if [[ $killed -eq 0 ]]; then
        green "No running DiskJockey processes."
    else
        # Give fskitd / fileproviderd a beat to reap the child before
        # a follow-up start/pluginkit-reload tries to talk to a fresh
        # extension host.
        sleep 1
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

cmd_reset_daemons() {
    # Three daemons cache extension identity + approval state and
    # occasionally get stuck after a rebuild, producing
    # `_EXExtensionIdentity: Code=5` or `ExtensionKit error 2` errors.
    # Killing them is safe — launchd respawns each one automatically
    # with fresh state. pkd and fskit_agent are per-user (no sudo);
    # fskitd is system-wide so we need sudo (will prompt once).
    #
    # Avoids logout/reboot as long as the approval state hasn't been
    # persisted to an on-disk store that survives these restarts.
    yellow "Killing per-user pkd + fskit_agent + lsd…"
    pkill -9 -x pkd 2>/dev/null || true
    pkill -9 -x fskit_agent 2>/dev/null || true
    # Per-user `lsd` owns the LaunchServices cache that `mount -t ext4`
    # uses to find our bundle; without bouncing it the cache can stay
    # stale even after pluginkit re-register. System-wide lsd (root)
    # would need sudo — we only kill the per-user one here since that
    # is enough for the mount-to-extension routing.
    pkill -9 -u "$USER" -x lsd 2>/dev/null || true
    sleep 1
    if pgrep -x fskitd >/dev/null 2>&1; then
        yellow "Killing system fskitd (sudo prompt)…"
        sudo pkill -9 -x fskitd || red "fskitd kill failed (sudo denied?)"
        sleep 2
    fi
    # Verify the respawn landed (launchd is normally <1s).
    for svc in pkd fskit_agent fskitd; do
        if pgrep -x "$svc" >/dev/null 2>&1; then
            green "$svc respawned."
        else
            yellow "$svc not running yet — launchd may still be respawning."
        fi
    done
}

cmd_pluginkit_reload() {
    if [[ ! -d "$APP_BUNDLE" ]]; then
        red "No built app at $APP_BUNDLE — run 'scripts/dev.sh build' first."
        return 1
    fi

    # Order matters. An earlier revision of this function did the
    # pluginkit -r/-a first, then LaunchServices -u/-f, which undid
    # the pluginkit registrations (lsregister -u nukes every entry
    # for the bundle, including what -a just added). Correct order:
    #
    #   1. For each bundle id, discover every currently-registered
    #      Path (including stale ones from /tmp/dj-build/ or the
    #      project-local build/ dir) and deregister them. The -r
    #      matches by path, not by bundle id, so we have to enumerate
    #      first; otherwise stale entries linger and macOS loads the
    #      wrong binary instead of our fresh one.
    #   2. lsregister -u + -f on the parent bundle — tells
    #      LaunchServices "this is the one true DiskJockey.app, for
    #      every embedded extension too."
    #   3. pluginkit -a + -e use on each extension's fresh DerivedData
    #      path to make sure pluginkit + per-user enablement are set
    #      after the LaunchServices shuffle.

    yellow "Deregistering any stale path-based pluginkit entries…"
    for entry in "${FSKIT_EXTENSIONS[@]}"; do
        local bid="${entry##*|}"
        # Each Path line in the verbose output is the path a currently-
        # registered entry points at; sometimes multiple rows per bid
        # if older builds left different paths.
        while IFS= read -r stale_path; do
            [[ -z "$stale_path" ]] && continue
            printf '  %-64s  (was: %s)\n' "$bid" "$stale_path"
            pluginkit -r "$stale_path" >/dev/null 2>&1 || true
        done < <(
            pluginkit -mAvvv -i "$bid" 2>/dev/null \
                | awk -F'= ' '/^[[:space:]]*Path = / { print $2 }'
        )
    done

    yellow "Refreshing LaunchServices for $APP_BUNDLE"
    "$LSREGISTER" -u "$APP_BUNDLE" >/dev/null 2>&1 || true
    "$LSREGISTER" -f "$APP_BUNDLE" >/dev/null 2>&1 || true

    yellow "Registering fresh extension bundles + user-enabling them…"
    for entry in "${FSKIT_EXTENSIONS[@]}"; do
        local rel="${entry%%|*}"
        local bid="${entry##*|}"
        local appex="$APP_BUNDLE/$rel"
        if [[ ! -d "$appex" ]]; then
            yellow "  Skipping $bid — no bundle at $appex"
            continue
        fi
        pluginkit -a "$appex" 2>&1 | sed 's/^/  /' || true
        pluginkit -e use -i "$bid" 2>&1 | sed 's/^/  /' || true
    done

    green "pluginkit reload complete. Current state:"
    for entry in "${FSKIT_EXTENSIONS[@]}"; do
        local bid="${entry##*|}"
        pluginkit -mAvvv -i "$bid" 2>&1 \
            | grep -E "^\+|^[[:space:]]+Path |^[[:space:]]+UUID |^[[:space:]]+Timestamp " \
            | sed 's/^/  /' \
            || true
    done

    green ""
    green "If mount still returns 'Permission denied' or error 2 after this,"
    green "you likely need to:"
    green "  a) toggle the extension in System Settings → Login Items &"
    green "     Extensions → File System Extensions, OR"
    green "  b) log out and back in (cycles per-user fskit_agent / pkd), OR"
    green "  c) reboot (nukes the kernel extension trust cache)."
}

cmd_clean_stale_bundles() {
    # Sometimes an earlier `xcodebuild` run without -derivedDataPath
    # lands a stale DiskJockey.app at /private/tmp/dj-build/ or at
    # ./build/. pluginkit happily registers whichever copy it finds
    # first, and `mount -t ext4` then routes to a path that's either
    # missing or has drifted from the current source. Nuke both
    # candidates up-front so pluginkit-reload has a single real
    # bundle to register.
    local removed=0
    for p in /private/tmp/dj-build "$PROJECT_ROOT/build"; do
        if [[ -d "$p" ]]; then
            yellow "Removing stale bundle dir: $p"
            # Best-effort pluginkit cleanup for anything registered at
            # this path before the dir goes away.
            for entry in "${FSKIT_EXTENSIONS[@]}"; do
                local rel="${entry%%|*}"
                pluginkit -r "$p/Debug/DiskJockey.app/$rel" >/dev/null 2>&1 || true
            done
            "$LSREGISTER" -u "$p/Debug/DiskJockey.app" >/dev/null 2>&1 || true
            rm -rf "$p"
            removed=1
        fi
    done
    if [[ $removed -eq 0 ]]; then
        green "No stale build bundles to clean."
    fi
}

cmd_doctor() {
    # The full recovery drill, encoding everything the team worked out
    # the hard way on 2026-04-21:
    #   1. Rebuilds leave stale app bundles at non-DerivedData paths;
    #      pluginkit picks the wrong one and mount fails with
    #      `com.apple.extensionKit.errorDomain error 2` (the bundle
    #      macOS thinks is authoritative no longer exists or doesn't
    #      match the registration metadata).
    #   2. pluginkit + lsregister can re-register cleanly, but that
    #      doesn't unstick an already-broken in-memory identity in
    #      pkd; you get `_EXExtensionIdentity: Code=5` crashes at
    #      extension-spawn time. Bouncing pkd + fskit_agent + fskitd
    #      + lsd clears that.
    #   3. Even after all that, `mount -t ext4 /dev/diskNsN` will STILL
    #      return `Permission denied` because the fstype→bundle lookup
    #      sits in a LaunchServices layer none of the above reset. The
    #      DiskArbitration-on-physical-insert path is separate and
    #      does work, so the user has to eject + reinsert the disk to
    #      verify — `mount -t ext4` lying at the CLI is not
    #      informative about whether the real flow is fixed.
    yellow "doctor: running full FSKit recovery drill…"
    echo
    cmd_clean_stale_bundles
    echo
    cmd_pluginkit_reload
    echo
    cmd_reset_daemons
    echo
    green "=================================================================="
    green "doctor: automated recovery done. FINAL STEP IS MANUAL:"
    green ""
    green "  Eject and physically reinsert the disk (USB / SD card / etc.)."
    green "  DiskArbitration will re-probe through the freshly-respawned"
    green "  fskitd and the extension will mount normally."
    green ""
    yellow "  Do NOT test with 'mount -t ext4 /dev/diskNsN /mnt'. That"
    yellow "  command goes through a LaunchServices cache that survives"
    yellow "  every daemon restart done here and will keep returning"
    yellow "  'Permission denied' long after the real flow works. Use"
    yellow "  the plug-in-disk flow, or 'diskutil eject diskN && reinsert'."
    green "=================================================================="
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
        kill|killall|stop)
                     cmd_kill "$@" ;;
        start)       cmd_start "$@" ;;
        restart)     cmd_restart "$@" ;;
        rebuild)     cmd_rebuild "$@" ;;
        clean)       cmd_clean "$@" ;;
        logs-reset|logs|reset-logs)
                     cmd_logs_reset "$@" ;;
        pluginkit-reload|reload|plugins)
                     cmd_pluginkit_reload "$@" ;;
        reset-daemons|kick-daemons|daemons)
                     cmd_reset_daemons "$@" ;;
        doctor|fix|recover)
                     cmd_doctor "$@" ;;
        clean-stale-bundles|clean-stale)
                     cmd_clean_stale_bundles "$@" ;;
        status)      cmd_status "$@" ;;
        -h|--help|help) usage 0 ;;
        *)
            red "Unknown subcommand: $sub"
            usage 1
            ;;
    esac
}

main "$@"
