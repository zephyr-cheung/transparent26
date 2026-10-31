#!/bin/bash
# Symbolised disassembly of the WindowServer menu bar internals (needs root).
#
#   sudo ./tools/ws-disasm.sh
#
# Output: /tmp/t26-ws-disasm.log
set -u
OUT=/tmp/t26-ws-disasm.log
PID=$(pgrep -x WindowServer | head -1)

if [ "$(id -u)" -ne 0 ]; then
  echo "run me with sudo: sudo $0" >&2
  exit 1
fi
[ -z "${PID}" ] && { echo "WindowServer not found" >&2; exit 1; }

echo "WindowServer pid=${PID}; attaching (brief pause)..."
TERM=dumb lldb -p "${PID}" --batch \
  -o 'image list -o -f' \
  -o 'disassemble -n update_menu_bar_layers' \
  -o 'disassemble -n set_menu_bars' \
  -o 'disassemble -n parse_filter_settings' \
  -o 'disassemble -n menu_has_desktop_background' \
  -o 'disassemble -n update_menu_bar_alpha_on_space' \
  -o 'detach' \
  > "${OUT}" 2>&1

echo "log: ${OUT} ($(wc -l < "${OUT}") lines)"
echo
echo "=== SkyLight image slide ==="
grep -E "SkyLight.framework/Versions/A/SkyLight" "${OUT}" | head -2
echo
echo "=== what the menu bar code calls ==="
grep -oE "callq? +0x[0-9a-f]+ ; [A-Za-z_][^\n]*|bl +0x[0-9a-f]+ ; [A-Za-z_][^\n]*" "${OUT}" \
  | sed 's/.*; //' | sort | uniq -c | sort -rn | head -40
