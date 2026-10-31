# 02 · Reverse-engineering notes: the menu bar in SkyLight / WindowServer

Environment: macOS 14.6.1 (Darwin 23.6.0), Apple Silicon (arm64e), `csrutil
status` = disabled, Command Line Tools only (no Xcode). The absolute addresses
below come from **this build**; on a different system they have to be resolved
again (addresses move, function names do not).

## 1. Where static analysis stops

```sh
nm -n /tmp/SkyLight.macho | wc -l      # → 0 (the export table is empty)
```

The menu bar code lives almost entirely in **SkyLight**
(`/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight`, about
5.2 MB); the actual rendering core is CoreAnimation / QuartzCore.
`update_menu_bar_layers` and `resize_one_pill` are **local symbols** that are not
exported, so:

- `nm` finds nothing → they have to be located **at runtime** with
  `image lookup -rn MenuBar` inside lldb;
- the layer name strings in `__cstring` (`SLMenuBarBackdropLayer` and friends)
  have **no static xref**, because chained fixups only fill the pointers in at
  load time. So "find the reference to this string" is a dead end; the real calls
  can only be observed at runtime.

Mach-O layout (this machine):

| Segment | Address / size |
| --- | --- |
| `__TEXT` vmaddr | `0x185c06000` |
| `__text` | starts `0x185c08cac`, size `0x3f1fcc` |
| `__cstring` | starts `0x18602b360`, size `0x32e86`, file offset `4346720` |

Symbols of interest (resolved at runtime, before the ASLR slide):

| Symbol | Address | Note |
| --- | --- | --- |
| `update_menu_bar_layers` | `0x185d00674` | the core of every menu bar rebuild |
| `resize_one_pill` | call sites `0x185d00d84` / `0x185d0130c` / `0x185d0141c` | **the way into the layer tree** |
| `objc_msgSend$updateLayer:key:rendererWork:` | `0x1860a7a40` | CoreUI paints the material here; call sites `0x185c8e400` / `0x185cffb84` / `~0x185d0139c` |
| `objc_msgSend$setHidden:` | `0x1860a5780` | this is what makes the backdrop visible again on every rebuild |
| `_sl_dlopen` | `0x185ffe5f8` | `update_menu_bar_layers` dlopens CoreUI |

## 2. What `update_menu_bar_layers` does

Call graph read off the disassembly (`/tmp/sl.asm`, the body of
`update_menu_bar_layers` is around line 253560 of a 47 MB symbolised
disassembly):

1. `_sl_dlopen("CoreUI")`, then look up `getkCUIWidgetKey`,
   `getkCUIBackdropCompatibleKey`, `getkCUIScaleKey`,
   `getkCUIPresentationStateKey`, `getkCUIBezelTintColor`;
2. build a `CUIDescriptor` dictionary (widget = menu bar, presentation state =
   current appearance, bezel tint = colour sampled from the wallpaper);
3. `objc_msgSend$updateLayer:key:rendererWork:` paints the material into some
   layer;
4. call `resize_one_pill` to place the pills;
5. plus `SLSLogBreak`, `CGXWindowGetOwner`,
   `PKGManagedMenuSpaceWalkMenuBarCompanionWindows` and the like.

In other words: **CoreUI paints the glass, but SkyLight decides which layer is
visible**. We work on the latter, so the former never has to be touched.

## 3. Locating the layers at runtime

```sh
sudo tools/ws-symbols.sh    # image lookup -rn MenuBar / Backdrop / pill
sudo tools/ws-disasm.sh     # disassemble -n update_menu_bar_layers / resize_one_pill
```

Both only attach and modify nothing; they write
`/tmp/t26-ws-{symbols,disasm}.log`.

The signature of `resize_one_pill`, inferred from the disassembly:

```
resize_one_pill(space, ctx, CALayer *pill, CGRect, ...)   // the layer is in x2
```

`x2` points at one of the `SLMenuBarPill_*` layers (or at their container), and
climbing 6 `superlayer`s from there reaches the root. Measured: the climb is never
more than 6, and the root's `superlayer` is nil.

The tree is dumped by plain ObjC reflection (`_walk` in
`libexec/t26/ws_hook.py`): `-[CALayer sublayers]`, `-name`, `-isHidden`,
`-filters`, `-backgroundFilters`, `-compositingFilter`, `-className`.

## 4. The menu bar layer names

They are all **plain `CALayer`s** — there is no `SLMenuBar*Layer` ObjC class in
SkyLight, the names are just strings passed to `setName:` — which is exactly why
they can be manipulated from ObjC:

```
SLMenuBarOnScreenRootLayer        SLMenuBarBackdropLayer
SLMenuBarEnhancementLayer         SLMenuBarAXBackstopLayer
SLMenuBarFSBackstopLayer          SLMenuBarSelectionPillContainer
SLMenuBarPill_1  SLMenuBarPill_2  SLMenuBarPill_StatusItem
SLMenuBarTextGroupLayer           SLMenuBarTextLayer
SLMenuBarAppleLogoLayer           SLMenuBarShadowLayer
```

The strings are present in `__cstring` (`0x18602b360` + offset), but as noted in
§1 they have no static xref, so they can only be observed at runtime.

## 5. lldb batch-scripting pitfalls (all encountered)

- the correct way to import in batch mode is `script import resolve`, followed by
  `script resolve.dump(lldb.debugger, '<addrs>')`;
- **use named breakpoints** (`-N t26pill`), never numeric ids: lldb splits one
  name into several locations and the numbers drift;
- after `-n`, give either the full name or the name without a signature
  (`update_menu_bar_layers`); a signature with the parameter list does not work;
- auto-continue is `breakpoint modify -G true` (not `-a`; `-a` means "append
  commands after the existing ones");
- casting a **void** method call as `(void)[obj setX]` makes lldb report a bogus
  `unknown error` even though the call succeeded; use `(int)[obj setX]` or wrap
  it in `(id)`;
- returning `False` from a Python callback does **not** stop the process (because
  `-G true` auto-continues); to really stop it, use `process interrupt` or
  `breakpoint disable`;
- Python module file names **must not contain dashes** (`ws_hook.py`, not
  `ws-hook.py`);
- **never detach from a Python timer thread**: `lldb.debugger` is `None` there.
  Detaching is the shell's job (FIFO `/tmp/t26-ctl`);
- `SBDebugger` has no `GetNumBreakpoints()`; use
  `GetSelectedTarget().GetNumBreakpoints()`;
- **two expression-JIT pitfalls** (only inside `EvaluateExpression`):
  - reading a `double` return value (e.g. `[(id)p opacity]`) yields garbage
    (`5.26e-315`); read it as `(float)`;
  - comparing a pointer with the literal zero, `[(id)p contents] == 0`, is
    compiled wrongly (`err=False val=None`); write
    `(unsigned long long)[(id)p contents] != 0` instead;
  - in short: the **void setters** (`setHidden:`, `setOpacity:0.0`) are
    reliable, reading values back is not — so do the writes in one expression and
    verify separately.

## 6. Reproducing this on another machine or OS version

1. `sudo tools/ws-symbols.sh` to confirm `update_menu_bar_layers` and
   `resize_one_pill` still exist, and note the new addresses;
2. `sudo t26 tree` to see the layer tree, confirm the backdrop layer name still
   contains `MenuBarBackdrop` and that it is still a sibling of the root's
   children;
3. if the name changed, set `T26_PATTERN=<new name>` and run `settle` again;
4. if the backdrop is no longer a sibling but a parent (with the text inside it),
   `setHidden:YES` would hide the text too — in that case switch to "clear
   contents/filters only, never hide", i.e. `T26_DEEP=0` with `setContents:nil`,
   and verify again.
