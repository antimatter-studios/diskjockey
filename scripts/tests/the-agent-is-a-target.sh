#!/usr/bin/env bash
#
# the-agent-is-a-target.sh — the XPC helper is built, embedded, and reachable.
#
# WHAT THIS IS ABOUT, AND WHY IT IS WORTH A FILE OF ITS OWN.
#
# Mounting a disk image from the UI goes app -> DJAgentClient -> XPC ->
# DiskJockeyAgent -> `hdiutil attach` -> DiskArbitration -> FSKit extension.
# The agent is the only unsandboxed part; the sandboxed app cannot shell out
# to hdiutil, and diskarbitrationd does the privileged mount, so nothing here
# needs root.
#
# For most of the project's life that agent was NOT a target in the Xcode
# project. It was compiled by hand once, dropped into a DerivedData bundle,
# and installed as a user LaunchAgent whose plist pointed INTO DerivedData.
# Anything that cleared DerivedData -- `dev.sh clean`, Xcode's own cleanup --
# deleted the binary and orphaned the plist, and at the next login launchd
# had nothing to run.
#
# The failure that produced was: the user picks a disk image and NOTHING
# HAPPENS. The XPC connect fails, the throw is caught, and the message goes
# into an in-memory array. On 2026-09-10 that cost an evening of guessing,
# with `docs/driverkit-qcow2-architecture.md`'s DriverKit fallback and an
# untested `FSPathURLResource` path both investigated before anyone noticed
# the helper was simply absent.
#
# So every load-bearing piece of that arrangement is asserted here: the
# target exists, it is unsandboxed, the app embeds it where launchd's plist
# expects it, the app cannot be built without it, and the facts the two sides
# duplicate by hand still agree.
#
# TEXT ONLY. Runs in the ubuntu `Shell scripts` job, so it reads the project
# file and the sources; it does not build anything.
#
#   bash scripts/tests/the-agent-is-a-target.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PBX="$REPO/DiskJockey.xcodeproj/project.pbxproj"
AGENT_DIR="$REPO/DiskJockeyAgent"
fails=0
ok()   { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1" >&2; fails=$((fails + 1)); }

[ -f "$PBX" ] || { echo "no project file at $PBX" >&2; exit 1; }

# ------------------------------------------------------------- the target
target_json="$(python3 - "$PBX" <<'PY'
import json, re, sys
s = open(sys.argv[1]).read()
out = {"exists": False, "productType": None, "sandbox": None, "entitlements": None,
       "sources": [], "embedded_at": None, "app_depends": False}
m = re.search(r'/\* DiskJockeyAgent \*/ = \{\n\t+isa = PBXNativeTarget;(.*?)\n\t+name = DiskJockeyAgent;', s, re.S)
if m:
    out["exists"] = True
    body = m.group(1)
    pt = re.search(r'productType = "([^"]+)"', s[m.end():m.end()+400])
    out["productType"] = pt.group(1) if pt else None
    cl = re.search(r'buildConfigurationList = ([0-9A-F]{24})', body)
    if cl:
        lst = re.search(re.escape(cl.group(1)) + r' /\*.*?\*/ = \{\n\t+isa = XCConfigurationList;\n\t+buildConfigurations = \((.*?)\);', s, re.S)
        for cid, _ in re.findall(r'([0-9A-F]{24}) /\* (\w+) \*/', lst.group(1) if lst else ""):
            blk = re.search(re.escape(cid) + r' /\* \w+ \*/ = \{\n\t+isa = XCBuildConfiguration;\n\t+buildSettings = \{(.*?)\n\t+\};', s, re.S)
            if not blk: continue
            sb = re.search(r'ENABLE_APP_SANDBOX = (\w+);', blk.group(1))
            en = re.search(r'CODE_SIGN_ENTITLEMENTS = ([^;]+);', blk.group(1))
            # PER CONFIGURATION, not one value. Taking a single reading let an
            # arm that removed the setting from Release alone pass, because
            # Debug still carried it.
            out.setdefault("configs", []).append({
                "sandbox": sb.group(1) if sb else None,
                "entitlements": en.group(1).strip('"') if en else None,
            })
            if sb: out["sandbox"] = sb.group(1)
            if en: out["entitlements"] = en.group(1).strip('"')
    ph = re.search(r'buildPhases = \((.*?)\);', body, re.S)
    for pid, _ in re.findall(r'([0-9A-F]{24}) /\* ([^*]+) \*/', ph.group(1) if ph else ""):
        blk = re.search(re.escape(pid) + r' /\* [^*]+ \*/ = \{\n\t+isa = PBXSourcesBuildPhase;(.*?)\n\t+\};', s, re.S)
        if blk:
            out["sources"] = sorted(re.findall(r'/\* ([^ ]+\.swift) in Sources \*/', blk.group(1)))
# how the app embeds it, and whether it depends on it
app = re.search(r'/\* DiskJockey \*/ = \{\n\t+isa = PBXNativeTarget;(.*?)\n\t+name = DiskJockey;', s, re.S)
if app:
    ph = re.search(r'buildPhases = \((.*?)\);', app.group(1), re.S)
    for pid, _ in re.findall(r'([0-9A-F]{24}) /\* ([^*]+) \*/', ph.group(1) if ph else ""):
        blk = re.search(re.escape(pid) + r' /\* [^*]+ \*/ = \{\n\t+isa = PBXCopyFilesBuildPhase;(.*?)\n\t+\};', s, re.S)
        if blk and "DiskJockeyAgent" in blk.group(1):
            d = re.search(r'dstPath = "?([^";]*)"?;', blk.group(1))
            out["embedded_at"] = d.group(1) if d else ""
    dep = re.search(r'dependencies = \((.*?)\);', app.group(1), re.S)
    for did, _ in re.findall(r'([0-9A-F]{24}) /\* ([^*]+) \*/', dep.group(1) if dep else ""):
        blk = re.search(re.escape(did) + r' /\* PBXTargetDependency \*/ = \{(.*?)\n\t+\};', s, re.S)
        if blk and "DiskJockeyAgent" in blk.group(1):
            out["app_depends"] = True
print(json.dumps(out))
PY
)"
get() { printf '%s' "$target_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('$1'))"; }

if [ "$(get exists)" = "True" ]; then
    ok "DiskJockeyAgent is a target in the Xcode project"
else
    fail "DiskJockeyAgent is NOT an Xcode target: it has to be hand-compiled, so it disappears on the next clean and the disk-image UI silently stops working"
    echo "the-agent-is-a-target: $fails check(s) failed" >&2
    exit 1
fi

case "$(get productType)" in
    com.apple.product-type.tool) ok "and it builds as a command-line tool" ;;
    *) fail "the agent's productType is $(get productType), not com.apple.product-type.tool" ;;
esac

# THE ONE SETTING THE HELPER EXISTS FOR. Sandboxed, it cannot run hdiutil,
# read pluginkit state, or drive osascript — which is the entire job.
case "$(get sandbox)" in
    NO) ok "and it is built UNSANDBOXED, which is the only reason it exists" ;;
    *)  fail "ENABLE_APP_SANDBOX is $(get sandbox) for the agent; sandboxed it cannot run hdiutil or read extension state, which is its whole purpose" ;;
esac

# EVERY CONFIGURATION, because a setting present in Debug and absent in
# Release ships a sandboxed helper from a release build only.
cfg_report="$(printf '%s' "$target_json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
cfgs = d.get("configs") or []
if not cfgs:
    print("none"); raise SystemExit
bad = [c for c in cfgs if c.get("sandbox") != "NO" or not c.get("entitlements")]
print("ok %d" % len(cfgs) if not bad else "bad %d of %d" % (len(bad), len(cfgs)))
')"
case "$cfg_report" in
    "ok "*) ok "and ${cfg_report#ok } configurations all set ENABLE_APP_SANDBOX=NO with an entitlements file" ;;
    none)   fail "could not read the agent's build configurations" ;;
    *)      fail "the agent's build configurations disagree ($cfg_report): a setting present in Debug and absent in Release ships a sandboxed helper from a release build" ;;
esac

ents="$(get entitlements)"
if [ -n "$ents" ] && [ "$ents" != "None" ] && [ -f "$REPO/$ents" ]; then
    ok "and it signs with $ents"
    if grep -A 1 'com.apple.security.app-sandbox' "$REPO/$ents" | grep -q '<false/>'; then
        ok "whose app-sandbox key is false"
    else
        fail "$ents does not set com.apple.security.app-sandbox to false"
    fi
else
    fail "the agent has no CODE_SIGN_ENTITLEMENTS pointing at a file that exists (got ${ents:-none})"
fi

# Every source in the directory must be compiled, for the same reason the
# EXT4 extension's list is checked: this target has an explicit source list.
compiled="$(printf '%s' "$target_json" | python3 -c "import json,sys; print(' '.join(json.load(sys.stdin)['sources']))")"
missing=""
for f in "$AGENT_DIR"/*.swift; do
    b="$(basename "$f")"
    case " $compiled " in *" $b "*) ;; *) missing="$missing $b" ;; esac
done
if [ -z "$missing" ]; then
    ok "and it compiles every .swift file in DiskJockeyAgent/"
else
    fail "DiskJockeyAgent/ has files the target does not compile:$missing"
fi

# --------------------------------------------------- where launchd looks
# `scripts/install-agent-dev.sh` searches DerivedData for
# .../DiskJockey.app/Contents/Library/LaunchAgents/DiskJockeyAgent and writes
# a plist whose Program is that path. If the app stops embedding it there,
# the installer finds nothing and says so — but only if somebody runs it.
embed="$(get embedded_at)"
case "$embed" in
    Contents/Library/LaunchAgents) ok "the app embeds it at Contents/Library/LaunchAgents, where install-agent-dev.sh looks" ;;
    None|"") fail "the app has no copy phase embedding DiskJockeyAgent: the binary is built and then left behind in the products directory" ;;
    *) fail "the app embeds the agent at '$embed'; install-agent-dev.sh searches Contents/Library/LaunchAgents and will not find it" ;;
esac
if [ -n "$(grep -c 'Contents/Library/LaunchAgents' "$REPO/scripts/install-agent-dev.sh" 2>/dev/null || echo 0)" ] \
   && grep -q 'LaunchAgents' "$REPO/scripts/install-agent-dev.sh" 2>/dev/null; then
    ok "and the installer agrees on that path"
else
    fail "scripts/install-agent-dev.sh no longer references the LaunchAgents path the app embeds into"
fi

if [ "$(get app_depends)" = "True" ]; then
    ok "and the app target depends on the agent, so it cannot be built without one"
else
    fail "the app does not depend on the agent target: a build can succeed while producing no helper, which is the state that caused diskjockey's silent attach failures"
fi

# --------------------------------- the facts duplicated by hand still agree
# Both files say, in words, that changing one without the other breaks the
# XPC and that neither side reports why.
agent_team="$(grep -oE 'kTeamID = "[^"]+"' "$AGENT_DIR/main.swift" 2>/dev/null | head -1 | cut -d'"' -f2)"
app_team="$(grep -oE 'teamID = "[^"]+"' "$REPO/DiskJockeyApplication/Services/DJAgentClient.swift" 2>/dev/null | head -1 | cut -d'"' -f2)"
if [ -n "$agent_team" ] && [ "$agent_team" = "$app_team" ]; then
    ok "both sides pin the same team identifier ($agent_team)"
else
    fail "team identifier mismatch: agent says '${agent_team:-none}', app says '${app_team:-none}' — the XPC connection is then invalidated with no error at either call site"
fi

if diff -q "$AGENT_DIR/DJAgentProtocol.swift" \
           "$REPO/DiskJockeyApplication/Services/DJAgentProtocol.swift" >/dev/null 2>&1; then
    ok "and the two copies of DJAgentProtocol.swift are identical"
else
    fail "the agent's and the app's DJAgentProtocol.swift differ: an @objc protocol mismatch fails the XPC call at runtime, not at compile time"
fi

# ------------------------------------------- and a failure leaves a trace
# The attach flow used to report only into an in-memory array, so "nothing
# happened" left nothing on disk to read. It writes through AppLog now, which
# LogTailService feeds back into the same panel.
MOUNTSVC="$REPO/DiskJockeyApplication/Services/FSKitMountService.swift"
if grep -q 'AppLog.shared.event' "$MOUNTSVC" 2>/dev/null; then
    ok "the attach flow's log lines are written through AppLog, so they survive the process"
else
    fail "FSKitMountService no longer logs through AppLog: its messages go only into LogRepository's in-memory array, which is why 'nothing happens' left no evidence anywhere"
fi

if [ "$fails" -eq 0 ]; then
    echo "the-agent-is-a-target: all checks passed"
else
    echo "the-agent-is-a-target: $fails check(s) failed" >&2
fi
exit $(( fails > 0 ))
