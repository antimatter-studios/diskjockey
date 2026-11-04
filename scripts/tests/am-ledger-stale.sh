#!/usr/bin/env bash
#
# am-ledger-stale.sh — a claim's age is measured in UTC, and a row that
# cannot be dated is reported rather than skipped (diskjockey#132).
#
# The ledger writes `updated` in UTC (`date -u +%Y-%m-%dT%H:%M:%SZ`), but
# `to_epoch` parsed it with BSD `date -j -f`, which reads the digits as
# LOCAL time and ignores the literal Z. In CEST every live claim aged by
# two hours and `stale` listed agents mid-task as stalled. The GNU fallback
# `date -d` does not exist on macOS, so an unparseable timestamp became 0
# and `[ "$ts" -gt 0 ] || continue` dropped the row silently.
#
# Linux's `date` parses the Z correctly, so a Linux run could never show
# the defect. The BSD behaviour measured in the issue is reproduced by a
# `date` stub on PATH: `-j -f` parses in the local zone ignoring Z, and
# `-d` is an illegal option. The real `date` is checked too.
#
#   bash scripts/tests/am-ledger-stale.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LEDGER_BIN="$REPO/scripts/am-ledger"
fails=0
sandbox="$(mktemp -d)"
trap 'rm -r "$sandbox"' EXIT
export AM_LEDGER_DIR="$sandbox"
unset AM_LEDGER_PROJECT
REAL_DATE="$(command -v date)"

ok()   { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }

# The BSD `date` of the issue, as measured there.
mkdir -p "$sandbox/bsd"
cat > "$sandbox/bsd/date" <<STUB
#!/usr/bin/env bash
for a in "\$@"; do [ "\$a" = "-d" ] && { echo "date: illegal option -- d" >&2; exit 1; }; done
if [ "\${1:-}" = "-j" ] || { [ "\${1:-}" = "-u" ] && [ "\${2:-}" = "-j" ]; }; then
    utc=0; [ "\$1" = "-u" ] && { utc=1; shift; }
    shift; [ "\$1" = "-f" ] && shift 2
    input="\$1"; shift
    # -j -f parses in the LOCAL zone and ignores a literal Z; with -u, in UTC.
    python3 - "\$utc" "\$input" "\$@" <<'PY'
from datetime import datetime, timezone
import sys

if sys.argv[3:] != ["+%s"]:
    sys.exit("date stub: only +%s is supported for -j -f")
timestamp = datetime.strptime(sys.argv[2], "%Y-%m-%dT%H:%M:%SZ")
if sys.argv[1] == "1":
    timestamp = timestamp.replace(tzinfo=timezone.utc)
print(int(timestamp.timestamp()))
PY
    exit \$?
fi
exec "$REAL_DATE" "\$@"
STUB
chmod +x "$sandbox/bsd/date"

check_stub() {
    local zone="$1" expected="$2" out
    shift 2
    out="$(TZ="$zone" "$sandbox/bsd/date" "$@" -j -f '%Y-%m-%dT%H:%M:%SZ' '2020-01-01T00:00:00Z' +%s)"
    if [ "$out" = "$expected" ]; then ok "BSD date stub, TZ=$zone $*: epoch $expected"
    else fail "BSD date stub, TZ=$zone $*: expected $expected, got $out"; fi
}
check_stub Europe/Berlin 1577833200
check_stub America/Los_Angeles 1577865600
check_stub Europe/Berlin 1577836800 -u
check_stub America/Los_Angeles 1577836800 -u
if "$sandbox/bsd/date" -d '2020-01-01T00:00:00Z' +%s >/dev/null 2>&1; then
    fail 'BSD date stub accepts GNU -d'
else
    ok 'BSD date stub rejects GNU -d'
fi

ago() {
    python3 - "$(( $("$REAL_DATE" -u +%s) - $1 ))" <<'PY'
from datetime import datetime, timezone
import sys

print(datetime.fromtimestamp(int(sys.argv[1]), timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
}
row() { printf '%s\t%s\t%s\t%s\t-\t-\t%s\t%s\n' "$1" "$2" fixing "$3" "$4" "$5"; }
{
    row repo 1 alive  "$(ago 900)"            "claimed fifteen minutes ago"
    row repo 2 dead   "$(ago 10800)"          "claimed three hours ago"
    row repo 3 odd    "not-a-timestamp"       "a row nobody can date"
} > "$sandbox/issues.tsv"

check_run() {
    local label="$1" out
    out="$2"
    case "$out" in
        *"#1 "*) fail "$label: a claim made fifteen minutes ago is listed as stale" ;;
        *) ok "$label: a fifteen-minute-old claim is not stale" ;;
    esac
    if printf '%s\n' "$out" | grep -qE '#2 .* 3h '; then ok "$label: a three-hour-old claim is listed at 3h"
    else fail "$label: the three-hour-old claim is missing or misdated: $(printf '%s' "$out" | grep '#2' || echo absent)"; fi
    case "$out" in
        *"#3 "*) ok "$label: a row whose timestamp cannot be parsed is listed, not skipped" ;;
        *) fail "$label: a row whose timestamp cannot be parsed was silently dropped" ;;
    esac
}

echo "am-ledger-stale: ages in UTC"
check_run "BSD date, TZ=Europe/Berlin" "$(PATH="$sandbox/bsd:$PATH" TZ=Europe/Berlin "$LEDGER_BIN" stale 2 2>&1)"
check_run "BSD date, TZ=America/Los_Angeles" "$(PATH="$sandbox/bsd:$PATH" TZ=America/Los_Angeles "$LEDGER_BIN" stale 2 2>&1)"
check_run "host date, TZ=Europe/Berlin" "$(TZ=Europe/Berlin "$LEDGER_BIN" stale 2 2>&1)"
check_run "host date, TZ=America/Los_Angeles" "$(TZ=America/Los_Angeles "$LEDGER_BIN" stale 2 2>&1)"

echo
if [ "$fails" = 0 ]; then
    echo "am-ledger-stale: all checks passed"
else
    echo "am-ledger-stale: $fails check(s) failed" >&2
fi
exit "$fails"
