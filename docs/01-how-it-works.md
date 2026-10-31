# 01 · How it works

The goal: take the menu bar's **backdrop layer** off while keeping text, icons,
clock, status items, pills, the Apple logo and the shadow. On this release that
layer paints the plain translucent bar material; on macOS 26 it is the same layer
that paints Liquid Glass. The first attempt used
`SLSSetMenuBarSystemOverrideAlpha(alpha=0)`, which fades the whole bar out — menu
items included — so that route was rejected (see
[03-dead-ends](03-dead-ends.md)).

## The short version

The glass is **one `CALayer` whose name contains `MenuBarBackdrop`**, and it is a
**sibling** of the text / icon / shadow / pill layers, not their parent. Neutralise
that one layer and the glass is gone while everything else stays.

```
root                                   (SLMenuBarOnScreenRootLayer, unnamed)
├─ SLMenuBarBackdropLayer              ← the glass itself (the one to remove)
│    └─ SLMenuBarEnhancementLayer       cf=darkenBlendMode
├─ SLMenuBarAXBackstopLayer   hidden
├─ SLMenuBarFSBackstopLayer   hidden
├─ SLMenuBarSelectionPillContainer  hidden
│    ├─ SLMenuBarPill_1 / _2 / _StatusItem
│         └─ (unnamed) → CUIMenuBarSelectionLayer → Active
│              cf=plusL / brighten
└─ SLMenuBarTextGroupLayer
     ├─ SLMenuBarTextLayer
     ├─ SLMenuBarAppleLogoLayer
     └─ SLMenuBarShadowLayer    fl=(gaussianBlur) cf=vibrantLightSourceOver
```

That dump comes from `sudo t26 tree` against the real WindowServer; it is not a
guess.

## Why a dylib cannot be injected

WindowServer is a platform binary, and AMFI refuses to map any non-Apple image
into it, regardless of SIP:

```
dlopen(...): code signature ... not valid for use in process:
mapping process is a platform binary, but mapped file is not
```

**Debugging, however, is allowed**: lldb may stop the process, read arguments,
run expressions and call real functions. So the whole approach is "breakpoints
plus an expression": not a single line of code is loaded into the process.

## The only entry point: `resize_one_pill`

Every menu bar rebuild ends in `update_menu_bar_layers()`, which calls
`resize_one_pill(...)`. Its third argument (whatever lives in arm64 `x2`) is a
live `CALayer` that sits inside the real menu bar layer tree.

The flow (all of it inside one lldb expression, see below):

1. climb at most 6 `superlayer`s from `x2` to reach the bar's root;
2. walk the root's children (and one level below) and, for every layer whose
   name matches `[name containsString:@"MenuBarBackdrop"]`:
   - `setHidden:YES`
   - `setOpacity:0.0`
   - `setContents:nil`
   - `setFilters:nil`
   - `setBackgroundFilters:nil`
   - plus the same treatment for **its child** (`SLMenuBarEnhancementLayer`,
     `cf=darkenBlendMode`) — on some displays that sublayer still paints the glass
     after the parent has been emptied
3. return `newly hidden * 1000 + already hidden`.

Layers whose names do not match (text, logo, shadow, pill) are not touched at
all.

## Why the neutralisation has to be "deep"

The log evidence: every pass reports `already hidden: 0`, i.e. **WindowServer sets
`hidden` back to `NO` on every rebuild** (the same layer pointer `0x600001b33080`
is hidden over and over). With `hidden` alone, the glass comes back as soon as
the breakpoint is dropped.

But it does *not* reset `opacity=0` / `contents=nil` / `filters=nil`. So:

- `hidden` being reset does not matter: the layer has no content, no filters and
  is fully transparent, so there is nothing to draw;
- therefore the repair can **disable every breakpoint and let the debugger
  exit**, leaving WindowServer at full speed while the bar stays transparent.

That is `settle`, and it is the mode that has been verified to be "no stutter and
stays transparent".

One pitfall, learned the hard way with two displays: `settle` used to let go
after "4 passes and 3 seconds", which left the second display's bar repaired
**once** with nobody watching it, and it came back frosted after the rebuild. The
exit condition is now "**every display root WindowServer has reported was
repaired at least twice**", or `T26_SETTLE_MAX` (60s by default) with a warning.
After that change the two-display test reports `2/2 display(s) confirmed` and both
displays stay transparent once detached.

## Usage

```sh
make && sudo make install   # once

sudo t26 settle             # repair, then let go (recommended)
sudo t26 fix -s 600         # stay attached (debugging, costs frames)
sudo t26 tree               # look at the real layer tree
t26 status                  # what the last run did, and whether it worked
```

`settle` arms the breakpoints and runs a few passes (these seconds stutter, that
is expected), then runs `breakpoint disable` and the script detaches. Zero
overhead from then on.

Modes:

| Mode | What it does |
| --- | --- |
| `settle` | neutralise, then drop the breakpoints — no debugger left (recommended) |
| `fix` | stay attached, repair every rebuild (fallback) |
| `tree` | print the live menu bar layer tree, change nothing |
| `probe` / `hunt` / `theme` | diagnostics only, see [02](02-reverse-engineering.md) |

The CLI is the only supported front end: `-s/--seconds`, `--pattern`,
`--shallow`, `--settle-min`, `--settle-max`, `--pid` and `--log` are translated
into the engine environment below (you can also set those by hand when driving
the engine directly).

Environment: `T26_MODE` `T26_PATTERN` (default `MenuBarBackdrop`) `T26_MAXFIX`
(0 = never stop, the default in `fix`) `T26_MAXHITS` (1000000 in `fix/settle`)
`T26_DEEP` (1 by default; turns deep neutralisation off) `T26_SETTLE_MIN`
(default 4s, earliest detach) `T26_SETTLE_MAX` (default 60s; give up waiting for
every display to confirm and warn) `T26_TREECAP` `T26_LOG` `T26_PID`.

## Why the fix can disappear again

The repair is written into live `CALayer` objects, so it lives exactly as long as
those objects do. Two different things can take it away:

- **a rebuild of the bar** (front app changes, focus, full screen): WindowServer
  resets `hidden` only — `opacity=0` / `contents=nil` / `filters=nil` survive, so
  the bar stays transparent. This is the case `settle` was designed around.
- **a new bar tree**: an external display that sleeps and wakes, a display
  configuration change, or a wallpaper change (the material is regenerated with
  the new bezel tint) can produce fresh layers. Nothing survives that, because
  the objects the repair touched no longer exist. Verified with `t26 tree`: on a
  built-in display the backdrop kept the same pointer and `op=0.00` across a
  wallpaper change (only the enhancement child's compositing filter was
  rewritten, `darken` → `lighten`), while the external display came back with a
  different root and backdrop pointer holding `contents` again.

Three answers, all shipped:

- `t26 settle --fast` — attach, repair, detach as soon as every display the CLI
  can see has a repaired bar (`T26_DISPLAYS`). The deep state survives ordinary
  rebuilds, so there is nothing left to wait for; no forced rebuild means no
  focus stealing. This is the cheapest form: ~1s attached.
- `t26 settle --guard N` — stay armed until the bar has been quiet for N seconds
  after the last repair; catches a tree rebuilt *after* the first repair.
- `t26 agent install` — a launchd watcher that notices unlock / display /
  wallpaper changes and runs `settle --fast` for you (`--full` switches it to the
  guarded form). `RunAtLoad` + `KeepAlive` make it start at boot, and it repairs
  once when a console session appears, so a reboot ends with a transparent bar
  without any manual step.

## Undo

Nothing persistent to clean up:

- to undo after `settle`: log out / reboot (WindowServer restarts and everything
  is back);
- or run `sudo t26 fix -s 5` and set the layer back with `setHidden:NO` by hand —
  not worth it, a reboot is cleaner.

The only files touched are `/tmp/*.log`.

## Safety rules

While lldb is attached, WindowServer is **stopped under ptrace**. **Never Ctrl-C
this process**: SIGINT makes a batch lldb **kill its target**, and the target is
WindowServer. To abort, open another terminal:

```sh
sudo sh -c 'echo "process interrupt" > /tmp/t26-ctl'
sudo sh -c 'echo "process detach"    > /tmp/t26-ctl'
```
