#!/usr/bin/env bash
# Shared per-repository cache of GitHub answers, for the inventory commands.
# Source this file; it defines functions and runs nothing.
#
# A command that asks GitHub the same question of every constellation
# repository pays one request per repository per run, and asked again a few
# minutes later the answer has almost always not moved. So each answer is
# kept per repository and per question, and reused while it is fresh:
#
#   ${XDG_CACHE_HOME:-$HOME/.cache}/am/github/<owner>/<repo>/<key>
#
# Every worktree and every command on the machine shares one cache, and a
# repository's entry serves whichever command asks its question. The key
# names the question (`issues-open`, `issues-open-prs`, ...): two commands
# asking different questions of one repository never read each other's
# answers. XDG_CACHE_HOME counts only when it is absolute, as the XDG base
# directory specification requires.
#
# ONLY A WHOLE, SUCCESSFUL ANSWER IS KEPT. A fetch that fails (a rate limit,
# a network error, a 5xx) writes nothing, so the next ask asks again rather
# than reading the failure as "nothing there" for the rest of the TTL. An
# answer is written to a temporary file beside its entry and renamed over it,
# so a reader never sees half of one. A cache that cannot be written is no
# cache: the fetch still runs and still answers.
#
#   github_cache_path <owner/repo> <key>
#       where that entry lives
#   github_cached <owner/repo> <key> <ttl-seconds> <command> [args...]
#       the entry, when it is younger than the TTL; otherwise <command>'s
#       output, kept when <command> exits 0. <command>'s stderr and exit
#       status pass through. A TTL of 0 never reads an entry, but a
#       successful fetch still refreshes it. Exit 2, before any fetch, for a
#       repository or key that could name a path outside the cache, or a
#       TTL that is not a number of seconds.
#
# The TTL is the caller's: commands take AM_GITHUB_CACHE_TTL (600 seconds by
# default) and a --no-cache flag that passes 0.

# The cache root, or failure when there is nowhere to put one.
github_cache_root() {
    case "${XDG_CACHE_HOME:-}" in
        /*) printf '%s/am/github' "$XDG_CACHE_HOME" ;;
        *)  [ -n "${HOME:-}" ] || return 1
            printf '%s/.cache/am/github' "$HOME" ;;
    esac
}

github_cache_path() { # <owner/repo> <key>
    local root
    root="$(github_cache_root)" || return 1
    printf '%s/%s/%s' "$root" "$1" "$2"
}

# One component of a name: what GitHub allows in an owner or repository
# name, and never `.` or `..`.
github_cache_component_ok() {
    case "$1" in
        ''|.|..|*[!A-Za-z0-9._-]*) return 1 ;;
    esac
}

# Seconds since <file> was last written; failure when there is no file.
# GNU stat takes -c, BSD stat -f.
github_cache_age() {
    local mtime
    mtime="$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null)" || return 1
    case "$mtime" in ''|*[!0-9]*) return 1 ;; esac
    echo $(( $(date +%s) - mtime ))
}

github_cached() { # <owner/repo> <key> <ttl-seconds> <command> [args...]
    local slug="$1" key="$2" ttl="$3" entry age tmp rc
    shift 3
    case "$slug" in
        */*/*|*/) echo "github-cache: '$slug' is not owner/repository" >&2; return 2 ;;
        */*) ;;
        *) echo "github-cache: '$slug' is not owner/repository" >&2; return 2 ;;
    esac
    if ! github_cache_component_ok "${slug%%/*}" || ! github_cache_component_ok "${slug#*/}"; then
        echo "github-cache: '$slug' is not owner/repository" >&2
        return 2
    fi
    case "$key" in
        ''|.*|*[!A-Za-z0-9._-]*) echo "github-cache: '$key' cannot name an entry" >&2; return 2 ;;
    esac
    case "$ttl" in
        ''|*[!0-9]*) echo "github-cache: the TTL '$ttl' is not a number of seconds" >&2; return 2 ;;
    esac

    if ! entry="$(github_cache_path "$slug" "$key")"; then
        "$@"
        return $?
    fi
    # A file dated in the future (a clock that moved) is not fresh.
    if [ "$ttl" -gt 0 ] && age="$(github_cache_age "$entry")" \
        && [ "$age" -ge 0 ] && [ "$age" -lt "$ttl" ]; then
        cat "$entry"
        return 0
    fi
    if ! mkdir -p "${entry%/*}" 2>/dev/null || ! tmp="$(mktemp "$entry.XXXXXX" 2>/dev/null)"; then
        "$@"
        return $?
    fi
    "$@" > "$tmp"
    rc=$?
    if [ "$rc" -eq 0 ] && mv -f "$tmp" "$entry" 2>/dev/null; then
        cat "$entry"
        return 0
    fi
    # Not kept: a failed answer passes through as the command gave it.
    cat "$tmp"
    rm -f "$tmp"
    return "$rc"
}
