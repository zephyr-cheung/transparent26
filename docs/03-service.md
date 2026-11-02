# 03 · Optional launchd service

The `t26` command is a one-shot repair. Running it from `sudo` on a timer is
simple but expensive: every run re-attaches to WindowServer and re-scans its heap
(2–5 s of CPU). The optional service keeps the discovery result in memory and
uses GUI events only as wake-ups.

No lldb, no ptrace, no kernel extension.

## Processes

```
t26        one-shot CLI; also installs/removes the service
t26d       root LaunchDaemon; owns the WindowServer task port and layer cache
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

`reapply` means "check the cached layers; write only if a field is wrong".
`rescan` means "the tree may have been replaced; do a full scan".

The daemon also has a 60-second heartbeat that performs a full scan. This is the
safety net for events the agent cannot see (notably some wallpaper changes) and
for a missed notification. It is deliberately not a one-second poll.

## Cache and repair

On startup, or on `rescan`, the daemon:

1. resolves the WindowServer PID and calls `task_for_pid` once;
2. runs the same scan as `t26` (`t26_find_layers` in `t26-core.c`);
3. stores each layer's `layer / contents / flags / handle` in memory.

On `reapply`:

1. verify each cached address still has the
   `SLMenuBarBackdropLayer` name (`t26_is_backdrop`);
2. read `+0x60` and `+0x24`;
3. if `contents == 0 && (flags & (1 << 34))`, do nothing;
4. otherwise call `t26_write_state`, which validates the name again, writes both
   fields, and reads them back.

If a cached layer is unreadable, its name no longer matches, or WindowServer's
PID changed, the cache is dropped and a full scan is scheduled.

Events are debounced for 300 ms and all work runs on a serial utility-QoS
queue, so a burst of notifications becomes one repair. Full rescans are also
rate-limited to one per 10 seconds (`MIN_RESCAN_SEC` in `t26d.c`); the cheap
`reapply` path is not limited.

## Why this is cheaper than `sudo t26` on a timer

- no `sudo`/process startup per event;
- the WindowServer task port is held, not re-acquired;
- the full heap scan is skipped when the cached layers are still valid;
- only a few 8-byte reads/writes happen on the common path;
- the daemon sleeps in `dispatch_main()` when nothing happens.

The remaining cost is the 60 s heartbeat full scan, plus a full scan after a
display/lock/wake/wallpaper event. If that is still too much on a slow machine,
raise `HEARTBEAT_SEC` in `t26d.c`.

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

## Known limitation

A cached render layer can remain readable but stop being the on-screen tree after
a rebuild. `reapply` would then see a valid/transparent old layer and do nothing,
while the new visible layer is transparent only after the next `rescan` or the
60 s heartbeat.

If measurements show this happens on ordinary app/Space switches, the next step
is to cache a stable **root/context** (the menu bar's `PKGManagedMenuSpace` /
`CAContext`) and walk the render tree on each event instead of rescanning the
whole heap. That would make the per-event work O(tree), not O(heap). The current
service is the event + cache version; the root/context traversal is the later
optimisation.

## Permissions

- root for the daemon (`task_for_pid` on WindowServer);
- SIP disabled, same as the one-shot command;
- the agent needs no special entitlement; it only posts Darwin notifications;
- no kext approval, no debugger entitlement, no Full Disk Access.
