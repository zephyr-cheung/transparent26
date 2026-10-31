# 04 · Why it stutters, and how the stutter was removed

Reported symptom: after the repair the machine felt "really laggy", especially
when **switching windows (focus changes)**.

## The real cause: ptrace stops the process, not a slow expression

A breakpoint stops **the whole of WindowServer** (hundreds of threads:
compositing, rendering, the display link, event dispatch). Every hit means: stop
→ run the Python callback → run the expression → resume, and CoreAnimation's
commits and vsync are pushed back in between. How fast the expression is matters
little; **the number of stops** is what costs.

Measured breakpoint hits per rebuild (from `/tmp/t26hook.log`):

```
settle run: 14 hits / 4 fix pass(es)   → 3.5 per rebuild
fix    run: 22 hits / 6 fix pass(es)   → 3.7 per rebuild
```

A rebuild always costs 1×`update_menu_bar_layers` + 3×`resize_one_pill` (one per
pill, more with two displays). Switching focus always rebuilds the bar (the
active state and every app's menus change), which is why that is the worst case.

## Measurements

Taken on a dummy target (root layer `SLMenuBarOnScreenRootLayer` with Backdrop +
Text children) through the same code path:

| Approach | Time per rebuild |
| --- | --- |
| old multi-eval walker (`_neutralize_tree`, one eval per layer) | **174 ms** |
| one large expression (shallow: `setHidden` only) | **10–11 ms** |
| one large expression (deep: four more setters) | **11–13 ms** |
| real WindowServer, first pass (lldb JITs the expression) | **256–268 ms** |
| real WindowServer, every later pass | **14–31 ms** |

Real numbers from `/tmp/t26hook.log`:

```
fix pass 1: neutralised 1 layer(s) under 0x600001b33080 in 256 ms
fix pass 2: neutralised 1 layer(s) under 0x600001bf3540 in 31 ms
fix pass 3: neutralised 1 layer(s) under 0x600001b33080 in 18 ms
```

The first cut is far slower because lldb has to JIT-compile the expression into
the target process.

## Optimisations that were made

1. **Compress the whole repair into one expression** (`_fix_expr()`): climb to the
   root, scan two levels, match the name, five setters and the count, all in one
   `EvaluateExpression`. Previously it was one eval per layer: 174 ms → 11 ms.
2. **The `update_menu_bar_layers` callback only raises a flag.** It is called
   **per display**, so doing the surgery there would do it twice with two
   displays. The actual pass is triggered by the next `resize_one_pill`, once per
   rebuild.
3. **Removed a duplicated climb.** `_root_of` was already folded into
   `_fix_expr`, but the pill callback still had a "climb 6 superlayers" loop, so
   every hit wasted 6 evals — 18 extra process stops per rebuild. That was one of
   the direct causes of "still laggy"; it is gone.
4. **Skip layers that are already hidden**: the expression runs
   `if (isHidden) m++; else {…}`, so repeated hits do not repeat the setters.
5. **The hit cap no longer stops the process**: it used to be that `hits >=
   MAXHITS` returned `False` → the process stayed stopped on the breakpoint until
   the script timed out (the desktop froze). Now it logs `hit limit … reached —
   still fixing, logging muted` and keeps going; in `fix`/`settle` `MAXHITS` is
   raised to 1,000,000 instead.
6. **Quieter logs**: the first 12 passes log every time, afterwards every 200th;
   `fix`/`settle` no longer arm the diagnostic breakpoints A/B/D/E (they hit every
   CALayer property set in the system).
7. **The actual solution: `settle`.** Once repaired, `breakpoint disable` +
   detach leaves **not a single breakpoint on WindowServer**: zero overhead. That
   is the real reason it stopped stuttering — not faster pauses, but zero pauses.

## Repairing on every pill (while `settle` waits)

Early on, to save stops, only the **first pill of a rebuild** triggered the repair
(a `need_fix` latch). The second display was often missed that way, or
WindowServer repainted the backdrop after the first pill. The current strategy:

- while `settle` waits, **every** `resize_one_pill` runs the repair expression
  (3 per rebuild, 10–30 ms each) — it only lasts the few seconds between "repaired"
  and "let go";
- as soon as the root of every display WindowServer reported has been repaired at
  least twice, the breakpoints are disabled and the debugger detaches, back to
  zero stops;
- `T26_SETTLE_MAX` (60s by default) is the fallback: let go with a WARNING instead
  of keeping the breakpoints armed forever and dragging the machine down.

## What `--guard` costs

`--guard N` keeps the breakpoints armed for N seconds after the last rebuild, so
an unlock burst (bar rebuilt once per display, sometimes twice) is repaired by a
single attachment. The visible cost is the same per-hit stop (~15–30 ms) for the
rebuilds inside that window, plus one attach (~0.5–1 s); after that the debugger
detaches and the cost is zero again. Measured on a dummy target that rebuilds for
4 s and then idles: 8 rebuilds repaired, detach 3 s after the last one, 9.5 s
wall clock for the whole run.

## Why `settle` can let go

WindowServer sets the backdrop's `hidden` back to `NO` on every rebuild, but it
does **not** restore `opacity` / `contents` / `filters` / `backgroundFilters`.
After deep neutralisation the layer has no content, no filters and is fully
transparent, so even when it is made visible it cannot draw glass. That is why the
bar stays transparent with every breakpoint disabled (as reported after the real
test: "everything is fine now, no lag").

## If the glass comes back after `settle` on some future version

That would mean WindowServer on that version repaints `contents` as well. Fall
back to `fix` (stay attached, ~10–30 ms per rebuild), or go further: use a one-off
diagnostic to find the call site that sets the backdrop back to `hidden:NO` (the
return address of `objc_msgSend$setHidden:`) and patch that instruction in memory
— a one-time patch, zero overhead afterwards, gone on reboot.
