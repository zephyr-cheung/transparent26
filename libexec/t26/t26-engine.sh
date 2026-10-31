#!/bin/bash
# t26-engine — privileged engine behind `t26` (do not run by hand).
#
# WindowServer is a platform binary, so AMFI refuses to map any dylib into it
# ("mapped file is not a platform binary") no matter what SIP says. Debugging is
# allowed, though: this engine stops WindowServer under lldb, hooks
# SkyLight`resize_one_pill (its CALayer argument sits inside the live menu bar
# layer tree), climbs to the bar's root and neutralises every child whose name
# contains "MenuBarBackdrop". The backdrop is a *sibling* of the text / icon /
# shadow / pill layers, so only the backdrop disappears: nothing is loaded
# into WindowServer and nothing is written to disk. The change dies with the
# next WindowServer restart (log out / reboot).
#
# The `t26` CLI is the only supported front end; it validates the options, runs
# the preflight checks, streams this engine's log lines and prints the summary.
# This script therefore expects to be spawned, not typed:
#
#   t26-engine.sh <settle|fix|tree|probe|hunt|theme> -s SECONDS
#
# env: T26_PID         target pid (default: WindowServer)
#      T26_SECS        give up after this many seconds (default 30)
#      T26_PATTERN     layer-name substring to act on (default MenuBarBackdrop)
#      T26_MAXFIX      stop after this many neutralised layers (0 = never stop)
#      T26_DEEP        also drop contents/filters/opacity (default 1)
#      T26_SETTLE_MIN  earliest detach, seconds (default 4)
#      T26_SETTLE_MAX  give up waiting for every display to be confirmed (60)
#      T26_LOG         log file (default /tmp/t26hook.log)
#      T26_QUIET       print nothing on stdout, log only (set by the CLI)
#
# docs: docs/01-how-it-works.md  ·  02-reverse-engineering  ·  03-dead-ends
#       04-performance (why the debugger costs frames, and how settle avoids it)
#
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${T26_HOOK:-$SELF_DIR/ws_hook.py}"
[ -f "$HOOK" ] || { echo "t26-engine: hook not found: $HOOK" >&2; exit 3; }
LOG="${T26_LOG:-/tmp/t26hook.log}"
LLDBLOG=/tmp/t26-layer-lldb.log
CTL=/tmp/t26-ctl

QUIET="${T26_QUIET:-0}"
say() { [ "$QUIET" = 1 ] || printf '%s\n' "$*"; }

MODE=settle
SECS=""
while [ $# -gt 0 ]; do
    case "$1" in
        probe|hunt|theme|tree|fix|settle) MODE="$1" ;;
        -s|--seconds) shift; SECS="${1:-}" ;;
        -h|--help)
            say "t26-engine is an internal helper; use: t26 help"
            exit 0 ;;
        *) echo "t26-engine: unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

PID="${T26_PID:-}"
if [ -z "$PID" ]; then
    PID="$(pgrep -x WindowServer | head -1)"
    [ -n "$PID" ] || { echo "t26-engine: WindowServer not found" >&2; exit 4; }
    if [ "$(id -u)" != 0 ]; then
        echo "t26-engine: must run as root to debug WindowServer" >&2
        echo "            try:  sudo t26 $MODE" >&2
        exit 3
    fi
fi

SECS="${SECS:-${T26_SECS:-}}"
[ -n "$SECS" ] || SECS=$([ "$MODE" = probe ] && echo 25 || echo 30)

say "==> mode $MODE, target pid $PID, up to ${SECS}s"
if [ "$MODE" = probe ]; then
    say "    nothing is modified; layer names are only logged"
elif [ "$MODE" = hunt ]; then
    say "    nothing is modified; menu-bar layer setters are only logged"
elif [ "$MODE" = theme ]; then
    say "    nothing is modified; the layers CoreUI paints are only logged"
elif [ "$MODE" = settle ]; then
    say "    the backdrop is emptied out (hidden, no contents, no filters, no"
    say "    opacity), then the breakpoints are disabled and the debugger lets"
    say "    go, so WindowServer runs at full speed. Watch the bar afterwards:"
    say "    if the glass returns, WindowServer repaints it on every rebuild."
elif [ "$MODE" = tree ]; then
    say "    nothing is modified; the menu bar CALayer tree is only dumped"
else
    say "    the desktop may stutter for a few seconds while attached."
    say "    text, icons, status items, pills and the shadow are untouched;"
    say "    only the backdrop layer is disabled."
    say "    two lldb expressions per menu bar rebuild: -s 600 is comfortable."
fi
say "    log: $LOG    lldb: $LLDBLOG"

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

# A run that never reached a conclusion (time budget used up while still
# waiting for the last display) still needs a verdict in the log: the CLI
# reports on it, and a silent ending looks like a crash.
if ! awk -v s="$SEP" 'index($0,s){f=1} f' "$LOG" 2>/dev/null | grep -q "^t26: done:"; then
    if [ "$MODE" = settle ]; then
        echo "t26: done: timed out after ${SECS}s — the menu bar was not confirmed on every display" >>"$LOG"
    else
        echo "t26: done: timed out after ${SECS}s — the time budget ran out" >>"$LOG"
    fi
fi

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

say "==> lldb finished (detach: $detached, session: $LLDBLOG)"
if [ "$detached" = no ]; then
    say "==> WARNING: lldb may still be attached. Do not kill it; run:"
    say "    sudo sh -c 'echo \"process detach\" > $CTL'"
fi
pgrep -x WindowServer >/dev/null && say "==> WindowServer pid $(pgrep -x WindowServer | head -1) alive" \
    || say "==> WARNING: WindowServer is not running (log out to recover)"
if grep -qE "^error: " "$LLDBLOG"; then
    say "==> lldb notes:"
    grep -E "^error: " "$LLDBLOG" | grep -v "Process must be launched" |
        head -5 | sed 's/^/    /'
fi

# The CLI reads the run block out of the log and prints the summary; the engine
# only has to report a detach that did not happen.
if [ "$detached" = no ]; then
    echo "t26-engine: lldb may still be attached to pid $PID" >&2
    echo "t26-engine: run: sudo t26 abort" >&2
    exit 5
fi
exit 0
