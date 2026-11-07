#!/usr/bin/env bash
# No closure literal is an arm of a conditional expression in the Swift
# sources.
#
# The FSKit extensions hand the Rust drivers C callbacks, and set the optional
# ones with a conditional:
#
#     coreCfg.write = isWritable ? { ctx, offset, buf, len in ... } : nil
#
# Swift 6.2 accepts that. Swift 6.4 (Xcode 27) refuses it -- "a C function
# pointer can only be formed from a reference to a 'func' or a literal
# closure" -- so the app stopped compiling on Xcode 27 while CI, on Xcode 26,
# stayed green (#580). Assigning the closure inside `if isWritable { ... }`
# compiles on both, and the field is nil when the branch is not taken.
#
# A text guard cannot tell a C function pointer from a Swift closure, so it
# refuses the shape everywhere: an `if` reads as well for either, and the next
# C callback written this way would otherwise be found only by somebody on a
# newer Xcode than CI's.
#
# The scan runs over this repository, then over a sandbox that plants each
# shape, so the guard is shown to fail as well as to pass.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fails=0
ok() { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }

# A closure literal with parameters opening an arm: `? { a, b in` for the
# first, and `? x : { a in` for the second.
params='\{ *[A-Za-z_][A-Za-z0-9_, ]* +in *$'
shape="\\? *$params|\\? [^:]+ : *$params"

# scan <root>: one line per offending site, nothing when there is none.
scan() {
    local root="$1"
    (cd "$root" && git ls-files '*.swift' 2>/dev/null | while IFS= read -r f; do
        grep -nE "$shape" "$f" 2>/dev/null | sed "s|^|$f:|"
    done)
}

found="$(scan "$ROOT")"
if [ -z "$found" ]; then
    ok "no closure literal is an arm of a conditional expression"
else
    while IFS= read -r site; do
        fail "${site%%:*}:$(printf '%s' "$site" | cut -d: -f2) sets a closure through a conditional; assign it inside an if (#580)"
    done <<<"$found"
fi

sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT
(
    cd "$sandbox" && git init -q . &&
    cat > Planted.swift <<'EOF'
cfg.write = isWritable ? { ctx, offset, buf, len in
    return 0
} : nil
cfg.flush = readOnly ? nil : { ctx in
    return 0
}
if isWritable {
    cfg.write = { ctx, offset, buf, len in
        return 0
    }
}
let stats = IOStatsRecorder(label: name, emit: { fields in
})
EOF
    git add -A
) >/dev/null 2>&1
planted="$(scan "$sandbox")"
for want in 'Planted.swift:1:' 'Planted.swift:4:'; do
    if printf '%s\n' "$planted" | grep -qF "$want"; then
        ok "a planted conditional closure is caught: $want"
    else
        fail "a planted conditional closure is not caught: $want"
    fi
done
if printf '%s\n' "$planted" | grep -qE 'Planted\.swift:(8|12):'; then
    fail "the scan reports a closure that is not in a conditional: $(printf '%s\n' "$planted" | grep -E ':(8|12):' | head -1)"
else
    ok "a closure assigned inside an if, or passed as an argument, is not reported"
fi

[ "$fails" -ne 0 ] || echo 'no-conditional-closures: all checks passed'
exit "$((fails > 0))"
