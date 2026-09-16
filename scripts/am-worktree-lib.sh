#!/usr/bin/env bash
# am-worktree-lib.sh — the ownership record, derived in ONE place.
#
# Sourced by am-worktree-own (which writes the record) and
# am-worktree-reap (which reads it before deleting). It has no side
# effects.
#
# WHY ONE PLACE. Each tool used to hash its own spelling of the path: the
# owner hashed whatever it was typed (`<wt>/`, a relative path, a symlinked
# route), the reaper hashed git's form. Any difference filed the claim
# under a key the reaper never opened, and an unowned tree is one the
# reaper may remove (#126). Normalising in only one tool moves that
# mismatch rather than removing it, so both call these functions.
#
# WHY A RECORD THAT CANNOT BE READ IS NOT "OLD". The reaper used to read
# the record twice while the owner truncated and rewrote it, and an empty
# timestamp became epoch 0 — "silent for 29 million minutes" — in the one
# branch that deletes (#127). So the record is read ONCE, and anything
# that is not a name and a number is reported as unreadable, which every
# caller treats as a reason to keep.

am_wt_state_dir() {
    printf '%s' "${AM_WORKTREE_STATE:-$HOME/.local/state/am-worktrees}"
}

# The physical absolute path of an EXISTING directory: symlinks resolved,
# no trailing slash. Fails for anything else rather than guessing.
am_wt_canonical() {
    [ -n "${1:-}" ] && [ -d "$1" ] || return 1
    (CDPATH='' cd -P -- "$1" 2>/dev/null && pwd -P)
}

# The state file name for a canonical path. A hash that did not come out
# as 32 hex characters is an error, not a key.
am_wt_key() {
    local h
    h="$(printf '%s' "$1" | shasum -a 256 | cut -c1-32)" || return 1
    case "$h" in
        *[!0-9a-f]*|'') return 1 ;;
    esac
    [ "${#h}" -eq 32 ] || return 1
    printf '%s' "$h"
}

# am_wt_read_record <file> — one open, one read. Sets AM_WT_NAME,
# AM_WT_WHEN, AM_WT_PATH. Returns 1 when the record is not a name, a
# numeric timestamp and a path.
am_wt_read_record() {
    AM_WT_NAME=""; AM_WT_WHEN=""; AM_WT_PATH=""
    local line=""
    IFS= read -r line < "$1" 2>/dev/null || [ -n "$line" ] || return 1
    IFS=$'\t' read -r AM_WT_NAME AM_WT_WHEN AM_WT_PATH <<< "$line"
    [ -n "$AM_WT_NAME" ] || return 1
    case "$AM_WT_WHEN" in
        ''|*[!0-9]*) return 1 ;;
    esac
    return 0
}

# am_wt_find_owner <canonical-path>
#   0  found: AM_WT_NAME / AM_WT_WHEN hold the freshest matching claim
#   1  no claim recorded for this path
#   2  a claim exists for this path and cannot be read — keep, do not guess
#
# The record under the canonical key is authoritative when readable. The
# scan over the other records is the MIGRATION: claims written before the
# key was canonical sit under the hash of whatever was typed, and each
# carries its path in field 3, so they are matched by resolving that path
# rather than stranded.
am_wt_find_owner() {
    local want="$1" dir key f best_name="" best_when="" unreadable=0 p rp
    dir="$(am_wt_state_dir)"
    key="$(am_wt_key "$want")" || return 2
    if [ -e "$dir/$key" ]; then
        am_wt_read_record "$dir/$key" || return 2
        best_name="$AM_WT_NAME"; best_when="$AM_WT_WHEN"
    fi
    for f in "$dir"/*; do
        [ -f "$f" ] || continue
        [ "$f" = "$dir/$key" ] && continue
        if ! am_wt_read_record "$f"; then
            # Attributable only if its path field survived.
            p="${AM_WT_PATH%"${AM_WT_PATH##*[!/]}"}"
            [ -n "$p" ] || continue
            if [ "$p" = "$want" ] || { rp="$(am_wt_canonical "$p")" && [ "$rp" = "$want" ]; }; then
                unreadable=1
            fi
            continue
        fi
        p="${AM_WT_PATH%"${AM_WT_PATH##*[!/]}"}"
        [ -n "$p" ] || continue
        if [ "$p" = "$want" ] || { rp="$(am_wt_canonical "$p")" && [ "$rp" = "$want" ]; }; then
            if [ -z "$best_when" ] || [ "$AM_WT_WHEN" -gt "$best_when" ]; then
                best_name="$AM_WT_NAME"; best_when="$AM_WT_WHEN"
            fi
        fi
    done
    [ "$unreadable" = 1 ] && return 2
    [ -n "$best_name" ] || return 1
    AM_WT_NAME="$best_name"; AM_WT_WHEN="$best_when"
    return 0
}
