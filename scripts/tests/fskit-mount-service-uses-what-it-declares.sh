#!/usr/bin/env bash
#
# fskit-mount-service-uses-what-it-declares.sh — FSKitMountService.swift
# declares nothing it does not use (diskjockey#288).
#
# Mounting moved from `mount -F` to `hdiutil attach` plus DiskArbitration, and
# the old path left pieces behind in FSKitMountService that compiled cleanly
# and did nothing. The one that matters is a parameter: `attach(imagePath:
# name:fsType:mountOptions:)` documented `mountOptions` as the partition
# slicing options (`partition_offset=N,partition_length=M,container=K`)
# "passed verbatim to mount(8)", and its body never read it. A caller that
# passed them got the whole device mounted, with no error. Beside it sat two
# error cases nothing threw (`authorizationDenied`, for an administrator
# prompt the app no longer shows, and `mountPointInUse`) and a process helper,
# `run(executable:arguments:)`, that nothing called and that set an unread
# stdout pipe, the deadlock ProcessRunner exists to avoid.
#
# The compiler says nothing about any of these: an unread parameter, an
# unthrown case and an uncalled static func are all legal Swift. So, reading
# the file as text, with comments and string contents blanked out but string
# interpolations kept:
#
#   1. every named parameter of every `func` is read in that func's body;
#   2. every `func` is called somewhere in the Swift sources, matched by its
#      name and its first argument label, so `process.run()` does not count as
#      a call of `run(executable:arguments:)`;
#   3. every case of every error enum the file declares is constructed
#      somewhere, as `<Enum>.<case>` or as `throw .<case>`.
#
# A control then appends one of each defect to a copy of the file and requires
# all three checks to name it, because a gate that cannot fail is
# indistinguishable from no gate.
#
# TEXT ONLY. Runs in the ubuntu `Shell scripts` job; it builds nothing.
#
#   bash scripts/tests/fskit-mount-service-uses-what-it-declares.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TARGET="$REPO/DiskJockeyApplication/Services/FSKitMountService.swift"
fails=0
ok()   { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1" >&2; fails=$((fails + 1)); }

[ -f "$TARGET" ] || { echo "no ${TARGET#"$REPO/"}: this guard has nothing to read" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 is required to read the Swift sources" >&2; exit 1; }

# Every Swift file in the checkout except build output and vendored trees.
others_list() {
    find "$REPO" \( -name .build -o -name build -o -name DerivedData -o -name tmp \
                    -o -name lib -o -name .git \) -prune -o -name '*.swift' -print |
        grep -vxF "$TARGET" | sort
}

# check <target file> [other swift files...]: one line per finding,
# `unread <func> <param>`, `uncalled <func>`, `unthrown <enum>.<case>`, then
# a `checked <funcs> <params> <cases>` line. The target is also searched for
# calls and constructions.
check() {
    python3 - "$@" <<'PY'
import re, sys

def mask(src):
    r"""Blank comments and string-literal text; keep `\( ... )` interpolations
    so a parameter read only inside one still counts as read."""
    out, i, n = [], 0, len(src)

    def code(i, stop_on_paren):
        depth = 0
        while i < n:
            c = src[i]
            if src.startswith('//', i):
                j = src.find('\n', i)
                j = n if j < 0 else j
                out.append(' ' * (j - i)); i = j; continue
            if src.startswith('/*', i):
                j = src.find('*/', i + 2)
                j = n if j < 0 else j + 2
                out.append(re.sub(r'[^\n]', ' ', src[i:j])); i = j; continue
            m = re.compile(r'(#*)("""|")').match(src, i)
            if m:
                i = string(m.end(), len(m.group(1)), m.group(2))
                continue
            if stop_on_paren:
                if c == '(':
                    depth += 1
                elif c == ')':
                    if depth == 0:
                        out.append(c); return i + 1
                    depth -= 1
            out.append(c); i += 1
        return i

    def string(i, hashes, quote):
        out.append(" " * (hashes + len(quote)))
        close = quote + '#' * hashes
        esc = '\\' + '#' * hashes
        while i < n:
            if src.startswith(close, i):
                out.append(' ' * len(close)); return i + len(close)
            if src.startswith(esc, i):
                k = i + len(esc)
                if k < n and src[k] == '(':
                    out.append(' ' * len(esc) + '(')
                    return string(code(k + 1, True), hashes, quote)
                out.append(' ' * (len(esc) + 1)); i = k + 1; continue
            out.append('\n' if src[i] == '\n' else ' '); i += 1
        return i

    code(0, False)
    return ''.join(out)

def match(text, i, open_c, close_c):
    depth = 0
    for j in range(i, len(text)):
        if text[j] == open_c:
            depth += 1
        elif text[j] == close_c:
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

target, others = sys.argv[1], sys.argv[2:]
t = mask(open(target).read())
corpus = [t] + [mask(open(p, errors='replace').read()) for p in others]
findings, nfuncs, nparams, ncases = [], 0, 0, 0

for m in re.finditer(r'\bfunc\s+(\w+)\s*(?:<[^>{]*>)?\s*\(', t):
    name, popen = m.group(1), m.end() - 1
    pclose = match(t, popen, '(', ')')
    bopen = t.find('{', pclose)
    if pclose < 0 or bopen < 0:
        continue
    bclose = match(t, bopen, '{', '}')
    body = t[bopen:bclose + 1]
    nfuncs += 1
    first_label = None
    for k, p in enumerate(split_top(t[popen + 1:pclose])):
        names = p.split(':', 1)[0].split()
        if not names:
            continue
        if k == 0:
            first_label = names[0]
        internal = names[-1]
        if internal == '_':
            continue
        nparams += 1
        if not re.search(r'\b%s\b' % re.escape(internal), body):
            findings.append('unread %s %s' % (name, internal))
    if first_label is None:
        call = r'\b%s\s*\(\s*\)' % re.escape(name)
    elif first_label == '_':
        call = r'\b%s\s*\((?!\s*\))' % re.escape(name)
    else:
        call = r'\b%s\s*\(\s*%s\s*:' % (re.escape(name), re.escape(first_label))
    call = r'(?<!func )' + call
    if not any(re.search(call, text) for text in corpus):
        findings.append('uncalled %s' % name)

for m in re.finditer(r'\benum\s+(\w+)\s*:[^{]*\b\w*Error\b[^{]*\{', t):
    enum, bopen = m.group(1), m.end() - 1
    body = t[bopen + 1:match(t, bopen, '{', '}')]
    # Top-level `case` declarations only: drop nested braces (the switch in
    # errorDescription) before looking.
    flat, depth = [], 0
    for c in body:
        if c == '{':
            depth += 1
        elif c == '}':
            depth -= 1
        elif depth == 0:
            flat.append(c)
    for decl in re.finditer(r'^\s*case\s+([^\n]+)', ''.join(flat), re.M):
        for item in split_top(decl.group(1)):
            case = re.match(r'(\w+)', item).group(1)
            ncases += 1
            made = r'\b%s\.%s\b|\bthrow\s+\.%s\b|throwing:\s*\.%s\b' % (
                re.escape(enum), case, case, case)
            if not any(re.search(made, text) for text in corpus):
                findings.append('unthrown %s.%s' % (enum, case))

for f in findings:
    print(f)
print('checked %d %d %d' % (nfuncs, nparams, ncases))
PY
}

others=()
while IFS= read -r f; do others+=("$f"); done < <(others_list)

# ------------------------------------------------- the real file
result="$(check "$TARGET" "${others[@]}")"
summary="$(printf '%s\n' "$result" | grep '^checked ' | tail -1)"
read -r _ nfuncs nparams ncases <<< "${summary:-checked 0 0 0}"
if [ "${nfuncs:-0}" -lt 10 ] || [ "${ncases:-0}" -lt 1 ]; then
    fail "read only ${nfuncs:-0} func(s) and ${ncases:-0} error case(s) in ${TARGET#"$REPO/"}: the file moved or its syntax changed, and nothing was checked"
fi
bad=0
while read -r kind what rest; do
    case "$kind" in
        unread)   fail "$what() never reads its parameter '$rest': a caller's argument is dropped with no error — apply it or remove it from every caller"; bad=1 ;;
        uncalled) fail "$what() is declared in ${TARGET#"$REPO/"} and nothing calls it — remove it"; bad=1 ;;
        unthrown) fail "$what is never thrown — remove the case and its errorDescription"; bad=1 ;;
    esac
done <<< "$result"
[ "$bad" = 0 ] && ok "$nfuncs funcs read all $nparams named parameters and have a caller; all $ncases error cases are thrown"

# -------------------------------- control: each defect is refused
sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT
cp "$TARGET" "$sandbox/FSKitMountService.swift"
cat >> "$sandbox/FSKitMountService.swift" <<'SWIFT'

extension FSKitMountService {
    enum ControlError: LocalizedError { case neverThrownForTheControl }
    static func controlNeverCalled(source: String, droppedForTheControl: String? = nil) -> String {
        return "\(source)"
    }
}
SWIFT
control="$(check "$sandbox/FSKitMountService.swift" "${others[@]}")"
for want in "unread controlNeverCalled droppedForTheControl" \
            "uncalled controlNeverCalled" \
            "unthrown ControlError.neverThrownForTheControl"; do
    if printf '%s\n' "$control" | grep -qxF "$want"; then
        ok "control: '$want' is refused"
    else
        fail "control: '$want' was accepted, so this guard cannot fail on it"
    fi
done
if printf '%s\n' "$control" | grep -qxE 'unread controlNeverCalled source'; then
    fail "control: a parameter read only inside a string interpolation was reported unread"
else
    ok "control: a parameter read inside a string interpolation counts as read"
fi

if [ "$fails" -eq 0 ]; then
    echo "fskit-mount-service-uses-what-it-declares: all checks passed"
else
    echo "fskit-mount-service-uses-what-it-declares: $fails check(s) failed" >&2
fi
exit $(( fails > 0 ))
