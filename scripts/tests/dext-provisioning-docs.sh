#!/usr/bin/env bash
# The virtual disk driver's activation section names every capability the
# project actually signs with or Apple's frameworks require of it, and the
# README's known gaps link to it. Reads project.pbxproj, the entitlements,
# the dext's Info.plist and the agent's sources as data, so the document
# cannot drift from what the build produces.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fails=0
ok()   { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }

check() {
    local name="$1" code="$2" out
    if out="$(python3 - "$ROOT" <<PY 2>&1
import pathlib, plistlib, re, sys
root = pathlib.Path(sys.argv[1])
text = (root / 'DiskJockey.xcodeproj/project.pbxproj').read_text()
objects = {}
for match in re.finditer(r'^\t\t([A-Z0-9]{24}) /\*[^\n]*?\*/ = \{', text, re.M):
    end = text.index('\n', match.end())
    if not text[match.end():end].endswith('};'):
        end = text.index('\n\t\t};', match.end())
    objects[match[1]] = text[match.end():end]

def value(body, key):
    match = re.search(r'\b' + key + r'\s*=\s*([^;]+);', body)
    return match[1].strip().strip('"') if match else ''

def refs(body, key):
    return re.findall(r'\b[A-Z0-9]{24}\b', value(body, key))

targets = {value(body, 'name'): body for body in objects.values()
           if value(body, 'isa') == 'PBXNativeTarget'}

def configs(name):
    return [objects[cid] for cid in
            refs(objects[refs(targets[name], 'buildConfigurationList')[0]], 'buildConfigurations')]

def entitlements(name):
    keys = {}
    for config in configs(name):
        path = value(config, 'CODE_SIGN_ENTITLEMENTS')
        assert path, name + ' configuration has no entitlements'
        keys.update(plistlib.loads((root / path).read_bytes()))
    return keys

readme = (root / 'DiskJockeyVirtualDisk/README.md').read_text()
heading = '## Activation and provisioning'
assert heading in readme, 'no "' + heading + '" section in DiskJockeyVirtualDisk/README.md'
section = readme.split(heading, 1)[1].split('\n## ', 1)[0]
$code
PY
)"; then
        ok "$name"
    else
        fail "$name"
        printf '%s\n' "$out" | tail -3 | sed 's/^/      /'
    fi
}

check 'the section names every entitlement the dext is signed with' '
keys = entitlements("DiskJockeyVirtualDisk")
assert keys, "the dext signs with no entitlements"
missing = [k for k in keys if "`" + k + "`" not in section]
assert not missing, missing
'

check 'the section names the install entitlement the app is signed with' '
assert entitlements("DiskJockey").get("com.apple.developer.system-extension.install") is True
assert "`com.apple.developer.system-extension.install`" in section
assert "no activation UI or installation entitlement" not in readme, \
    "the README still says the app lacks the install entitlement"
'

check 'the section names the dext bundle identifier and where the app embeds it' '
ids = {value(c, "PRODUCT_BUNDLE_IDENTIFIER") for c in configs("DiskJockeyVirtualDisk")}
assert len(ids) == 1, ids
assert "`" + ids.pop() + "`" in section
paths = {value(objects[pid], "dstPath") for pid in refs(targets["DiskJockey"], "buildPhases")
         if value(objects[pid], "isa") == "PBXCopyFilesBuildPhase"}
assert "Contents/Library/SystemExtensions" in paths, paths
assert "`Contents/Library/SystemExtensions`" in section
'

check 'a block-storage child requires the block-storage family entitlement to be named' '
info = plistlib.loads((root / "DiskJockeyVirtualDisk/Info.plist").read_bytes())
classes = re.findall(r"IOUserBlockStorageDevice", plistlib.dumps(info).decode())
assert classes, "the personality no longer publishes IOUserBlockStorageDevice"
assert "`com.apple.developer.driverkit.family.block-storage-device`" in section
'

check 'an agent that opens the user client requires the user-client access entitlement to be named' '
opens = [p for p in (root / "DiskJockeyAgent").rglob("*") if p.suffix in (".c", ".cpp", ".mm", ".swift")
         and re.search(r"\bIOServiceOpen\s*\(", p.read_text())]
assert opens, "no agent source opens a user client"
configs("DiskJockeyAgent")
assert "`com.apple.developer.driverkit.userclient-access`" in section
assert "`DiskJockeyAgent/DiskJockeyAgent.entitlements`" in section
'

check 'the dext signs with the block-storage family entitlement' '
granted = entitlements("DiskJockeyVirtualDisk").get("com.apple.developer.driverkit.family.block-storage-device")
assert granted is True, granted
'

check 'the agent signs with user-client access to the dext bundle identifier' '
ids = {value(c, "PRODUCT_BUNDLE_IDENTIFIER") for c in configs("DiskJockeyVirtualDisk")}
assert len(ids) == 1, ids
granted = entitlements("DiskJockeyAgent").get("com.apple.developer.driverkit.userclient-access")
assert granted == [ids.pop()], granted
'

check 'the capabilities table marks no entitlement as missing from the project' '
rows = [line for line in section.splitlines() if line.startswith("| the ")]
assert rows, "the capabilities table has no rows"
missing = [line.split("|")[2].strip() for line in rows if line.split("|")[4].strip().startswith("**no**")]
assert not missing, missing
'

check 'the section names each command and the Apple documents it relies on' '
for needle in ("systemextensionsctl developer on", "systemextensionsctl developer off",
               "systemextensionsctl list", "csrutil status", "ioreg -l -w0 -c IOUserService",
               "Installing System Extensions and Drivers",
               "Debugging and testing system extensions",
               "Requesting Entitlements for DriverKit Development"):
    assert needle in section, needle
'

check 'the README known gaps link to the activation section' '
top = (root / "README.md").read_text()
gaps = top.split("## What doesn'"'"'t work", 1)[1].split("\n## ", 1)[0]
assert "DiskJockeyVirtualDisk/README.md#activation-and-provisioning" in gaps
'

if [ "$fails" -eq 0 ]; then
    echo 'dext-provisioning-docs: all checks passed'
fi
exit "$((fails > 0))"
