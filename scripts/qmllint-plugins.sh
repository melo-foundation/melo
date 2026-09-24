#!/usr/bin/env bash
# qmllint over plugin QML. The expected warnings are `Unqualified access` on
# `Plugin` and `MeloUi`, context properties the shell injects that have no QML
# type. Only those are dropped and anything else fails: disabling the whole
# `unqualified` category would hide a Repeater delegate reaching an outer
# `root`, and a count would drift with every new MeloUi call. The self-test
# below stops the script if the filter drops what it should catch.
#
# Usage: scripts/qmllint-plugins.sh                 the example plugins in
#                                                   sidecar/test-fixtures
#        scripts/qmllint-plugins.sh ~/.config/melo  every plugin under
#                                                   <dir>/plugins
set -uo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
lint=$(command -v qmllint-qt6 || command -v qmllint) || {
    echo "qmllint not found (qmllint-qt6 / qmllint)" >&2; exit 127; }

exempt='Plugin|MeloUi'
status=0

# The filter, shared by the real run and the self-test. qmllint usually prints
# diagnostic, source line, caret line, but a syntax error, a failed import or
# the ComponentBehavior hint can print alone. So a diagnostic is dropped only
# when it is an Unqualified access, a caret was seen, and the token under it is
# exempt; anything unrecognised is kept. decide() runs per diagnostic and at END.
filter_prog='
    function decide(   col, tok) {
        if (diag == "") return
        if (diag ~ /Unqualified access/ && src != "" && caret != "") {
            col = index(caret, "^")
            if (col > 0) {
                tok = substr(src, col)
                sub(/[^A-Za-z0-9_].*$/, "", tok)
                if (tok ~ "^(" exempt ")$") { diag = ""; src = ""; caret = ""; return }
            }
        }
        print diag
        diag = ""; src = ""; caret = ""
    }
    /^(Warning|Error|Info|Hint|Note):/ { decide(); diag = $0; next }
    diag != "" && src   == "" { src = $0; next }
    diag != "" && caret == "" { caret = $0; next }
    END { decide() }
'

filter() { awk -v exempt="$exempt" "$filter_prog"; }

# --- self-test ------------------------------------------------------------
# Four cases with known answers; cases 2 and 3 have no caret line.
selftest_fail=0
check() {   # check <name> <expected-kept-count> <input>
    local name=$1 want=$2 got
    got=$(printf '%s' "$3" | filter | grep -c . || true)
    if [ "$got" -ne "$want" ]; then
        printf 'SELF-TEST FAILED: %s — kept %s, expected %s\n' "$name" "$got" "$want" >&2
        selftest_fail=1
    fi
}
check "an exempt unqualified access is dropped" 0 \
'Warning: X.qml:1:9: Unqualified access [unqualified]
    text: MeloUi.player.title
          ^^^^^^
'
check "a caretless diagnostic at EOF is KEPT" 1 \
'Warning: X.qml:9:1: Failed to import QtFoo [import]
'
check "a caretless diagnostic before another one is KEPT" 2 \
'Warning: X.qml:9:1: Failed to import QtFoo [import]
Warning: X.qml:2:16: Expected token `;'"'"' [syntax]
Item { width: 1x }
               ^
'
check "a NON-exempt unqualified access is kept" 1 \
'Warning: X.qml:1:9: Unqualified access [unqualified]
    y: root.titlebarRowOffset
       ^^^^
'
if [ "$selftest_fail" -ne 0 ]; then
    echo "the filter is broken; not reporting on any file" >&2; exit 2
fi
# --------------------------------------------------------------------------

# With no argument, the example plugins docs/plugins.md points authors at.
# With a directory, every plugin under <dir>/plugins, which is the layout of
# melo's config folder.
if [ $# -gt 0 ]; then
    scan_dir="$1/plugins"
else
    scan_dir="$root/sidecar/test-fixtures"
fi
files=()
while IFS= read -r -d '' f; do files+=("$f"); done < <(
    find "$scan_dir" -mindepth 2 -maxdepth 3 -name '*.qml' -print0 2>/dev/null)

# Zero files is not a pass: print the count every time, and report an empty
# run as a no-op rather than "OK".
if [ "${#files[@]}" -eq 0 ]; then
    echo "qmllint-plugins: no plugin QML under $scan_dir — nothing checked."
    echo "  pass the folder that holds plugins/, e.g.:"
    echo "  scripts/qmllint-plugins.sh ~/.config/melo"
    exit 0
fi

echo "qmllint-plugins: checking ${#files[@]} file(s) under $scan_dir"
for f in "${files[@]}"; do
    [ -e "$f" ] || continue
    out=$("$lint" "$f" 2>&1)
    rc=$?
    kept=$(printf '%s\n' "$out" | filter)
    # qmllint exits 0 with nothing to say and 1 when it has warnings. Anything
    # else is the tool failing rather than the file, and must not read as clean.
    if [ "$rc" -ne 0 ] && [ "$rc" -ne 1 ]; then
        printf '%-44s qmllint exited %d\n%s\n' "${f#"$root"/}" "$rc" "$out"
        status=1
        continue
    fi
    n_total=$(printf '%s\n' "$out" | grep -c '^\(Warning\|Error\|Info\|Hint\|Note\):' || true)
    n_kept=$(printf '%s' "$kept" | grep -c . || true)
    printf '%-44s %3d diagnostics, %d after dropping %s\n' \
           "${f#"$root"/}" "$n_total" "$n_kept" "$exempt"
    if [ "$n_kept" -ne 0 ]; then printf '%s\n' "$kept"; status=1; fi
done

[ "$status" -eq 0 ] && echo "OK: ${#files[@]} file(s), no diagnostic outside the injected context properties"
exit "$status"
