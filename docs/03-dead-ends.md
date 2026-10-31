# 03 · Dead ends, and why it is not done that way

Rejected approaches in chronological order, with the evidence, so they are not
tried again.

## 1. `SLSSetMenuBarSystemOverrideAlpha` — fades the text out too

```
SLSSetMenuBarSystemOverrideAlpha(cid, display, alpha, flags, animate)
// display 0 = every display; the override is connection scoped and dies with the process
```

With `--alpha 0` the result is not "the glass is gone" but **the whole bar is
gone**: text, icons and menu items fade together. The reason is plain — the API
sets the compositing alpha of the entire menu bar (backdrop + content) and has no
backdrop-only channel. That is what produced the very first "my icons and menus
disappeared" report.

The early Swift client kept this route (no longer shipped) for temporary debugging
only; it is **not** the solution.

## 2. Injecting a dylib — AMFI's platform-binary rule, unrelated to SIP

`t26menuhook.m` + `ws-inject.sh` (verified not to work, removed from the repo) was
the original idea: swizzle `-[CALayer setName:]` and edit the layers from inside
the server process. The result:

```
dlopen(...): code signature ... not valid for use in process:
mapping process is a platform binary, but mapped file is not
```

Rejected even with `csrutil status` disabled, the dylib ad-hoc signed, and both
arm64 and arm64e slices compiled. AMFI's platform-binary rule does not care about
the SIP switch.

Related pitfalls:

- building arm64 only gets you `missing compatible architecture ... need 'arm64e'`
  from dyld;
- building a block IMP inside the target with an lldb expression trips arm64e
  ptrauth: `EXC_BAD_ACCESS ... 0x20000001916c7da0`;
- arm64e test executables built that way are killed by the kernel (`Killed: 9`).

Conclusion: **load no code at all**; only breakpoints plus expressions.

## 3. `SLSTransactionSpaceRebuildMenuBar` — an encoder, not a "rebuild"

The name is tempting, but its first argument is an `SLSTransaction` (it writes
opcode bytes into it). Calling it with a `CGSConnectionID` → `SIGBUS`. The real
way to rebuild the menu bar is to change the front app: the script uses
`open -a Finder` (not `osascript`, to avoid the Automation/TCC prompt).

## 4. `-[CALayer setName:]` / `CA::Layer::setter(attr=0x17c)` — not how it is named

The first observation was that `-[CALayer setName:]` funnels into
`CA::Layer::setter(attr = 0x17c, type = 3)` (0x17c is "name"). The funnel is real,
but **when the menu bar is drawn the names are not assigned there**: both
breakpoints were armed for 25 seconds (including a forced rebuild) and produced
zero menu-bar hits. The names are attached when the layers are created; a rebuild
only changes properties and contents.

So breakpoints A and B survive only in `probe` / `hunt` for diagnostics;
`fix`/`settle` do not arm them (they hit **every** CALayer property set in the
whole system, which is the biggest source of noise).

## 5. The CoreUI theme renderer — 25 seconds, zero hits

`objc_msgSend$updateLayer:key:rendererWork:` (the `theme` mode) is where the glass
is actually painted, and swapping its key would be the most elegant fix. Measured
against the real WindowServer: zero hits in 25 seconds. Dropped.

## 6. Scanning the heap from an expression / static string xrefs — neither works

- walking the heap from an expression looking for `CALayer` instances is far too
  slow (the process stops every time), and touching a deallocated object kills
  WindowServer outright;
- static xrefs to the `SLMenuBar*Layer` strings do not exist (chained fixups);
- `nm -n SkyLight.macho` gives 0 symbols, and nothing references those names
  statically either.

## 7. `-a` for auto-continue / numeric ids for breakpoints

- `breakpoint modify -a` means "append commands", not auto-continue; the right
  flag is `-G true`;
- numeric ids drift as soon as one symbol resolves to several locations; use
  `-N` named breakpoints.

## 8. A durable switch that needs no debugger — there is none

The obvious wish is a preference or an API that makes WindowServer build the bar
without a backdrop, so that nothing has to be repaired ever again.

- `SLSSetMenuBar*` exist (the strings are there: `SLSSetMenuBar: Invalid
  kCGMenuBarFilterKey`, `SLSSetMenuBarDrawingStyle: error setting connection
  property`, `GetActiveMenuBarDrawingStyle`, `SetMenuBarDrawingStyle`) but are
  **not exported**: `nm` on SkyLight shows only `SLSGetDisplayMenubarHeight`,
  `SLSTransactionSystemStatusBarSetLayoutIndex` and
  `SLSTransactionSystemStatusBarResetLayout` for the menu bar. Being able to call
  them still means calling them *from inside* WindowServer, i.e. attach a
  debugger.
- `kSLSMenuBarReduceTransparency` does exist and does remove the translucency —
  by making the bar **opaque**, which is the opposite of what this project wants.
- the drawing style / filter keys are connection or transaction scoped and the
  setters write into the bar's settings, not into a user default that could be
  written once and forgotten;
- patching the code instead of the objects is blocked twice over: SkyLight lives
  in the dyld shared cache (text pages are not writable) and AMFI rejects
  anything that is not a platform binary, exactly as with the dylib attempt.
- the layer-name strings (`SLMenuBarBackdropLayer`, ...) have **no static xref**
  in the extracted image either — a scan for `adrp`+`add` pairs to their page
  finds only the neighbouring strings, and there is no chained-fixups table left
  in the extracted binary. So "hook the code that names the layer" is not
  reachable statically, only at runtime.

Conclusion: the only durable lever is to re-apply the repair after the event,
which is what `--guard` and `t26 agent` do.

## 9. Is `hidden` alone enough? — No

In `fix` mode every pass logs `neutralised 1 layer(s) ... (already hidden: 0)`,
which shows WindowServer sets `hidden` back to `NO` on every rebuild. That is why
`settle` also writes `opacity=0 / contents=nil / filters=nil /
backgroundFilters=nil`: it does not reset those, which is what makes "still
transparent after the debugger let go" possible. See
[01](01-how-it-works.md).
