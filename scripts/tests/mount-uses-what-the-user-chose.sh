#!/usr/bin/env bash
#
# mount-uses-what-the-user-chose.sh — the mount flow applies every choice it
# takes, and reports the mount point Disk Arbitration used (diskjockey#290).
#
# Mounting is `hdiutil attach` plus `DADiskMountWithArguments(disk, nil, …)`.
# The nil is the mount path, so diskarbitrationd mounts each volume at its own
# label, and it picks the driver by probing: there is no argument that names a
# filesystem. Yet the service took a `name` ("becomes the mount point under
# /Volumes"), a `mountPointPrefix` and an `fsType`, and the app collected them
# from the user: an editable Name field in the disk image inspector, a "Mount
# as ext4 / Mount as NTFS" alert, and two File menu items, one per type. The
# names reached only `validateMountName`, the type only a `logger.info` line,
# and the success log then said `mounted /Volumes/<name>` for a path DA may
# never have used. Validating a value and logging it both count as reading it,
# so a check that a parameter is merely read cannot see any of this.
#
# Reading the mount service and the inspector as text, with comments blanked:
#
#   1. every named parameter of every `func` reaches something other than a
#      validator (`validate…(`) or a log call (`logger.…(`, `logFSKit(`,
#      `addLogEntry(`, `print(`);
#   2. outside the detach functions, no string builds a path as
#      `/Volumes/\(…)`: a mount point is what DA's description reports, never
#      one assembled from a name.
#
# A control appends each defect to a copy of the service and requires both
# checks to name it, and requires a detach function's `/Volumes/\(…)` to pass,
# because a gate that cannot fail is indistinguishable from no gate.
#
# TEXT ONLY. Runs in the ubuntu `Shell scripts` job; it builds nothing.
#
#   bash scripts/tests/mount-uses-what-the-user-chose.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SERVICE="$REPO/DiskJockeyApplication/Services/FSKitMountService.swift"
INSPECTOR="$REPO/DiskJockeyApplication/Views/DiskImageInspectorView.swift"
fails=0
ok()   { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1" >&2; fails=$((fails + 1)); }

for f in "$SERVICE" "$INSPECTOR"; do
    [ -f "$f" ] || { echo "no ${f#"$REPO/"}: this guard has nothing to read" >&2; exit 1; }
done
command -v python3 >/dev/null || { echo "python3 is required to read the Swift sources" >&2; exit 1; }

# check <swift file>...: one line per finding, `dropped <file> <func> <param>`
# or `assumed <file> <func>`, then `checked <funcs> <params>`.
check() {
    python3 - "$@" <<'PY'
import os, re, sys

def views(src):
    r"""Two length-preserving views of `src`: `text` has comments blanked and
    strings kept; `code` also blanks string text but keeps `\( … )`
    interpolations, so a value read only inside one still counts."""
    text, code, i, n = list(src), list(src), 0, len(src)

    def blank(view, a, b):
        for k in range(a, b):
            if view[k] != '\n':
                view[k] = ' '

    def in_code(i, stop_on_paren):
        depth = 0
        while i < n:
            if src.startswith('//', i):
                j = src.find('\n', i)
                j = n if j < 0 else j
                blank(text, i, j); blank(code, i, j); i = j; continue
            if src.startswith('/*', i):
                j = src.find('*/', i + 2)
                j = n if j < 0 else j + 2
                blank(text, i, j); blank(code, i, j); i = j; continue
            m = re.compile(r'(#*)("""|")').match(src, i)
            if m:
                i = in_string(m.end(), len(m.group(1)), m.group(2))
                continue
            if stop_on_paren:
                if src[i] == '(':
                    depth += 1
                elif src[i] == ')':
                    if depth == 0:
                        return i + 1
                    depth -= 1
            i += 1
        return i

    def in_string(i, hashes, quote):
        close, esc = quote + '#' * hashes, '\\' + '#' * hashes
        while i < n:
            if src.startswith(close, i):
                return i + len(close)
            if src.startswith(esc, i):
                k = i + len(esc)
                if k < n and src[k] == '(':
                    i = in_code(k + 1, True)
                    continue
                blank(code, i, k + 1); i = k + 1; continue
            blank(code, i, i + 1); i += 1
        return i

    in_code(0, False)
    return ''.join(text), ''.join(code)

def match(s, i, open_c, close_c):
    depth = 0
    for j in range(i, len(s)):
        if s[j] == open_c:
            depth += 1
        elif s[j] == close_c:
            depth -= 1
            if depth == 0:
                return j
    return -1

def split_top(s):
    s = s.replace('->', '  ')
    parts, depth, start = [], 0, 0
    for j, c in enumerate(s):
        if c in '([<':
            depth += 1
        elif c in ')]>':
            depth -= 1
        elif c == ',' and depth == 0:
            parts.append(s[start:j]); start = j + 1
    parts.append(s[start:])
    return [p for p in (x.strip() for x in parts) if p]

# A call whose arguments do not count as applying a value.
INERT = re.compile(r'\b(?:validate\w*|logger\s*\.\s*\w+|logFSKit|addLogEntry|print)\s*\(')
ASSUMED = re.compile(r'/Volumes/\\\(')

findings, nfuncs, nparams = [], 0, 0
for path in sys.argv[1:]:
    label = os.path.basename(path)
    text, code = views(open(path).read())
    for m in re.finditer(r'\bfunc\s+(\w+)\s*(?:<[^>{]*>)?\s*\(', code):
        name, popen = m.group(1), m.end() - 1
        pclose = match(code, popen, '(', ')')
        bopen = code.find('{', pclose)
        if pclose < 0 or bopen < 0:
            continue
        bclose = match(code, bopen, '{', '}')
        body = list(code[bopen:bclose + 1])
        for c in INERT.finditer(''.join(body)):
            end = match(''.join(body), c.end() - 1, '(', ')')
            for k in range(c.start(), end + 1):
                if body[k] != '\n':
                    body[k] = ' '
        applied = ''.join(body)
        nfuncs += 1
        for p in split_top(code[popen + 1:pclose]):
            names = p.split(':', 1)[0].split()
            if not names or names[-1] == '_':
                continue
            nparams += 1
            if not re.search(r'\b%s\b' % re.escape(names[-1]), applied):
                findings.append('dropped %s %s %s' % (label, name, names[-1]))
        if 'etach' not in name and ASSUMED.search(text[bopen:bclose + 1]):
            findings.append('assumed %s in-%s()' % (label, name))
    # A view's computed properties are not funcs: whatever is outside every
    # func body is checked as one more place.
    outside = list(text)
    for m in re.finditer(r'\bfunc\s+\w+[^{]*\{', code):
        bopen = m.end() - 1
        for k in range(bopen, match(code, bopen, '{', '}') + 1):
            outside[k] = ' '
    if ASSUMED.search(''.join(outside)):
        findings.append('assumed %s outside-any-func' % label)

for f in findings:
    print(f)
print('checked %d %d' % (nfuncs, nparams))
PY
}

report() {
    while read -r kind file what rest; do
        case "$kind" in
            dropped) fail "$file: $what() takes '$rest' and only validates or logs it: the caller's choice never reaches the mount — apply it, or remove it here and from the UI that collects it"; bad=1 ;;
            assumed) fail "$file: $what builds a mount point as /Volumes/\\(…): DA mounts at the volume's own label, so report the path DA's description gives"; bad=1 ;;
        esac
    done <<< "$1"
}

# ------------------------------------------------- the real files
result="$(check "$SERVICE" "$INSPECTOR")"
read -r _ nfuncs nparams <<< "$(printf '%s\n' "$result" | grep '^checked ' | tail -1)"
if [ "${nfuncs:-0}" -lt 10 ]; then
    fail "read only ${nfuncs:-0} func(s): a file moved or its syntax changed, and nothing was checked"
fi
bad=0
report "$result"
[ "$bad" = 0 ] && ok "$nfuncs funcs apply all $nparams named parameters; no mount point is assembled from a name"

# -------------------------------- control: each defect is refused
sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT
cp "$SERVICE" "$sandbox/FSKitMountService.swift"
cat >> "$sandbox/FSKitMountService.swift" <<'SWIFT'

extension FSKitMountService {
    static func controlMount(source: String, chosenName: String, chosenType: String) {
        _ = URL(fileURLWithPath: source)
        try? validateMountName(chosenName)
        logger.info("mount \(chosenType, privacy: .public)")
        print("mounted /Volumes/\(chosenName) from \(source)")
    }
    static func controlDetach(name: String) {
        _ = URL(fileURLWithPath: "/Volumes/\(name)")
    }
}
SWIFT
control="$(check "$sandbox/FSKitMountService.swift")"
for want in "dropped FSKitMountService.swift controlMount chosenName" \
            "dropped FSKitMountService.swift controlMount chosenType" \
            "assumed FSKitMountService.swift in-controlMount()"; do
    if printf '%s\n' "$control" | grep -qxF "$want"; then
        ok "control: '$want' is refused"
    else
        fail "control: '$want' was accepted, so this guard cannot fail on it"
    fi
done
if printf '%s\n' "$control" | grep -qE '^(dropped FSKitMountService.swift control(Detach|Mount source)|assumed FSKitMountService.swift in-controlDetach)'; then
    fail "control: a used parameter or a detach function's own /Volumes path was refused"
else
    ok "control: a parameter that is applied, and a detach path, pass"
fi

if [ "$fails" -eq 0 ]; then
    echo "mount-uses-what-the-user-chose: all checks passed"
else
    echo "mount-uses-what-the-user-chose: $fails check(s) failed" >&2
fi
exit $(( fails > 0 ))
