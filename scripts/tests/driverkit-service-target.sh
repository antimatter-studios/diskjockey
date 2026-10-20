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
    assert value(config, 'GCC_TREAT_WARNINGS_AS_ERRORS') == 'YES', 'the dext builds with fatal warnings'
phases = [objects[pid] for pid in refs(target, 'buildPhases')]
sources = [objects[bid] for phase in phases if value(phase, 'isa') == 'PBXSourcesBuildPhase'
           for bid in refs(phase, 'files')]
names = {pathlib.Path(value(objects[refs(source, 'fileRef')[0]], 'path')).name for source in sources}
assert names == {'DJVirtualDiskService.cpp', 'DJVirtualDiskService.iig',
                 'DJVirtualDiskUserClient.cpp', 'DJVirtualDiskUserClient.iig',
                 'DJVirtualDiskDevice.cpp', 'DJVirtualDiskDevice.iig'}, names
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
client = personality['UserClientProperties']
assert client['IOClass'] == 'IOUserUserClient'
assert client['IOUserClass'] == 'DJVirtualDiskUserClient'
service = (root / 'DiskJockeyVirtualDisk/DJVirtualDiskService.iig').read_text()
assert re.search(r'\bkern_return_t\s+NewUserClient\s*\(', service), 'the service opens user clients'
user = (root / 'DiskJockeyVirtualDisk/DJVirtualDiskUserClient.iig').read_text()
assert re.search(r'class\s+DJVirtualDiskUserClient\s*:\s*public\s+IOUserClient\b', user)
assert re.search(r'\bkern_return_t\s+ExternalMethod\s*\(', user), 'the user client dispatches'
source = (root / 'DiskJockeyVirtualDisk/DJVirtualDiskUserClient.cpp').read_text()
assert 'DJUserClientDispatch' in source and 'IOTimerDispatchSource' in source, 'hosts the dispatch core'
device = (root / 'DiskJockeyVirtualDisk/DJVirtualDiskDevice.iig').read_text()
assert re.search(r'class\s+DJVirtualDiskDevice\s*:\s*public\s+IOUserBlockStorageDevice\b', device), \
    "the child subclasses Apple's IOUserBlockStorageDevice"
assert '<BlockStorageDeviceDriverKit/IOUserBlockStorageDevice.iig>' in device
child = (root / 'DiskJockeyVirtualDisk/DJVirtualDiskDevice.cpp').read_text()
assert '#include "DJVirtualDiskBlockIO.h"' in child and 'DJBlockIO<' in child, 'I/O routes through the block-I/O core'
assert 'kDJAttachmentIdentityKey' in child, 'the child publishes the attachment identity'
assert re.search(r'\*isWriteProtected\s*=\s*true\s*;', child), 'the media is write-protected'
assert 'failAll(' in child, 'terminating the child completes pending I/O'
# The user client hosts the mount selectors; its publish hook has the service
# create the child from this personality, and its remove hook terminates it.
device_personality = personality['DJVirtualDiskDeviceProperties']
assert device_personality['IOClass'] == 'IOUserBlockStorageDevice'
assert device_personality['IOUserClass'] == 'DJVirtualDiskDevice'
assert '#include "DJVirtualDiskMountSelectors.h"' in source and 'DJMountTable' in source, \
    'the user client hosts the mount-selector core'
assert re.search(r'\bCreate\s*\([^;]*kDJDevicePropertiesKey', source), 'publish creates the child from its personality'
assert re.search(r'->Terminate\s*\(', source), 'remove terminates the child'
for key in ('kDJAttachmentIdentityKey', 'kDJDeviceByteOffsetKey', 'kDJDeviceByteLengthKey', 'kDJDeviceBlockSizeKey'):
    assert key in source and key in child, key
shared_text = (root / 'DiskJockeyVirtualDisk/DJVirtualDiskShared.h').read_text()
for key, name in (('kDJDeviceByteOffsetKey', 'DJByteOffset'), ('kDJDeviceByteLengthKey', 'DJByteLength'),
                  ('kDJDeviceBlockSizeKey', 'DJBlockSize')):
    assert re.search(r'#define\s+' + key + r'\s+"' + name + r'"\s*$', shared_text, re.M), key
    assert not re.search(r'#\s*define\s+' + key + r'\b', child), key + ' is defined once, in the shared header'
entitlements = plistlib.loads((root / 'DiskJockeyVirtualDisk/DiskJockeyVirtualDisk.entitlements').read_bytes())
assert entitlements == {'com.apple.developer.driverkit': True,
                        'com.apple.developer.driverkit.family.block-storage-device': True}, \
    'least privilege: DriverKit plus the block-storage family its child publishes'
PY
then
    ok 'the service target embeds a dext whose user client hosts the read dispatch and mount-selector cores'
else
    fail 'the DriverKit project graph or service personality is invalid'
fi
# One definition of the identity key, in the header the agent and the dext both
# include, so the matcher cannot search for a key the child never publishes.
if python3 - "$ROOT" <<'PY'
import pathlib, re, sys
root = pathlib.Path(sys.argv[1])
sources = [p for d in ('DiskJockeyAgent', 'DiskJockeyVirtualDisk') for p in sorted((root / d).iterdir())
           if p.suffix in {'.h', '.hpp', '.c', '.cpp', '.iig', '.swift'}]
defs = [p.relative_to(root).as_posix() for p in sources
        if re.search(r'^\s*#\s*define\s+kDJAttachmentIdentityKey\b', p.read_text(), re.M)]
assert defs == ['DiskJockeyVirtualDisk/DJVirtualDiskShared.h'], defs
shared = (root / 'DiskJockeyVirtualDisk/DJVirtualDiskShared.h').read_text()
assert re.search(r'#define\s+kDJAttachmentIdentityKey\s+"DJAttachmentIdentity"\s*$', shared, re.M)
match = (root / 'DiskJockeyAgent/DJAgentMediaMatch.hpp').read_text()
assert '#include "../DiskJockeyVirtualDisk/DJVirtualDiskShared.h"' in match, 'the agent matcher includes the shared key'
child = (root / 'DiskJockeyVirtualDisk/DJVirtualDiskDevice.cpp').read_text()
assert '#include "DJVirtualDiskShared.h"' in child, 'the dext child includes the shared key'
PY
then
    ok 'the agent and the dext take the attachment identity key from one shared header'
else
    fail 'the attachment identity key is defined more than once or not shared'
fi
if [ "$fails" -eq 0 ]; then
    echo 'driverkit-service-target: all checks passed'
fi
exit "$((fails > 0))"
