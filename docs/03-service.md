# 03 · Optional launchd service

The `t26` command is a one-shot repair. Running it from `sudo` on a timer is
simple but expensive: every run re-attaches to WindowServer and re-scans its heap
(2–5 s of CPU). The optional service keeps the discovery result in memory and
uses GUI events only as wake-ups.

No lldb, no ptrace, no kernel extension.

## Processes

```
t26        one-shot CLI; also installs/removes the service
t26d       root LaunchDaemon; owns the WindowServer task port and handle cache
t26-agent  per-user LaunchAgent; sends Darwin notifications on GUI events
```

`t26d` runs as root because `task_for_pid` on WindowServer requires it. The agent
runs in the user's Aqua session, where `NSWorkspace` and distributed
notifications are available. The agent never scans and never writes; it only
posts `com.zephyr.t26.reapply` or `com.zephyr.t26.rescan`.

## Events

| source | notification |
| --- | --- |
| frontmost application change | `reapply` |
| active Space change | `reapply` |
| session became active | `rescan` |
| screens wake / system wake | `rescan` |
| screen unlocked | `rescan` |
| display configuration change | `rescan` |

`reapply` means "check each cached handle's current render layer; write only if a
field is wrong". `rescan` means "the handle tree may have been replaced; do a
full scan".

The daemon also has a 60-second heartbeat, but it is a cheap `reapply`: it reads
the cached handles and their current render layers, and does not scan the heap.
A full scan is reserved for startup, WindowServer restart, an explicit `rescan`,
or an invalid cached handle. This is the safety net for events the agent cannot
see (notably some wallpaper changes) and for a missed notification. It is
deliberately not a one-second poll.

## Cache and repair

On startup, or on `rescan`, the daemon:

1. resolves the WindowServer PID and calls `task_for_pid` once;
2. runs the same layer scan as `t26` (`t26_find_layers` in `t26-core.c`);
3. for every backdrop render layer, reads `+0x90` -> `CA::Render::Handle*`,
   validates the handle type (`0x16`), and stores the unique handle addresses.

The handle is the stable object. Its `+0x10` field is the **current** committed
`CA::Render::Layer`; a rebuild may replace that layer, but the handle normally
survives and simply points at the new one.

On `reapply`, for each cached handle:

1. verify `handle + 0x0c == 0x16` and read `handle + 0x10` into `rl`
   (`t26_handle_current`);
2. verify `rl` still has the `SLMenuBarBackdropLayer` name
   (`t26_is_backdrop`);
3. read `rl + 0x60` and `rl + 0x24`;
4. if `contents == 0 && (flags & (1 << 34))`, do nothing;
5. otherwise call `t26_write_state`, which validates the name again, writes both
   fields, and reads them back.

If a handle is unreadable, its type is no longer `0x16`, or WindowServer's PID
changed, the cache is dropped and a full scan is scheduled. A still-valid handle
whose current layer is temporarily `0` or not a named backdrop is skipped; the
next `reapply` checks it again. This avoids dropping a handle just because the
tree is mid-rebuild.

Events are debounced for 300 ms and all work runs on a serial utility-QoS
queue, so a burst of notifications becomes one repair. Full rescans are also
rate-limited to one per 10 seconds (`MIN_RESCAN_SEC` in `t26d.c`); the cheap
`reapply` path is not limited.

## Why this is cheaper than `sudo t26` on a timer

- no `sudo`/process startup per event;
- the WindowServer task port is held, not re-acquired;
- the full heap scan is skipped while the cached handles are still valid;
- only a few 8-byte reads/writes happen on the common path;
- the daemon sleeps in `dispatch_main()` when nothing happens.

The remaining cost is a full scan on startup, WindowServer restart, or an
explicit `rescan` (display/lock/wake/wallpaper events are rate-limited to one
scan per 10 s). The 60 s heartbeat only reads handles. If even that is too much
on a slow machine, raise `HEARTBEAT_SEC` in `t26d.c`.

## Install / control

```sh
make
sudo make install
sudo t26 service install     # writes the two plists and bootstraps them
sudo t26 service status
sudo t26 service uninstall
```

Files:

```
/Library/LaunchDaemons/com.zephyr.t26d.plist
/Library/LaunchAgents/com.zephyr.t26agent.plist
/usr/local/libexec/t26/t26d
/usr/local/libexec/t26/t26-agent
/var/log/t26d.log
```

The daemon has `RunAtLoad` and `KeepAlive`; `ThrottleInterval` prevents a crash
loop. The agent is limited to `Aqua` sessions. If the agent cannot be bootstrapped
from the current root shell, it loads at the next GUI login.

## Handle validity

The handle cache assumes the `CA::Render::Handle` object outlives individual
render-layer rebuilds. That is what app/Space switches showed in the POC: the
handle address stayed fixed while `handle + 0x10` moved to the new render layer.

The failure mode is handle destruction/reuse (for example after a WindowServer
restart). The daemon checks the handle type before every reapply; if the type is
no longer `0x16`, it drops the cache and does a full scan. A still-valid handle
whose current layer is temporarily `0` or not a named backdrop is skipped until
the next reapply; that does not invalidate the cache.

This is the A3 design: one-time handle discovery, then O(handles) work per event,
not O(heap). It supersedes the earlier `context + 0x20` experiment, which
targeted a CoreUI material-update object rather than the visible render layer.

## Permissions

- root for the daemon (`task_for_pid` on WindowServer);
- SIP disabled, same as the one-shot command;
- the agent needs no special entitlement; it only posts Darwin notifications;
- no kext approval, no debugger entitlement, no Full Disk Access.
