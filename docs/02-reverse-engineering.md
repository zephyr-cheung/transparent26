# 02 · Reverse engineering and porting to another macOS

`t26.c` hard-codes a handful of QuartzCore offsets that were measured on
macOS 14.6.1 (23G93), M1. This document is the procedure for re-deriving them on
another release. It is deliberately written around **observations**, not around
"the offsets are X": the values move, the shapes usually do not.

The target is the committed `CA::Render::Layer` used by WindowServer's
compositor, not the mutable `CALayer`/`CA::Layer`.

## 0. Requirements

- Apple Silicon, SIP disabled (`csrutil status`), root for `task_for_pid`.
- Command Line Tools (`clang`, `lldb`, `otool`, `nm`).
- A way to look at QuartzCore. On current macOS it lives in the dyld shared
  cache; `lldb` can resolve its symbols in any process that links it.
- A sacrificial desktop session: the measurement below uses lldb to stop
  WindowServer for ~300 ms. The shipped `t26` does **not** do that.

## 1. Inspect QuartzCore symbols

Build a tiny local process that links QuartzCore, then let `lldb` resolve and
disassemble the private C++ symbols. This never attaches to WindowServer.

```objc
// /tmp/qcprobe.m
#import <QuartzCore/QuartzCore.h>
#include <unistd.h>
int main(void) {
    CALayer *l = [CALayer layer];
    l.name = @"x";
    for (;;) sleep(1);
}
```

```sh
clang -fobjc-arc -framework QuartzCore -framework Foundation -o /tmp/qcprobe /tmp/qcprobe.m
lldb --batch \
  -o 'breakpoint set -n sleep' \
  -o 'process launch --stop-at-entry -- /tmp/qcprobe' \
  -o continue \
  -o 'image lookup -rn "CA::Render::Layer"' \
  -o 'disassemble -n "CA::Render::Layer::set_contents(CA::Render::Object*)"' \
  -o 'disassemble -n "CA::Render::Layer::set_name(CA::Render::String*)"' \
  -o 'disassemble -n "CA::Render::Layer::copy_properties(CA::Render::Layer*, unsigned int)"' \
  -o kill /tmp/qcprobe
```

Useful symbols on 14.6.1:

| symbol | what it tells you |
| --- | --- |
| `CA::Render::Layer::set_contents` | contents field (`+0x60`) |
| `CA::Render::Layer::set_name` | name field (`+0x78`) |
| `CA::Render::Layer::set_handle` | handle field (`+0x90`) |
| `CA::Render::Layer::copy_properties` | flags at `+0x24` and other fields |
| `CA::Render::String::new_string` | String layout: `+0x18` length, `+0x1c` chars, type at `+0x0c` |
| `CA::Render::Handle::set_current_layer` | `Handle + 0x10` = current render layer |
| `CA::OGL::Renderer::alloc_layer` | how the renderer consumes `+0x24` |

The offsets are read from the instructions, not from a header:

- `set_contents`: `ldr x0, [x0, #0x60]` / `str x1, [x0, #0x60]`.
- `set_name`: `ldr/str` at `+0x78`.
- `set_handle`: `ldr/str` at `+0x90`.
- `copy_properties`: `ldur x8, [src, #0x24]` and bit copies from that qword.
- `String::new_string`: allocates `len + 0x20`; writes refcount at `+0x8`,
  type `0x31` at `+0xc`, length at `+0x18`, copies chars to `+0x1c`.

Record the offsets on the new OS. If `set_contents` no longer exists under that
name, search `image lookup -rn "Render::Layer"` and read the constructor/copy
code; the field is the pointer that is ref/unref'd as an object.

## 2. Find the backdrop's committed layer

`SLMenuBarBackdropLayer` is the name string visible in the layer tree. There are
two different objects with that name:

- the mutable `CALayer`'s name attribute: a **CFString** in WindowServer's heap;
- the committed render layer's name: a **`CA::Render::String`**, with the
  characters inline.

The new `t26` scans for the second one. The layout on 14.6.1:

```
CA::Render::String
  +0x00  vtable (PAC-signed)
  +0x08  refcount (u32)
  +0x0c  type (u32) = 0x31
  +0x10  zero
  +0x18  length (u32)
  +0x1c  characters (inline, NUL-terminated)
```

If a hit is at address `c`, the object starts at `c - 0x1c`. Require:

- `type == 0x31` (or the value `new_string` writes on this OS);
- `length == strlen("SLMenuBarBackdropLayer")` (22);
- a sane refcount.

Then find 8-byte words equal to the object address. A word at address `p` is
the render layer's `+0x78` name pointer, so the candidate layer is `p - 0x78`.
Validate:

```
read(layer + 0x78) == string_object
read(layer + 0x60) is 0 or a plausible user pointer
read(layer + 0x90) is 0 or a plausible user pointer
```

The candidate can appear several times because the same name String can be
referenced by caches; deduplicate by layer address. Multiple displays produce
several backdrop layers; apply to all.

If no layer is found, the name may no longer be copied to the render layer. In
that case fall back to the mutable path: find the `CALayer` whose attr 380 name
is the CFString, get `CA::Layer = CALayer + 0x10`, and resolve its current render
layer through `CA::Render::Handle`/`CA::Render::Context` (the old `main` branch
docs/02 §9 and §18.3 describe the CALayer scan; `CA::Render::Handle + 0x10` is
the current render layer). Do not guess a pointer offset without validating it.

## 3. Find the correct hidden flag

`contents = 0` alone is not enough: it removes the image but leaves the backdrop
background, which looks grey. The render layer has a flags qword at `+0x24`; the
backdrop-only hidden flag is one bit in it.

On 14.6.1 the measurement was:

1. Capture a grey state (contents already 0):
   - `+0x24` qword `0xc2900930000f9f11` on two layers, `0xc2900934000f9f11` on one
     already-hidden layer.
2. Use the known-good ObjC setters to make the bar genuinely transparent. The
   old `main` branch has `tools/t26-fast.c` / `bin/t26-fast hide` for exactly
   this; it uses lldb and stops WindowServer ~300 ms. The core expression is:

   ```objc
   ({ void *p[] = { /* backdrop CALayer addresses */ };
      for (int i = 0; i < n; i++) {
          id l = (id)p[i];
          (int)[l setHidden:YES];
          (int)[l setOpacity:0.0];
          (int)[l setContents:nil];
      }
      (int)[CATransaction flush]; 0; })
   ```

3. Dump the render layers again. On every backdrop `+0x24` became
   `0xc2900934...`: **bit 34 set** (the high word changed `0x...30` → `0x...34`).
4. Write `contents=0 | 1<<34` from userspace: transparent bar, text and icons
   intact.

What not to use:

- **bit 32** changed the whole menu bar (text included) on this build. It is a
  wider/root flag, not the backdrop hidden bit. The tool never sets it.
- The byte at `+0x20` also changed (`0xff → 0x00`) between grey and transparent
  states, but writing it alone does not remove the backdrop. It is not the
  opacity control. Do not use it.
- `+0x24` is a **qword**; bit 34 lives in the high 32 bits (at `+0x28`), not in
  the low word. `1ULL << 34`, not `1U << 2`.
- `CA::OGL::Renderer::alloc_layer` reads bit 52 of `+0x24`; that is a different
  renderer flag. Do not assume it is hidden.

On a new OS, do the same before/after diff and find which bit flips on every
backdrop. Test one bit at a time with a throwaway write, and keep a way to clear
it again (the branch's earlier `t26k` tool had `--clear-bit`; in this branch you
can restore by logging out, or add a temporary clear in a local copy).

## 4. Scan calibration and performance

`t26.c` scans only `VM_PROT_READ|VM_PROT_WRITE` regions and skips regions larger
than 1 GiB. Render layers and their name Strings live in WindowServer's heap;
this avoids the dyld shared cache and executable pages.

Chunks are 16 MiB with a 64-byte overlap. A name that crosses a chunk boundary
is still found. The second pass scans 8-byte words for pointers to the String
objects. Both passes use `mach_vm_read_overwrite`; nothing is mapped into the
tool's address space and nothing is stopped.

If the scan is slow or finds nothing, temporarily print each region and the
number of String hits; do not blindly widen the region filter (scanning the
shared cache is much slower).

`task_for_pid` needs SIP disabled. The WindowServer PID is obtained from
`sysctl kern.windowserver_pid`, with `pgrep -x WindowServer` as a fallback.

## 5. The write

`mach_vm_write` writes an aligned 8-byte store:

```c
uint64_t zero = 0;
uint64_t flags = old_flags | (1ULL << 34);
mach_vm_write(task, layer + 0x60, (vm_offset_t)&zero, 8);
mach_vm_write(task, layer + 0x24, (vm_offset_t)&flags, 8);
```

No commit is required: the compositor reads the committed render tree. No thread
state is changed and no code is injected. Do not use a debugger in the shipped
path; the measurement in §3 is the only place lldb is appropriate.

The old contents object is not released. This leaks one material image for the
session, but it keeps the write path free of QuartzCore code. If a future version
requires a refcount-safe write, the setter/`IOMemoryDescriptor`/code-execution
route from `main` history is the alternative, with all its costs.

## 6. Porting checklist

1. `sw_vers`, `uname -m`, `csrutil status`.
2. `lldb` on `/tmp/qcprobe`: disassemble `set_contents`, `set_name`,
   `copy_properties`, `String::new_string`; record the field offsets.
3. Build/run the current `t26`; if it reports `0 backdrop render layer(s)`:
   - dump/inspect the inline name String candidates (type, length, chars);
   - check whether `+0x78` points at that String on a candidate;
   - if the name is not copied, implement the mutable-layer fallback.
4. Use the known-good setters (or old `t26-fast`) to create a transparent state,
   dump the render layer before/after, and find the hidden bit in `+0x24`.
5. Update the `#define`s at the top of `t26.c`:
   - `OFF_CONTENTS`, `OFF_FLAGS`, `OFF_NAME`, `OFF_HANDLE`, `HIDDEN_BIT`;
   - the String type/length/char offset if they moved.
6. Verify: run `sudo t26`; the backdrop disappears, text/icons remain; run again
   after an app switch; log out to restore.
7. If the name or layout changed on a future Liquid Glass release, repeat from
   step 1. Do not assume the 14.6.1 bit 34 is universal.

## 7. Pitfalls seen on this project

- The mutable `CALayer.name` is a heap **CFString**; its address changes on every
  WindowServer launch. Compare characters, never a hard-coded pointer.
- arm64e object isa pointers are PAC-signed. The render-layer scan does not need
  the isa, but any CALayer scan must mask `0x0000000FFFFFFFF8`.
- `CA::Layer + 0x90` is the **cached** contents used by `-contents`; the
  canonical contents lives in `CA::Layer::State` (`writable_state() + 0x68`).
  Poking the cached field does not queue a commit and is not used here.
- `contents=0` looks like a colour change (grey), not transparency. The hidden
  bit is required.
- Bit 32 hides the entire bar. Bit 34 is the backdrop-only hidden flag on
  14.6.1.
- A render layer can be replaced on a menu bar rebuild (app switch, wallpaper,
  display change). Rerun `sudo t26`.
- The tool is state-less: no `disable`, no saved original contents. Undo is log
  out / restart WindowServer.
- Do not turn this userspace write into a kext just to avoid lldb: the earlier
  kext experiment used an unsafe physical-page write and panicked the machine
  with `os_refcnt: attempted resurrection`. The render-tree write needs no
  kernel code.
