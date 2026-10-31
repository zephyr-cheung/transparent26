#!/bin/bash
# transparent26 · menu bar backdrop surgery inside WindowServer
#
# WindowServer is a platform binary, so AMFI refuses to map any dylib into it
# ("mapped file is not" a platform binary) no matter what SIP says. Debugging is
# allowed, though: this script stops WindowServer under lldb, hooks
# SkyLight`resize_one_pill (its CALayer argument is inside the live menu bar
# layer tree), climbs to the bar's root and neutralises every child whose name
# contains "MenuBarBackdrop". The backdrop is a *sibling* of the text / icon /
# shadow / pill layers, so only the Liquid Glass disappears. Nothing is loaded
# and nothing is written to disk; the change dies with the next WindowServer
# restart (log out / reboot).
#
# usage: sudo tools/ws-layer.sh [settle|fix|tree|probe|hunt|theme] [-s SECONDS]
#        tools/ws-layer.sh --status
#
#   settle  neutralise once, then disable the breakpoints and detach — no
#           debugger left, WindowServer runs at full speed (recommended)
#   fix     stay attached and re-fix on every rebuild (fallback)
#   tree    dump the live menu bar CALayer tree (names, classes, filters)
#   probe   log which layer names WindowServer assigns, change nothing
#   hunt    log every render-layer setter called from the menu bar code
#   theme   log the layers CUICoreThemeRenderer paints (that is the glass)
#
# env: T26_PID     target pid (default: WindowServer)
#      T26_SECS    give up after this many seconds (default 30)
#      T26_PATTERN layer-name substring to act on (default MenuBarBackdrop)
#      T26_MAXFIX  stop after this many neutralised layers (0 = never stop)
#      T26_DEEP    also drop contents/filters/opacity (default 1)
#      T26_LOG     log file (default /tmp/t26hook.log)
#
# docs: docs/01-how-it-works.md  ·  02-reverse-engineering  ·  03-dead-ends
#       04-performance (为什么卡 / 怎么不卡)
#
# SAFETY: while lldb is attached WindowServer is stopped at every hit, so the
# desktop may stutter for a moment. Never Ctrl-C this script — SIGINT makes a
# batch lldb *kill* the target. If it ever seems stuck, open another terminal:
#     sudo sh -c 'echo "process interrupt" > /tmp/t26-ctl'
#     sudo sh -c 'echo "process detach"    > /tmp/t26-ctl'
# which hands WindowServer back without killing it.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT/Tweak/ws_hook.py"
LOG="${T26_LOG:-/tmp/t26hook.log}"
LLDBLOG=/tmp/t26-layer-lldb.log
CTL=/tmp/t26-ctl

MODE=settle
SECS=""
while [ $# -gt 0 ]; do
    case "$1" in
        probe|hunt|theme|tree|fix|settle) MODE="$1" ;;
        -s|--seconds) shift; SECS="${1:-}" ;;
        --status)
            echo "==> hook log: $LOG"
            if [ -f "$LOG" ]; then tail -30 "$LOG"; else
                echo "    (no log yet — run: sudo $0 fix)"; fi
            exit 0 ;;
        -h|--help)
            sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "ws-layer.sh: unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

PID="${T26_PID:-}"
if [ -z "$PID" ]; then
    PID="$(pgrep -x WindowServer | head -1)"
    [ -n "$PID" ] || { echo "ws-layer.sh: WindowServer not found" >&2; exit 1; }
    if [ "$(id -u)" != 0 ]; then
        echo "ws-layer.sh: must run as root to debug WindowServer" >&2
        echo "             try:  sudo $0 $MODE" >&2
        exit 1
    fi
fi

SECS="${SECS:-${T26_SECS:-}}"
[ -n "$SECS" ] || SECS=$([ "$MODE" = probe ] && echo 25 || echo 30)

echo "==> mode $MODE, target pid $PID, up to ${SECS}s"
if [ "$MODE" = probe ]; then
    echo "    nothing is modified; layer names are only logged"
elif [ "$MODE" = hunt ]; then
    echo "    nothing is modified; menu-bar layer setters are only logged"
elif [ "$MODE" = theme ]; then
    echo "    nothing is modified; the layers CoreUI paints are only logged"
elif [ "$MODE" = settle ]; then
    echo "    the backdrop is emptied out (hidden, no contents, no filters, no"
    echo "    opacity), then the breakpoints are disabled and the debugger lets"
    echo "    go, so WindowServer runs at full speed. Watch the bar afterwards:"
    echo "    if the glass returns, WindowServer repaints it on every rebuild."
elif [ "$MODE" = tree ]; then
    echo "    nothing is modified; the menu bar CALayer tree is only dumped"
else
    echo "    the desktop may stutter for a few seconds while attached."
    echo "    text, icons, status items, pills and the shadow are untouched;"
    echo "    only the backdrop layer is disabled."
    echo "    two lldb expressions per menu bar rebuild: -s 600 is comfortable."
fi
echo "    log: $LOG    lldb: $LLDBLOG"

: >"$LLDBLOG"
rm -f "$CTL"; mkfifo "$CTL"; chmod 600 "$CTL"
# The hook reads these from the environment; lldb inherits what we export here.
export T26_MODE="$MODE"
if { [ "$MODE" = fix ] || [ "$MODE" = settle ]; } && [ -z "${T26_MAXFIX:-}" ]; then
    export T26_MAXFIX=0
fi
export T26_LOG="$LOG"
# hunt mode hits far more breakpoints than the others: be generous, but capped
if [ "$MODE" = hunt ]; then
    export T26_MAXHITS="${T26_MAXHITS:-20000}"
fi
# fix mode runs for minutes: the hit cap must never end the run early
if [ "$MODE" = fix ] || [ "$MODE" = settle ]; then
    export T26_MAXHITS="${T26_MAXHITS:-1000000}"
fi

SEP="t26: == run $(date +%s) $MODE pid $PID"
echo "$SEP ===" >>"$LOG"

# The menu bar stack is rebuilt when the front app changes, so switching to
# Finder forces WindowServer to (re)assign layer names. `open` is used instead
# of AppleScript because it needs no Automation (TCC) permission.
( sleep 3; /usr/bin/open -a Finder >/dev/null 2>&1 ) &

lldb -p "$PID" <"$CTL" >>"$LLDBLOG" 2>&1 &
LLDB=$!
exec 3>"$CTL"   # opening for write unblocks lldb's stdin

send() { printf '%s\n' "$*" >&3; }

send "settings set interpreter.prompt-on-quit false"
send "command script import $HOOK"

# Breakpoints are referenced by name, so the numbering cannot shift if lldb
# splits one name into several locations.
#
# A) the render tree WindowServer builds for the menu bar
# B) CALayer property sets (the "name" attribute id 0x17c)
# C) the menu-bar rebuild itself — logged only, proves it ran
# A and B are the noisy diagnostic pair: every CALayer property set in the
# whole system stops the process. Only arm them when nothing is modified.
if [ "$MODE" = probe ] || [ "$MODE" = hunt ]; then
    send "breakpoint set -n 'CA::Render::Layer::set_name' -N t26render"
    send "breakpoint command add -s python -F ws_hook.on_render_name t26render"
    send "breakpoint modify -G true t26render"

    send "breakpoint set -n 'CA::Layer::setter' -N t26setter"
    send "breakpoint command add -s python -F ws_hook.on_ca_setter t26setter"
    send "breakpoint modify -G true t26setter"
fi

# C fires once per menu bar rebuild. In fix mode it only raises a flag, so the
# expensive work happens once per rebuild instead of once per display.
send "breakpoint set -n 'update_menu_bar_layers' -N t26mb"
send "breakpoint command add -s python -F ws_hook.on_menu_bar_layers t26mb"
send "breakpoint modify -G true t26mb"

# D) everything that can give a layer its frosted-glass look (hunt only: these
#    are extremely hot, they would drown the tree/theme logs)
if [ "$MODE" = hunt ]; then
    send "breakpoint set -n 'CA::Render::Layer::set_background_filters' -N t26bgf"
    send "breakpoint command add -s python -F ws_hook.on_hunt_bg_filters t26bgf"
    send "breakpoint modify -G true t26bgf"
    send "breakpoint set -n 'CA::Render::Layer::set_filters' -N t26flt"
    send "breakpoint command add -s python -F ws_hook.on_hunt_filters t26flt"
    send "breakpoint modify -G true t26flt"
    send "breakpoint set -n 'CA::Render::Layer::set_compositing_filter' -N t26cf"
    send "breakpoint command add -s python -F ws_hook.on_hunt_comp_filter t26cf"
    send "breakpoint modify -G true t26cf"
    send "breakpoint set -n 'CA::Render::Layer::set_subclass' -N t26sub"
    send "breakpoint command add -s python -F ws_hook.on_hunt_subclass t26sub"
    send "breakpoint modify -G true t26sub"
    send "breakpoint set -n 'CA::Render::Layer::set_property_value' -N t26prop"
    send "breakpoint command add -s python -F ws_hook.on_hunt_property t26prop"
    send "breakpoint modify -G true t26prop"
    send "breakpoint set -n 'CA::Render::BackdropGroup::retain_group' -N t26rg"
    send "breakpoint command add -s python -F ws_hook.on_hunt_retain_group t26rg"
    send "breakpoint modify -G true t26rg"
fi

# E) the CoreUI theme renderer that actually paints the menu bar material
if [ "$MODE" = theme ]; then
    send "breakpoint set -n 'objc_msgSend\$updateLayer:key:rendererWork:' -N t26theme"
    send "breakpoint command add -s python -F ws_hook.on_theme_update t26theme"
    send "breakpoint modify -G true t26theme"
fi

# F) the live menu bar CALayer tree, reached from resize_one_pill(..., CALayer*, ...)
if [ "$MODE" = tree ] || [ "$MODE" = fix ] || [ "$MODE" = settle ]; then
    send "breakpoint set -n 'resize_one_pill' -N t26pill"
    send "breakpoint command add -s python -F ws_hook.on_resize_pill t26pill"
    send "breakpoint modify -G true t26pill"
fi

send "breakpoint list"
send "process continue"

# Wait for the hook to finish, or give up after SECS.
end=$((SECS * 2))
for _ in $(seq $end); do
    sleep 0.5
    awk -v s="$SEP" 'index($0,s){f=1} f' "$LOG" 2>/dev/null | grep -q "^t26: done:" && break
done

# Hand WindowServer back: interrupt (it may still be running), then detach,
# retrying until lldb confirms. Only then close stdin so lldb exits by EOF;
# never "quit" while still attached, and never send this script a SIGINT.
send "process interrupt"
sleep 1
detached=no
for _ in 1 2 3 4 5; do
    send "process detach"
    sleep 0.5
    if grep -q "has been detached\|Process .* detached\|exited with status" "$LLDBLOG"; then
        detached=yes
        break
    fi
done
exec 3>&-
wait $LLDB 2>/dev/null
rm -f "$CTL"

echo "==> lldb finished (detach: $detached, session: $LLDBLOG)"
if [ "$detached" = no ]; then
    echo "==> WARNING: lldb may still be attached. Do not kill it; run:"
    echo "    sudo sh -c 'echo \"process detach\" > $CTL'"
fi
pgrep -x WindowServer >/dev/null && echo "==> WindowServer pid $(pgrep -x WindowServer | head -1) alive" \
    || echo "==> WARNING: WindowServer is not running (log out to recover)"
if grep -qE "^error: " "$LLDBLOG"; then
    echo "==> lldb notes:"
    grep -E "^error: " "$LLDBLOG" | grep -v "Process must be launched" |
        head -5 | sed 's/^/    /'
fi

RUNLOG="$(awk -v s="$SEP" 'index($0,s){f=1} f' "$LOG" 2>/dev/null)"

echo "==> hook log ($LOG)"
if [ -f "$LOG" ]; then
    printf '%s\n' "$RUNLOG" | tail -25 | sed 's/^t26: /    /'
else
    echo "    (empty — the breakpoint was never hit)"
fi
matches=$(printf '%s' "$RUNLOG" | grep -c "MATCH" || true)
hunted=$(printf '%s' "$RUNLOG" | grep -c "HUNT " || true)
themed=$(printf '%s' "$RUNLOG" | grep -c "THEME " || true)
trees=$(printf '%s' "$RUNLOG" | grep -c "MENUBAR layer: " || true)
fixed=$(printf '%s' "$RUNLOG" | grep -c "neutralised" || true)

if [ "$fixed" -gt 0 ]; then
    echo
    echo "==> done: $fixed layer(s) neutralised — text, icons and status items"
    echo "    are untouched. Undo: log out or reboot (nothing is persisted)."
elif [ "$trees" -gt 0 ]; then
    echo
    echo "==> $trees menu bar CALayer tree(s) dumped (MENUBAR layer / super / tree)."
    echo "    Nothing was changed — read the names and filters above."
elif [ "$themed" -gt 0 ]; then
    echo
    echo "==> $themed CoreUI-rendered layer(s) logged (lines marked THEME)."
    echo "    Nothing was changed — this was a check of where the glass lives."
elif [ "$hunted" -gt 0 ]; then
    echo
    echo "==> $hunted render-layer setter call(s) came from the menu bar code"
    echo "    (lines marked HUNT). Nothing was changed — this was a hunt."
elif [ "$matches" -gt 0 ]; then
    echo
    echo "==> $matches matching layer name(s) were seen, but nothing was"
    echo "    neutralised — read the MATCH lines above to see which path"
    echo "    WindowServer uses."
elif [ "$MODE" = fix ]; then
    echo
    echo "==> no matching layer name was seen in this run."
    echo "    Click the Apple menu once to force a rebuild, or dump the tree:"
    echo "        sudo $0 tree -s 25"
fi
