#!/usr/bin/env bash
# The app may install the virtual disk system extension, asks for exactly
# the dext it embeds, and asks only when a qcow2 or VHDX image is mounted.
# Reads project.pbxproj, the entitlements and the Swift call sites as data.
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

targets = {value(body, 'name'): (oid, body) for oid, body in objects.items()
           if value(body, 'isa') == 'PBXNativeTarget'}

def configs(name):
    target = targets[name][1]
    return [objects[cid] for cid in
            refs(objects[refs(target, 'buildConfigurationList')[0]], 'buildConfigurations')]

app_sources = sorted((root / 'DiskJockeyApplication').rglob('*.swift'))
activator = root / 'DiskJockeyApplication/Services/SystemExtensionActivator.swift'
$code
PY
)"; then
        ok "$name"
    else
        fail "$name"
        printf '%s\n' "$out" | tail -3 | sed 's/^/      /'
    fi
}

check 'every app configuration signs with entitlements that allow system-extension install' '
cfgs = configs("DiskJockey")
assert len(cfgs) == 2, "Debug and Release must both configure the app"
for config in cfgs:
    path = value(config, "CODE_SIGN_ENTITLEMENTS")
    assert path, "app configuration has no entitlements"
    ent = plistlib.loads((root / path).read_bytes())
    assert ent.get("com.apple.developer.system-extension.install") is True, path
'

check 'the app requests the bundle identifier of the dext it embeds' '
dext = {value(c, "PRODUCT_BUNDLE_IDENTIFIER") for c in configs("DiskJockeyVirtualDisk")}
assert len(dext) == 1, dext
info = plistlib.loads((root / "DiskJockeyVirtualDisk/Info.plist").read_bytes())
assert info["CFBundleIdentifier"] in dext, info["CFBundleIdentifier"]
source = activator.read_text()
ids = re.findall(r"static let identifier\s*=\s*\"([^\"]+)\"", source)
assert ids == list(dext), (ids, dext)
assert re.search(r"activationRequest\(\s*forExtensionWithIdentifier:\s*Self\.identifier\b", source), \
    "the request must name Self.identifier"
'

check 'the dext is embedded under Contents/Library/SystemExtensions' '
tid, target = targets["DiskJockeyVirtualDisk"]
product = refs(target, "productReference")[0]
app = targets["DiskJockey"][1]
copies = [objects[pid] for pid in refs(app, "buildPhases")
          if value(objects[pid], "isa") == "PBXCopyFilesBuildPhase"]
assert any(value(copy, "dstPath") == "Contents/Library/SystemExtensions"
           and value(copy, "dstSubfolderSpec") == "1"
           and any(refs(objects[bid], "fileRef") == [product] for bid in refs(copy, "files"))
           for copy in copies), "dext not embedded in SystemExtensions"
'

check 'one file in the app submits an activation request' '
users = [p.relative_to(root).as_posix() for p in app_sources
         if re.search(r"OSSystemExtensionRequest\s*\.\s*activationRequest", p.read_text())]
assert users == ["DiskJockeyApplication/Services/SystemExtensionActivator.swift"], users
assert "OSSystemExtensionManager.shared.submitRequest" in activator.read_text()
'

check 'activation is requested only from the DriverKit image mount branch' '
calls = {p.relative_to(root).as_posix(): len(re.findall(r"SystemExtensionActivator\s*\.\s*shared\s*\.\s*activate\(", p.read_text()))
         for p in app_sources if p != activator}
calls = {k: v for k, v in calls.items() if v}
mount = (root / "DiskJockeyApplication/Services/FSKitMountService.swift").read_text()
attaches = [m.start() for m in re.finditer(r"DriverKitImageAttachment\.attach\(", mount)]
assert attaches, "FSKitMountService.swift attaches no DriverKit image"
assert calls == {"DiskJockeyApplication/Services/FSKitMountService.swift": len(attaches)}, calls
# One activation per DriverKit branch, the partitioned one and the whole
# disk (diskjockey#515): each after its own URL check and before its attach.
for attach in attaches:
    branch_start = mount.rindex("the DriverKit route needs the image", 0, attach)
    call = mount.rindex("SystemExtensionActivator.shared.activate(", 0, attach)
    assert branch_start < call < attach, "activation must precede the DriverKit attach, inside its branch"
'

check 'nothing on the launch path requests activation' '
launch = [p for p in app_sources
          if re.search(r"@main\b|applicationDidFinishLaunching|applicationWillFinishLaunching", p.read_text())]
assert launch, "no launch file found"
for p in launch:
    body = p.read_text()
    assert "SystemExtensionActivator" not in body and "OSSystemExtension" not in body, p
'

if [ "$fails" -eq 0 ]; then
    echo 'system-extension-activation: all checks passed'
fi
exit "$((fails > 0))"
