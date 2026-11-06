#!/usr/bin/env bash
# chores.yml is the only entry point: no Makefile, no instruction to run make,
# and every `chore <task>` the workflows, scripts and docs name is a task.
#
# The build went through a Makefile of one-line wrappers until #577, beside a
# chores.yml that ran everything else, so there were two ways to build and
# the docs named both. A Makefile that comes back, or a sentence that still
# says `make vendor-all`, starts that again. And a renamed task leaves every
# workflow and README line that names the old one pointing at nothing, which
# chore only reports when somebody runs it.
#
# The checks run against this repository, then against a sandbox that
# plants each defect, so the guard is shown to fail as well as to pass.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fails=0
ok() { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }

# Change records describe what was true when they were written, including
# the make targets a change replaced: the changelog, its unreleased
# fragments, and the dated reports.
history='^(CHANGELOG\.md|changelog\.d/[^/]*|docs/constellation-report-[^/]*|docs/ip-audit-[^/]*)$'

# The targets the Makefile had, as commands, plus the forms make itself takes.
make_cmd='(^|[^A-Za-z0-9_-])make +(vendor-[a-z-]+|installable[a-z-]*|dev-(un)?link|install-agent|proto[a-z-]*|clean-all|pins|-C|-f)|\$\(MAKE\)|`make( [^`]*)?`'

# scan <root>: print one line per problem, nothing when there is none.
scan() {
    local root="$1" files f task
    files="$(cd "$root" && git ls-files 2>/dev/null)"
    printf '%s\n' "$files" | grep -iE '(^|/)(GNUmakefile|makefile)$|\.mk$' | sed 's/^/makefile: /'
    while IFS= read -r f; do
        [ -n "$f" ] && [ -f "$root/$f" ] || continue
        printf '%s\n' "$f" | grep -qE "$history" && continue
        [ "$f" = scripts/tests/no-makefile.sh ] && continue
        grep -nE "$make_cmd" "$root/$f" 2>/dev/null | cut -c1-120 | sed "s|^|make: $f:|"
    done < <(printf '%s\n' "$files" | grep -E '\.(md|sh|yml|yaml|py|swift|plist|modulemap)$|^Package\.swift$|^scripts/[^/.]+$')
    # Every `chore <task>` run outside chores.yml is a task in it: a command
    # line starting with chore in a workflow, a script or a markdown code
    # block, or `chore <task>` in markdown backticks. Prose and comments that
    # name another repository's task are not commands, so they are not read.
    local tasks pattern
    local cmd_line='^[[:space:]]*(- )?(run: +)?chore +[a-z][a-z0-9:_-]*'
    local quoted='`chore +[a-z][a-z0-9:_-]*'
    tasks="$(sed -nE 's/^  ([a-z][a-z0-9:_-]*):[[:space:]]*$/\1/p' "$root/chores.yml" 2>/dev/null)"
    while IFS= read -r f; do
        [ -n "$f" ] && [ -f "$root/$f" ] || continue
        printf '%s\n' "$f" | grep -qE "$history" && continue
        # AGENTS.md's backticks also quote the shared block, which names the
        # sibling crates' tasks, so only its code-block lines are commands.
        case "$f" in
            *.md) [ "$f" = AGENTS.md ] && pattern="$cmd_line" || pattern="$cmd_line|$quoted" ;;
            *) pattern="$cmd_line" ;;
        esac
        grep -noE "$pattern" "$root/$f" 2>/dev/null \
            | sed -E 's/^([0-9]+):.*chore +/\1 /' | while read -r line task; do
                case "$task" in global:*|help|test-*) continue ;; esac
                printf '%s\n' "$tasks" | grep -qxF "$task" || echo "task: $f:$line names chore $task, which chores.yml does not define"
            done
    done < <(printf '%s\n' "$files" | grep -E '^(README\.md|AGENTS\.md|\.github/workflows/[^/]+\.ya?ml|scripts/[^/]+\.sh|docs/[^/]+\.md|DiskJockeyVirtualDisk/README\.md)$')
}

problems="$(scan "$ROOT")"
if [ -z "$problems" ]; then
    ok "no Makefile, no instruction to run make, and every chore task named is defined"
else
    while IFS= read -r p; do fail "$p"; done <<<"$problems"
fi

# The same scan must catch each defect, or a pass above proves nothing.
sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT
(
    cd "$sandbox" && git init -q . &&
    printf 'tasks:\n  vendor:\n    cmds: [true]\n' > chores.yml &&
    printf 'all:\n\ttrue\n' > Makefile &&
    printf 'Build with `make vendor-all` first.\n' > README.md &&
    mkdir -p scripts && printf '#!/bin/sh\nchore vendor\nchore vendor:old\n' > scripts/build.sh &&
    printf '## [1.0]\n- make vendor-all\n' > CHANGELOG.md &&
    mkdir -p changelog.d && printf '### Changed\n- `make vendor-all` is now chore vendor\n' > changelog.d/x.md &&
    git add -A
) >/dev/null 2>&1
planted="$(scan "$sandbox")"
for want in 'makefile: Makefile' 'make: README.md:1:' 'task: scripts/build.sh:3 names chore vendor:old'; do
    if printf '%s\n' "$planted" | grep -qF "$want"; then
        ok "a planted defect is caught: $want"
    else
        fail "a planted defect is not caught: $want"
    fi
done
if printf '%s\n' "$planted" | grep -qE 'CHANGELOG|changelog\.d|names chore vendor,'; then
    fail "the scan reports history or a defined task: $(printf '%s\n' "$planted" | grep -E 'CHANGELOG|names chore vendor,' | head -1)"
else
    ok "history and defined tasks are not reported"
fi

[ "$fails" -ne 0 ] || echo 'no-makefile: all checks passed'
exit "$((fails > 0))"
