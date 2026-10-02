#!/usr/bin/env bash
#
# fskit-path-url-declarations.sh — every FSKit module declares only the
# resource kinds mount(8) can actually hand it.
#
# WHAT THIS IS ABOUT (#165).
#
# `mount -F -t ext4 <image-file> <mountpoint>` never launched the EXT4
# extension: mount reported `extensionKit error 2` or ENOENT from
# `probeResourceSync:usingBundle:`, and `probeFileResource` never ran once in
# four months of logs. The extension declared FSSupportsPathURLs = true, which
# reads as "path mounts work". They cannot, and the reason is not in our code.
#
# mount(8) picks ONE resource kind per module, from the module's attributes,
# in a fixed order — diskdev_cmds `disklib/fskit_support.m`, unchanged from
# diskdev_cmds-751 (macOS 26.0) through -757, and the same order in the
# shipped 26.1 `mount` binary:
#
#     if (acceptsBD)        -> [FSBlockDeviceResource proxyResourceForBSDName:argv0 ...]
#     else if (acceptsPath) -> [FSPathURLResource secureResourceWithURL: / resourceWithURL:]
#
# FSSupportsBlockResources wins. A module declaring both turns the image's
# PATH into a block-device proxy for a BSD name that does not exist, so no
# device resolves, nothing launches, and FSSupportsPathURLs is never read.
# A file-backed mount needs a module that declares path URLs and NOT blocks.
#
# The same function chooses `secureResourceWithURL:` only when
# FSRequiresSecurityScopedPathURLResources is true. A sandboxed extension
# handed the plain `resourceWithURL:` form has no grant to open the file.
#
# And each key is read with `isKindOfClass:[NSNumber class]`, so a
# `<string>true</string>` is silently false.
#
# So, for every target whose Info.plist is an FSKit module (found through the
# project file's INFOPLIST_FILE, not a hand list):
#   1. it does not declare both block resources and path URLs;
#   2. a sandboxed module that declares path URLs requires security-scoped ones;
#   3. every resource-kind key it carries is a boolean.
# Then each rule is shown to FAIL on a copy that breaks it.
#
# TEXT ONLY. Runs in the ubuntu `Shell scripts` job; it builds nothing.
#
#   bash scripts/tests/fskit-path-url-declarations.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PBX="$REPO/DiskJockey.xcodeproj/project.pbxproj"
fails=0
ok()   { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1" >&2; fails=$((fails + 1)); }

[ -f "$PBX" ] || { echo "no project file at $PBX" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 is required to read the plists" >&2; exit 1; }

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

# The rules, once, as a program over (Info.plist, entitlements) pairs. Prints
# one line per module, `ok <name>` or `bad <name>: <reason>`; the shell
# decides what each line means.
cat > "$SANDBOX/rules.py" <<'PY'
import plistlib, re, sys

KINDS = ("FSSupportsBlockResources", "FSSupportsPathURLs",
         "FSSupportsGenericURLResources", "FSSupportsServerURLs",
         "FSRequiresSecurityScopedPathURLResources")

def judge(info_path, ents_path):
    with open(info_path, "rb") as f:
        attrs = plistlib.load(f).get("EXAppExtensionAttributes") or {}
    if attrs.get("EXExtensionPointIdentifier") != "com.apple.fskit.fsmodule":
        return None
    name = attrs.get("FSShortName", info_path)
    sandboxed = False
    if ents_path:
        with open(ents_path, "rb") as f:
            sandboxed = plistlib.load(f).get("com.apple.security.app-sandbox") is True
    bad = [k for k in KINDS if k in attrs and not isinstance(attrs[k], bool)]
    if bad:
        return "bad %s: %s is not a boolean, and mount(8) reads a non-NSNumber as false" % (name, ", ".join(bad))
    if attrs.get("FSSupportsBlockResources") is True and attrs.get("FSSupportsPathURLs") is True:
        return ("bad %s: declares FSSupportsBlockResources AND FSSupportsPathURLs; mount(8) takes the "
                "block branch first, so a file path becomes a BSD-name proxy and never reaches the module" % name)
    if (attrs.get("FSSupportsPathURLs") is True and sandboxed
            and attrs.get("FSRequiresSecurityScopedPathURLResources") is not True):
        return ("bad %s: a sandboxed module accepting path URLs without FSRequiresSecurityScopedPathURLResources "
                "gets a plain URL it has no grant to open" % name)
    return "ok %s" % name

def modules(pbx):
    s = open(pbx).read()
    root = pbx.rsplit("/", 2)[0]
    seen = {}
    for blk in re.findall(r"buildSettings = \{(.*?)\n\t+\};", s, re.S):
        info = re.search(r"(?m)^\s*INFOPLIST_FILE = \"?([^\";]+)\"?;", blk)
        if not info:
            continue
        ents = re.search(r"(?m)^\s*CODE_SIGN_ENTITLEMENTS = \"?([^\";]+)\"?;", blk)
        key = (info.group(1), ents.group(1) if ents else "")
        seen[key] = True
    return [("%s/%s" % (root, i), "%s/%s" % (root, e) if e else "") for i, e in seen]

if sys.argv[1] == "--project":
    for info, ents in modules(sys.argv[2]):
        line = judge(info, ents)
        if line:
            print(line)
else:
    print(judge(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else ""))
PY

# ------------------------------------------------------- the real modules
report="$(python3 "$SANDBOX/rules.py" --project "$PBX" 2>&1)" || {
    fail "could not read the FSKit modules' Info.plists: $report"; report=""; }
count="$(printf '%s\n' "$report" | grep -c '^ok \|^bad ' || true)"

# Six FSKit extensions ship: EXT4, NTFS, XFS, BTRFS, EROFS, SQUASHFS. Fewer
# means the project-file reading stopped matching, which would pass vacuously.
if [ "$count" -ge 6 ]; then
    ok "found $count FSKit modules through the project file's INFOPLIST_FILE settings"
else
    fail "found only $count FSKit modules (6 ship); the project-file reading has stopped matching"
fi

nbad=0
while IFS= read -r line; do
    case "$line" in bad\ *) fail "${line#bad }"; nbad=$((nbad + 1)) ;; esac
done <<< "$report"
[ "$nbad" = 0 ] && [ "$count" -gt 0 ] \
    && ok "each declares only resource kinds mount(8) can deliver to it"

# ------------------------------------------- each rule fails when broken
# A guard that cannot fail is no guard. Start from the EXT4 module's real
# plist and break one rule at a time.
EXT4_INFO="$REPO/DiskJockeyEXT4/Info.plist"
EXT4_ENTS="$REPO/DiskJockeyEXT4/DiskJockeyEXT4.entitlements"
mutate() {  # mutate <out> <python statements over attrs>
    python3 - "$EXT4_INFO" "$1" "$2" <<'PY'
import plistlib, sys
d = plistlib.load(open(sys.argv[1], "rb"))
attrs = d["EXAppExtensionAttributes"]
exec(sys.argv[3])
plistlib.dump(d, open(sys.argv[2], "wb"))
PY
}
expect_bad() {  # expect_bad <label> <plist>
    case "$(python3 "$SANDBOX/rules.py" "$2" "$EXT4_ENTS")" in
        bad\ *) ok "rejects $1" ;;
        *)      fail "accepted $1" ;;
    esac
}

mutate "$SANDBOX/both.plist" 'attrs["FSSupportsBlockResources"]=True; attrs["FSSupportsPathURLs"]=True'
expect_bad "a module declaring both block resources and path URLs" "$SANDBOX/both.plist"

mutate "$SANDBOX/plain.plist" 'attrs["FSSupportsBlockResources"]=False; attrs["FSSupportsPathURLs"]=True; attrs["FSRequiresSecurityScopedPathURLResources"]=False'
expect_bad "a sandboxed path-URL module without security-scoped resources" "$SANDBOX/plain.plist"

mutate "$SANDBOX/string.plist" 'attrs["FSSupportsPathURLs"]="true"'
expect_bad "a resource-kind key written as a string" "$SANDBOX/string.plist"

# and the shape a working file-backed module has passes
mutate "$SANDBOX/path.plist" 'attrs["FSSupportsBlockResources"]=False; attrs["FSSupportsPathURLs"]=True; attrs["FSRequiresSecurityScopedPathURLResources"]=True'
case "$(python3 "$SANDBOX/rules.py" "$SANDBOX/path.plist" "$EXT4_ENTS")" in
    ok\ *) ok "accepts a path-only module that requires security-scoped resources" ;;
    *)     fail "rejected a path-only, security-scoped module, which is the shape mount(8) can deliver to" ;;
esac

if [ "$fails" -gt 0 ]; then
    echo "fskit-path-url-declarations: $fails check(s) failed" >&2
    exit 1
fi
echo "fskit-path-url-declarations: all checks passed"
