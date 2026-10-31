#!/bin/bash
# Dump the WindowServer-side symbols we need to find the menu bar backdrop layer.
# `image dump symtab -f` is not supported by this lldb; `image lookup -rn <regex>` is.
#
#   sudo ./tools/ws-symbols.sh
#
# Output: /tmp/t26-ws-symbols.log
set -u
OUT=/tmp/t26-ws-symbols.log
PID=$(pgrep -x WindowServer | head -1)

if [ "$(id -u)" -ne 0 ]; then
  echo "run me with sudo: sudo $0" >&2
  exit 1
fi
[ -z "${PID}" ] && { echo "WindowServer not found" >&2; exit 1; }

echo "WindowServer pid=${PID}; attaching (brief pause)..."
TERM=dumb lldb -p "${PID}" --batch \
  -o 'image lookup -rn backdrop' \
  -o 'image lookup -rn Backdrop' \
  -o 'image lookup -rn MenuBar' \
  -o 'image lookup -rn menu_bar' \
  -o 'image lookup -rn pill' \
  -o 'expr -l objc++ -O -- (const char *)[[NSClassFromString(@"CABackdropLayer") _shortMethodDescription] UTF8String]' \
  -o 'detach' \
  > "${OUT}" 2>&1

echo "log: ${OUT} ($(wc -l < "${OUT}") lines)"
echo
echo "=== menu bar / backdrop hits ==="
grep -E "Summary: (SkyLight|CoreAnimation|QuartzCore)" "${OUT}" | sed 's/^ *//' | sed 's/Summary: //' | sort -u | head -60
echo
echo "=== CABackdropLayer methods ==="
awk '/CABackdropLayer in/,/^\(lldb\)/' "${OUT}" | head -40
