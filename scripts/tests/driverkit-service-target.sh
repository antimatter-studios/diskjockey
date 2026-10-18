#!/usr/bin/env bash
# Read the project graph, not comments that merely name a DriverKit target.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fails=0
ok()   { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }

if python3 - "$ROOT" <<'PY'
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
expected = {'DiskJockey', 'DiskJockeyAgent', 'DiskJockeyLibrary',
            'DiskJockeyFileProvider', 'DiskJockeyTests', 'DiskJockeyUITests',
            'DiskJockeyLibraryTests', 'DiskJockeyEXT4', 'DiskJockeyNTFS',
            'DiskJockeyXFS', 'DiskJockeyBTRFS', 'DiskJockeyEROFS',
            'DiskJockeySQUASHFS', 'DiskJockeyBCACHEFS'}
assert expected <= targets.keys(), 'existing application targets must remain'
assert 'DiskJockeyVirtualDisk' in targets, 'DriverKit service target is missing'
tid, target = targets['DiskJockeyVirtualDisk']
assert value(target, 'productType') == 'com.apple.product-type.driver-extension'
product = refs(target, 'productReference')[0]
assert value(objects[product], 'path') == 'DiskJockeyVirtualDisk.dext'
configs = refs(objects[refs(target, 'buildConfigurationList')[0]], 'buildConfigurations')
assert len(configs) == 2, 'Debug and Release must both configure the dext'
for cid in configs:
    config = objects[cid]
    assert value(config, 'SDKROOT') == 'driverkit'
    assert value(config, 'SUPPORTED_PLATFORMS') == 'driverkit'
    assert value(config, 'PRODUCT_BUNDLE_IDENTIFIER') == 'com.antimatterstudios.diskjockey.virtualdisk'
    assert value(config, 'CODE_SIGN_ENTITLEMENTS') == 'DiskJockeyVirtualDisk/DiskJockeyVirtualDisk.entitlements'
    assert value(config, 'INFOPLIST_FILE') == 'DiskJockeyVirtualDisk/Info.plist'
    assert not value(config, 'LIBRARY_SEARCH_PATHS'), 'no host Rust archives in the dext'
phases = [objects[pid] for pid in refs(target, 'buildPhases')]
sources = [objects[bid] for phase in phases if value(phase, 'isa') == 'PBXSourcesBuildPhase'
           for bid in refs(phase, 'files')]
names = {pathlib.Path(value(objects[refs(source, 'fileRef')[0]], 'path')).name for source in sources}
assert names == {'DJVirtualDiskService.cpp', 'DJVirtualDiskService.iig'}, names
app = targets['DiskJockey'][1]
copies = [objects[pid] for pid in refs(app, 'buildPhases')
          if value(objects[pid], 'isa') == 'PBXCopyFilesBuildPhase']
assert any(value(copy, 'dstPath') == 'Contents/Library/SystemExtensions'
           and value(copy, 'dstSubfolderSpec') == '1'
           and any(refs(objects[bid], 'fileRef') == [product] for bid in refs(copy, 'files'))
           for copy in copies), 'app must embed the dext in SystemExtensions'
assert any(refs(objects[did], 'target') == [tid] for did in refs(app, 'dependencies'))
info = plistlib.loads((root / 'DiskJockeyVirtualDisk/Info.plist').read_bytes())
assert info['CFBundlePackageType'] == 'DEXT'
assert info['CFBundleIdentifier'] == 'com.antimatterstudios.diskjockey.virtualdisk'
personality = info['IOKitPersonalities']['DJVirtualDiskManager']
assert personality['IOProviderClass'] == 'IOUserResources'
assert personality['IOClass'] == 'IOUserService'
assert personality['IOUserClass'] == 'DJVirtualDiskService'
assert personality['IOUserServerName'] == info['CFBundleIdentifier']
entitlements = plistlib.loads((root / 'DiskJockeyVirtualDisk/DiskJockeyVirtualDisk.entitlements').read_bytes())
assert entitlements == {'com.apple.developer.driverkit': True}, 'service-only least privilege'
PY
then
    ok 'the standalone service target preserves app targets and embeds a service-only dext'
else
    fail 'the DriverKit project graph or service personality is invalid'
fi
if [ "$fails" -eq 0 ]; then
    echo 'driverkit-service-target: all checks passed'
fi
exit "$((fails > 0))"
