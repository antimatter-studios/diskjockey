#!/usr/bin/env bash
# Shared rate-limit stop for GitHub-backed inventory commands.
# Source this file, then call with command name, lookup name, captured stderr,
# and any nonempty fetch-stub marker. A limit exits the caller before it can
# print a table assembled from only the projects read so far.

github_stop_if_rate_limited() {
    local command_name="$1" lookup="$2" errors="$3" stubbed="$4"
    local reset when
    cat "$errors" >&2
    grep -qiE 'rate[ _]limit' "$errors" || return 0
    {
        echo
        echo "$command_name: GitHub is rate limiting this token; stopped at $lookup rather than"
        echo "$command_name: repeating a request that can only fail. Nothing was printed, because"
        echo "$command_name: a table built from the projects read so far would look complete."
        # The rate_limit endpoint is not itself counted against the limit.
        # A test stub has no token to ask about.
        if [ -z "$stubbed" ]; then
            reset="$(gh api rate_limit --jq '[.resources.core, .resources.graphql]
                | map(select(.remaining == 0) | .reset) | max // empty' 2>/dev/null)"
            if [ -n "$reset" ]; then
                when="$(date -u -r "$reset" +%H:%M:%SZ 2>/dev/null || date -u -d "@$reset" +%H:%M:%SZ 2>/dev/null)"
                echo "$command_name: the limit resets at $when."
            else
                echo "$command_name: no primary limit is exhausted, so this is a secondary limit; wait a few minutes."
            fi
        fi
    } >&2
    exit 5
}
