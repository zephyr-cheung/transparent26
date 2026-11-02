# 01 · How `t26` works

This document describes the implementation in `t26.c`. It is the userspace,
`mach_vm` route: no lldb, no ptrace, no kernel extension, and no stop of
WindowServer.

The measured machine is macOS 14.6.1 (Darwin 23.6.0), MacBook Air M1 (`t8103`).
Fields are version-specific; see [02-reverse-engineering.md](02-reverse-engineering.md).

## 1. What the compositor draws

A `CALayer` is the mutable object. At commit time QuartzCore creates a
`CA::Render::Layer` snapshot; WindowServer's compositor reads that snapshot. The
backdrop is just one of those layers.

The mutable layer's setters (`setContents:`, `setHidden:`, …) are not what this
tool uses. It edits the committed render layer directly, so no `CATransaction`
and no commit is needed.

## 2. The two writes

For each backdrop render layer:

```
+0x60  (Ref<CA::Render::Object> contents)      = 0
+0x24  (u64 flags)                            |= 1 << 34
```

Why both:

- `contents = 0` removes the material image. The compositor still draws the
  layer's background/filters, so the bar turns **grey**, not transparent.
- Bit 34 is the backdrop layer's own hidden flag. It suppresses the backdrop
  (background included) while keeping the sibling text/icons/status layers.
- Bit 32 is **not** that flag. Setting it hides the complete menu bar, text
  included. Never use bit 32 for the backdrop.

Measured evidence (14.6.1):

1. `contents=0` only → grey bar.
2. The known-good setters (`hidden=YES`, `opacity=0`, `contents=nil`, flush)
   changed the render layer's `+0x24` high word from `0xc2900930` to
   `0xc2900934` on every backdrop: bit 34.
3. `contents=0 | 1<<34` from userspace → transparent bar, text/icons intact
   (see `docs/example.png`).
4. `1<<32` → the whole bar disappeared; it was cleared afterwards.

`+0x20` is a byte that also changed between the grey and transparent states
(`0xff → 0x00`), but writing it alone does not make the bar transparent. It is
not the opacity control; do not use it.

## 3. Finding the layers

`t26.c` does not enumerate `CALayer` objects. It finds the committed render
layers directly by their name:

1. Scan readable/writable regions of WindowServer's address space for the
   inline characters `SLMenuBarBackdropLayer`.
2. The name is a `CA::Render::String`:
   ```
   +0x00  vtable (PAC-signed)
   +0x08  refcount (u32)
   +0x0c  type (u32, 0x31 for String on this build)
   +0x10  zero
   +0x18  length (u32)
   +0x1c  characters, inline, NUL-terminated
   ```
   For a hit at address `s`, `sobj = s - 0x1c`; require `type == 0x31`,
   `length == 22`, `refcount > 0`.
3. Scan the same regions for 8-byte words equal to `sobj` (the render layer's
   name pointer), and check `candidate = pointer_address - 0x78`:
   ```
   +0x78 == sobj
   +0x60 is 0 or a plausible user pointer (contents)
   +0x90 is 0 or a plausible user pointer (handle)
   ```
4. Deduplicate and return up to 8 layers.

The scan is read-only and uses:

```c
task_for_pid(mach_task_self(), WindowServer_pid, &task);
mach_vm_region(task, ...);                    // enumerate regions
mach_vm_read_overwrite(task, addr, len, ...); // read chunks
```

Only `VM_PROT_READ|VM_PROT_WRITE` regions are scanned. Render layers and their
names live in WindowServer's heap; skipping the shared cache/executable pages
keeps the scan to a few seconds. Chunks are 16 MiB with a 64-byte overlap so a
name string crossing a chunk boundary is still found. A 60-second deadline
prevents a pathological scan from hanging.

## 4. Writing

`mach_vm_write` writes the two 8-byte fields, then `t26` reads them back:

```c
write_mem(task, layer + 0x60, &zero, 8);
write_mem(task, layer + 0x24, &flags, 8);
read_mem(task, layer + 0x60, &contents, 8);
read_mem(task, layer + 0x24, &flags, 8);
```

The writes are single aligned stores. The compositor may read concurrently; a
64-bit aligned store is atomic, so the worst case is that the change appears on
the next frame. No thread is suspended, no transaction is created, and no code
runs inside WindowServer.

No `unref` is performed on the old contents. The original object is leaked for
the lifetime of the WindowServer process; this is intentional. Releasing it
would require running QuartzCore code or knowing the refcount path, and a leaked
backdrop image is harmless for a session.

## 5. Why text and icons survive

The name predicate selects the backdrop layer itself, not the root of the menu
bar tree. Setting its hidden bit (34) hides only that layer's backdrop. The text,
pills, Apple logo and status items are other layers and are untouched.

Bit 32 is a different (wider) flag: on this build it hides the whole menu bar.
That is why the tool never uses it.

## 6. Undo and lifetime

There is no state file and no `disable`. The committed render layer is part of
the running WindowServer process:

- log out, or restart WindowServer, to drop all modifications;
- a menu bar rebuild can replace the render layer, so run `sudo t26` again;
- nothing is persisted to disk, and no kernel extension is involved.

The original contents pointer is not saved, so a future `disable` command would
need either a state file (with the caveat that the layer may be rebuilt) or the
setter path used by the earlier lldb-based implementation (which needs a
debugger or code execution).

## 7. Cost

The scan is the only expensive part: typically 2–5 seconds of CPU in the `t26`
process, reading WindowServer's heap. It is not a freeze: WindowServer keeps
drawing and other processes keep running. The writes themselves are a handful of
bytes.

## 8. Safety boundaries

- The tool needs root and SIP disabled (`task_for_pid` on WindowServer).
- It writes only after validating the name pointer, string header and layer
  shape; a failed read skips the layer rather than guessing.
- It does not use lldb, ptrace, exception ports, `thread_set_state`, or a kext.
- It does not touch mutable `CA::Layer` state, so there is no transaction or
  copy-on-write interaction.
