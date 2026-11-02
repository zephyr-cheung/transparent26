// t26d — root launchd daemon for t26.
//
// Keeps the WindowServer task port and the backdrop render-layer addresses in
// memory.  GUI events arrive as Darwin notifications from t26-agent; a 60 s
// heartbeat is only a safety net.  It reads the cached layer fields first and
// writes only when they are not in the target state.  A full heap scan happens
// on startup, on WindowServer restart, or when a cached layer is no longer a
// valid backdrop.
#include "t26-core.h"

#include <dispatch/dispatch.h>
#include <mach/mach.h>
#include <notify.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define NOTIFY_REAPPLY "com.zephyr.t26.reapply"
#define NOTIFY_RESCAN  "com.zephyr.t26.rescan"
#define DEBOUNCE_MS    300
#define HEARTBEAT_SEC  60
#define MIN_RESCAN_SEC 10

static task_t ws_task = MACH_PORT_NULL;
static pid_t ws_pid = 0;
static struct t26_layer cache[T26_MAX_LAYERS];
static int cache_n = 0;
static time_t last_scan = 0;
static dispatch_queue_t q;
static int scheduled = 0;
static int pending_rescan = 0;

static void logmsg(const char *fmt, ...) {
    va_list ap;
    fprintf(stderr, "t26d: ");
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
    fflush(stderr);
}

static void schedule(int rescan);

static int ensure_task(void) {
    pid_t pid = t26_window_server_pid();
    if (pid <= 0) return -1;
    if (ws_task != MACH_PORT_NULL && pid == ws_pid) return 0;
    if (ws_task != MACH_PORT_NULL) {
        mach_port_deallocate(mach_task_self(), ws_task);
        ws_task = MACH_PORT_NULL;
    }
    if (task_for_pid(mach_task_self(), pid, &ws_task) != KERN_SUCCESS) {
        ws_task = MACH_PORT_NULL;
        ws_pid = 0;
        return -1;
    }
    ws_pid = pid;
    cache_n = 0;
    logmsg("attached to WindowServer %d", (int)pid);
    return 0;
}

static void scan_and_cache(void) {
    uint64_t layers[T26_MAX_LAYERS] = {0};
    double secs = 0;
    int n = t26_find_layers(ws_task, layers, T26_MAX_LAYERS, &secs);
    if (n < 0) {
        logmsg("scan timed out/failed");
        cache_n = 0;
        return;
    }
    if (n > T26_MAX_LAYERS) n = T26_MAX_LAYERS;
    last_scan = time(NULL);
    cache_n = 0;
    for (int i = 0; i < n; i++) {
        struct t26_layer st;
        if (t26_read_state(ws_task, layers[i], &st) == 0)
            cache[cache_n++] = st;
    }
    logmsg("scan: %d backdrop layer(s) in %.2fs", cache_n, secs);
}

static void apply_now(int rescan) {
    int rebuilt;

    if (ensure_task() != 0) {
        logmsg("WindowServer/task_for_pid not available yet");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5ull * NSEC_PER_SEC), q, ^{
            schedule(1);
        });
        return;
    }

    rebuilt = rescan || cache_n == 0;
    if (!rebuilt) {
        for (int i = 0; i < cache_n; i++) {
            if (!t26_is_backdrop(ws_task, cache[i].layer)) { rebuilt = 1; break; }
        }
    }
    if (rebuilt) {
        time_t now = time(NULL);
        if (last_scan != 0 && now - last_scan < MIN_RESCAN_SEC) {
            int wait = (int)(MIN_RESCAN_SEC - (now - last_scan));
            logmsg("rescan rate-limited; retry in %ds", wait);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)wait * NSEC_PER_SEC), q, ^{
                schedule(1);
            });
            return;
        }
        scan_and_cache();
        if (cache_n == 0) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10ull * NSEC_PER_SEC), q, ^{
                schedule(1);
            });
            return;
        }
    }

    for (int i = 0; i < cache_n; i++) {
        struct t26_layer st;
        if (t26_read_state(ws_task, cache[i].layer, &st)) {
            logmsg("layer %#llx unreadable; rescanning", (unsigned long long)cache[i].layer);
            cache_n = 0;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2ull * NSEC_PER_SEC), q, ^{
                schedule(1);
            });
            return;
        }
        if (t26_is_transparent(&st)) continue;
        if (!t26_is_backdrop(ws_task, cache[i].layer)) {
            logmsg("layer %#llx changed; rescanning", (unsigned long long)cache[i].layer);
            cache_n = 0;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2ull * NSEC_PER_SEC), q, ^{
                schedule(1);
            });
            return;
        }
        if (t26_write_state(ws_task, cache[i].layer) == 0)
            logmsg("enabled %#llx", (unsigned long long)cache[i].layer);
        else
            logmsg("write failed for %#llx", (unsigned long long)cache[i].layer);
    }
}

static void schedule(int rescan) {
    if (rescan) pending_rescan = 1;
    if (scheduled) return;
    scheduled = 1;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)DEBOUNCE_MS * NSEC_PER_MSEC), q, ^{
        int force;
        scheduled = 0;
        force = pending_rescan;
        pending_rescan = 0;
        apply_now(force);
    });
}

int main(void) {
    dispatch_queue_attr_t attr;
    dispatch_source_t timer;
    int tok_reapply = 0, tok_rescan = 0;

    if (geteuid() != 0) {
        logmsg("must run as root");
        return 1;
    }

    attr = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,
                                                   QOS_CLASS_UTILITY, 0);
    q = dispatch_queue_create("com.zephyr.t26d", attr);

    notify_register_dispatch(NOTIFY_REAPPLY, &tok_reapply, q, ^(int token) {
        (void)token;
        schedule(0);
    });
    notify_register_dispatch(NOTIFY_RESCAN, &tok_rescan, q, ^(int token) {
        (void)token;
        schedule(1);
    });

    timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)HEARTBEAT_SEC * NSEC_PER_SEC),
                              (uint64_t)HEARTBEAT_SEC * NSEC_PER_SEC,
                              5ull * NSEC_PER_SEC);
    dispatch_source_set_event_handler(timer, ^{
        schedule(1);
    });
    dispatch_resume(timer);

    logmsg("started");
    dispatch_async(q, ^{
        schedule(1);
    });
    dispatch_main();
    return 0;
}
