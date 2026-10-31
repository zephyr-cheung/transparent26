# t26 — a fully transparent macOS menu bar

Removes the menu bar's backdrop layer, so the bar becomes fully transparent: text,
icons, clock, status items, pills, the Apple logo and the shadow are **all kept**,
only the frosted panel behind them disappears and the desktop shows through.

The layer is the same one macOS 26 uses to paint Liquid Glass — here it is the
ordinary translucent bar material of an earlier release.

It is done by operating inside WindowServer — lldb breakpoints plus a single
Objective-C expression that clears `hidden` / `opacity` / `contents` / `filters`
on the `*MenuBarBackdrop*` layer, together with its child
(`SLMenuBarEnhancementLayer`). **Nothing is loaded into the process** (so AMFI's
platform-binary rule never comes into play) and **nothing is written to disk**:
log out or reboot and it is gone.

![The menu bar shows the wallpaper through it: text, icons, status items, pills and the shadow are all there, only the glass backdrop is missing](docs/example.png)

macOS 14.6.1 on a MacBook Air M1, right after `sudo t26 settle`. The whole bar
has no backdrop and the wallpaper comes straight through, while the Apple logo,
the `SodaM` / `Window` menus, the status items on the right and the clock are
untouched — the only thing that was neutralised is the glass layer.

```
$ sudo t26 settle
```

```
✓ menu bar backdrop removed — 5.4 s
  hidden         18 layer(s) across 2/2 display(s), 9 repair pass(es)
  debugger       detached, 2 breakpoint(s) disabled — WindowServer runs at full speed
  untouched      text, icons, status items, pills, shadow
  undo           log out or reboot (nothing is persisted)
```

## Install

Command Line Tools are enough (no Xcode), and **SIP has to be disabled**
(`csrutil status` must say disabled: boot into Recovery and run
`csrutil disable`).

```sh
make                 # swiftc builds bin/t26 directly (the SwiftPM shipped with
                     # a CLT-only install cannot link its package manifest, so
                     # there is no Package.swift: make is the build system)
sudo make install    # → /usr/local/bin/t26
                     # → /usr/local/libexec/t26/{t26-engine.sh,ws_hook.py}
```

Commands that need root re-exec themselves through `sudo`, so you do not have to
type it — and your `T26_*` environment is carried across. Use `sudo t26 ...` if
you prefer to be explicit.

## Usage

```sh
t26 settle            recommended: repair, drop the breakpoints, zero overhead
t26 status            what this machine looks like (SIP, displays, last run)
t26 doctor            preflight: what is missing and how to fix it, exit 3 when blocked
t26 logs [-n N] [-f]  read the hook log; -f follows it
t26 abort             escape hatch: hand WindowServer back (writes detach into the control pipe)

sudo t26 agent install  repair again automatically after unlock / display / wallpaper changes
sudo t26 agent status   is the watcher installed and running
sudo t26 fix -s 600   debugging: stay attached, repair every rebuild (costs frames)
sudo t26 tree         dump the live menu bar CALayer tree, change nothing
sudo t26 probe        read-only: print the layer names WindowServer assigns
sudo t26 hunt         read-only: print the render setters the menu bar code calls
sudo t26 theme        read-only: print what CoreUI's theme renderer paints
```

Common options:

```
-s, --seconds N     time budget (settle 40 · fix 900 · tree/probe/theme 25 · hunt 60)
-p, --pattern S     substring of the layer names to neutralise (default MenuBarBackdrop)
    --shallow       only hide, do not clear opacity/contents/filters
    --settle-min N  earliest detach, seconds (default 4)
    --settle-max N  how long to wait for displays to confirm, seconds (default 60)
    --guard N       keep the breakpoints until the bar has been quiet for N seconds
    --fast          one-shot: repair, detach, never steal focus (what the agent runs)
    --strict        exit 3 unless every display confirmed (good for scripts)
    --json          machine-readable output for settle/fix/status/doctor
    --pid N         operate on another process (testing; needs no sudo)
    --log PATH      hook log path (default /tmp/t26hook.log)
```

Exit codes are a contract: `0` fixed · `1` not fixed · `2` usage · `3` blocked
(SIP / privileges / `--strict`) · `4` no WindowServer · `5` engine failure ·
`130` interrupted.

### What `settle` is waiting for

The few seconds while the breakpoints are armed do stutter: every hit stops all
WindowServer threads, and that is the only source of the stutter. `settle` then:

1. repairs the whole bar's backdrop on every pill resize (3 per rebuild);
2. waits until the bar root of **every** display WindowServer reported has been
   repaired at least twice (`2/2 display(s) confirmed`);
3. disables the breakpoints and detaches — from then on there is no debugger on
   WindowServer and it runs at full speed.

Repairing once and letting go does not work: WindowServer resets `hidden` on
every rebuild, and each display rebuilds on its own, so the one that was repaired
first can be painted frosted again after you detach. That makes "every display
confirmed" a hard condition; if `--settle-max` runs out first, the run warns and
ends (that display may still be frosted — give it more time and run again).

### The fix can come back — that is what the agent is for

The repair is written into live `CALayer` objects. On some displays WindowServer
throws the whole bar tree away and builds a new one: that is what happens when an
external display sleeps and wakes, when the display configuration changes, or
when the wallpaper changes (the material is generated again with the new bezel
tint). `settle` cannot outlive that, because the objects it touched are gone.

Two knobs, both about keeping the attached window short:

- `t26 settle --fast` (what the agent runs) attaches, repairs, and detaches as
  soon as every display `t26 status` can see has a repaired bar. It never forces a
  rebuild, so it does not steal focus, and the deep state survives ordinary
  rebuilds, so there is nothing to wait for. Armed window: about a second.
- `t26 settle --guard N` stays armed until the bar has been quiet for N seconds
  after the last repair. Slower to let go, but it also catches a tree that is
  rebuilt *after* the first repair (an external display waking up a moment
  later). Use it when `--fast` misses a display.

Both are opt-in. `t26 agent install` turns `--fast` into a daemon: it watches for
screen unlock, display configuration changes and wallpaper changes, waits two
seconds, runs `t26 settle --fast`, and goes back to sleep. It never holds the debugger while
idle and never runs two settles at once. `sudo t26 agent uninstall` removes it;
`t26 agent run` runs the watcher in the foreground, and `--full` makes it use the
guarded settle instead.

### Do not press Ctrl-C

While lldb is attached, WindowServer is stopped under ptrace, and **SIGINT makes
a batch lldb kill its target** — the target is WindowServer, so the desktop goes
with it.

`t26` has two guards for this: the engine runs in its own process group (so the
terminal's Ctrl-C never reaches lldb) and the CLI ignores SIGINT itself. If a run
really is stuck, open another terminal:

```sh
sudo t26 abort
```

### Undo

Log out or reboot. The only things on disk are temporary files such as
`/tmp/t26hook.log` and `/tmp/t26-ctl`.

## Layout

```
Sources/t26/            the CLI (swiftc, no Xcode dependency)
  main.swift            entry point: dispatch
  CLI.swift             argument parsing, help text
  Commands.swift        reports for settle/fix/tree/... plus status/doctor/logs/abort
  Engine.swift          spawns the engine, streams the log, parses the result
  Log.swift             log → RunSummary (layers / displays confirmed / verdict)
  Layout.swift          locate libexec (T26_LIBEXEC / next to the exe / /usr/local)
  System.swift          sudo re-exec, subprocesses, SIP/display/user probing
  Style.swift           colours, two-column report, exit codes
libexec/t26/
  t26-engine.sh         lldb controller: attach / breakpoints / wait for done / detach
  t26-agent             launchd watcher: unlock / display / wallpaper → settle --guard
  ws_hook.py            lldb Python callbacks: single-expression repair, tree walk, settle verdict
tools/
  ws-symbols.sh         runtime symbol probe (read-only)
  ws-disasm.sh          symbolised disassembly of update_menu_bar_layers and friends
docs/                   reverse-engineering notes (mechanics / addresses and pitfalls / dead ends / performance)
```

## Docs

| File | Contents |
| --- | --- |
| [docs/01-how-it-works.md](docs/01-how-it-works.md) | Mechanics: layer tree, the `resize_one_pill` entry point, why the neutralisation has to be "deep", how `settle` decides |
| [docs/02-reverse-engineering.md](docs/02-reverse-engineering.md) | Reverse-engineering notes: SkyLight addresses, Mach-O layout, lldb batch scripting and expression-JIT pitfalls |
| [docs/03-dead-ends.md](docs/03-dead-ends.md) | Dead ends: alpha override, dylib injection, the `setName:` funnel, the CoreUI renderer |
| [docs/04-performance.md](docs/04-performance.md) | Why it stutters (ptrace stops the process), measurements, why `settle` can let go |

## Verified

- macOS 14.6.1 (Darwin 23.6, Apple Silicon), single and dual display: the glass
  is gone, text and icons are intact, switching windows does not stutter, and
  both displays stay transparent after the debugger detaches.
- The target look is macOS 26's transparent status bar: no glass, the desktop
  shows straight through.
- The repair lives in WindowServer's memory, so it does not survive a reboot, a
  logout, or a rebuild of the bar itself (external display waking up, wallpaper
  change). `t26 agent install` covers the last two.
- The only thing likely to change between macOS versions is the layer name: run
  `sudo t26 tree` to see the real tree and change `--pattern` if needed;
  `t26 doctor` checks the prerequisites first.

## Requirements

macOS on Apple Silicon, Command Line Tools (no Xcode), SIP disabled.
