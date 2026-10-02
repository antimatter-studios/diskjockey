#!/usr/bin/env bash
#
# every-agent-method-has-a-caller.sh — no XPC method on the agent outlives its
# last caller (diskjockey#286).
#
# The agent is the one unsandboxed process in the app, so every method on
# DJAgentProtocol is something any process that reaches its Mach service can
# ask an unsandboxed helper to do. A method nothing in the app calls is that
# surface with no use: nobody exercises it, so nobody notices when it stops
# working. `mountFSKit` was that method. It ran `mount -F` as root through an
# administrator prompt, had had no caller since mounting moved to hdiutil and
# DiskArbitration, and could only fail if anything did call it, because
# `mount -F` cannot mount an image file through a module that declares
# FSSupportsBlockResources (#165).
#
# So for every method the app's copy of DJAgentProtocol.swift declares (the
# two copies are held identical by the-agent-is-a-target.sh):
#
#   1. DJAgentClient.swift forwards it to the agent, as `proxy.<name>(`;
#   2. something in the app outside DJAgentClient.swift calls that wrapper,
#      as `DJAgentClient.shared.<name>(`. The spelling is strict on purpose: a
#      caller that reaches the client some other way fails here and names the
#      method, which is a cheaper mistake than a looser match that also
#      accepts an unrelated method of the same name.
#
# A control then adds a method with no caller to a copy of the protocol and
# requires the same check to fail on it, because a gate that cannot fail is
# indistinguishable from no gate.
#
# TEXT ONLY. Runs in the ubuntu `Shell scripts` job.
#
#   bash scripts/tests/every-agent-method-has-a-caller.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP="$REPO/DiskJockeyApplication"
PROTOCOL="$APP/Services/DJAgentProtocol.swift"
CLIENT="$APP/Services/DJAgentClient.swift"
fails=0
ok()   { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1" >&2; fails=$((fails + 1)); }

# check <protocol file>: one line per method, `ok <name>` or `orphan <name>
# <why>`, for every `func` the protocol declares. Prints nothing if it
# declares none, which the caller treats as a failure.
check() {
    local proto="$1" name callers
    grep -oE '^[[:space:]]*func [A-Za-z_][A-Za-z0-9_]*\(' "$proto" |
        sed -E 's/^[[:space:]]*func //; s/\($//' |
    while read -r name; do
        if ! grep -qE "proxy\.${name}\(" "$CLIENT"; then
            echo "orphan $name DJAgentClient.swift never forwards it to the agent as proxy.${name}("
            continue
        fi
        callers="$(grep -rlE --include='*.swift' "DJAgentClient\.shared\.${name}\(" "$APP" |
            grep -vF "$CLIENT" | sed "s|^$REPO/||" | sort | tr '\n' ' ')"
        if [ -z "$callers" ]; then
            echo "orphan $name nothing in DiskJockeyApplication/ calls DJAgentClient.shared.${name}("
        else
            echo "ok $name ${callers% }"
        fi
    done
}

for f in "$PROTOCOL" "$CLIENT"; do
    [ -f "$f" ] || { echo "no ${f#"$REPO/"}: this guard has nothing to read" >&2; exit 1; }
done

# ----------------------------------------------- the real protocol, method by method
result="$(check "$PROTOCOL")"
if [ -z "$result" ]; then
    fail "no func declarations found in ${PROTOCOL#"$REPO/"}: the protocol moved or its syntax changed, and nothing was checked"
fi
while read -r verdict name rest; do
    [ -n "${verdict:-}" ] || continue
    if [ "$verdict" = ok ]; then
        ok "$name is called, from $rest"
    else
        fail "$name has no caller: $rest — remove it from both DJAgentProtocol.swift copies, AgentImpl and DJAgentClient, or call it"
    fi
done <<< "$result"

# --------------------------------------- control: an orphan method is refused
sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT
awk '
    /^}/ && !done { print "    func orphanForTheControl(reply: @escaping (_ success: Bool, _ error: String?) -> Void)"; done = 1 }
    { print }
' "$PROTOCOL" > "$sandbox/DJAgentProtocol.swift"
if check "$sandbox/DJAgentProtocol.swift" | grep -q '^orphan orphanForTheControl '; then
    ok "control: a protocol method with no caller is refused"
else
    fail "control: a protocol method with no caller was accepted, so this guard cannot fail"
fi

if [ "$fails" -eq 0 ]; then
    echo "every-agent-method-has-a-caller: all checks passed"
else
    echo "every-agent-method-has-a-caller: $fails check(s) failed" >&2
fi
exit $(( fails > 0 ))
