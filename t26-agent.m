// t26-agent — per-user launchd agent that turns GUI events into Darwin
// notifications for t26d.  It never talks to WindowServer and never scans.
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#include <notify.h>

#define NOTIFY_REAPPLY "com.zephyr.t26.reapply"
#define NOTIFY_RESCAN  "com.zephyr.t26.rescan"

static void post(const char *name) {
    notify_post(name);
}

static void display_changed(CGDirectDisplayID display,
                            CGDisplayChangeSummaryFlags flags,
                            void *user) {
    (void)display;
    (void)user;
    if (flags & (kCGDisplayBeginConfigurationFlag |
                 kCGDisplayAddFlag |
                 kCGDisplayRemoveFlag |
                 kCGDisplaySetModeFlag |
                 kCGDisplayMovedFlag))
        post(NOTIFY_RESCAN);
    else
        post(NOTIFY_REAPPLY);
}

static CGDirectDisplayID seen_displays[8];
static uint32_t seen_display_count = 0;
static int have_display_snapshot = 0;

// CGDisplayRegisterReconfigurationCallback can miss an internal display
// coming online on some builds.  Poll the cheap topology snapshot as a
// fallback; a count/ID change means the menu bar may have a new backdrop.
static void check_display_topology(void) {
    CGDirectDisplayID ids[8] = {0};
    uint32_t n = 0;
    if (CGGetOnlineDisplayList(8, ids, &n) != kCGErrorSuccess) return;

    int changed = 0;
    if (have_display_snapshot) {
        if (n != seen_display_count) {
            changed = 1;
        } else {
            for (uint32_t i = 0; i < n; i++) {
                if (ids[i] != seen_displays[i]) { changed = 1; break; }
            }
        }
    }
    if (changed)
        post(NOTIFY_RESCAN);

    seen_display_count = n;
    for (uint32_t i = 0; i < n && i < 8; i++)
        seen_displays[i] = ids[i];
    have_display_snapshot = 1;
}

static void observe(NSNotificationCenter *nc, NSNotificationName name, const char *note) {
    [nc addObserverForName:name
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *n) {
                    (void)n;
                    post(note);
                }];
}

int main(void) {
    @autoreleasepool {
        NSWorkspace *workspace = [NSWorkspace sharedWorkspace];
        NSNotificationCenter *nc = [workspace notificationCenter];
        NSDistributedNotificationCenter *dc = [NSDistributedNotificationCenter defaultCenter];

        observe(nc, NSWorkspaceDidActivateApplicationNotification, NOTIFY_REAPPLY);
        observe(nc, NSWorkspaceActiveSpaceDidChangeNotification, NOTIFY_REAPPLY);
        observe(nc, NSWorkspaceSessionDidBecomeActiveNotification, NOTIFY_RESCAN);
        observe(nc, NSWorkspaceScreensDidWakeNotification, NOTIFY_RESCAN);
        observe(nc, NSWorkspaceDidWakeNotification, NOTIFY_RESCAN);

        // Wallpaper changes rebuild the menu bar, but AppKit has no public
        // desktop-image notification on this macOS version.  WallpaperAgent
        // posts this legacy distributed notification instead.
        [dc addObserverForName:@"com.apple.desktop"
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *n) {
                        (void)n;
                        post(NOTIFY_RESCAN);
                    }];

        [dc addObserverForName:@"com.apple.screenIsUnlocked"
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *n) {
                        (void)n;
                        post(NOTIFY_RESCAN);
                    }];
        [dc addObserverForName:@"com.apple.screenIsLocked"
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *n) {
                        (void)n;
                        post(NOTIFY_REAPPLY);
                    }];

        CGDisplayRegisterReconfigurationCallback(display_changed, NULL);
        check_display_topology();
        [NSTimer scheduledTimerWithTimeInterval:2.0
                                        repeats:YES
                                          block:^(NSTimer *timer) {
            (void)timer;
            check_display_topology();
        }];

        // Startup is also when a late-created backdrop handle can be missed.
        // A full rescan here is cheap relative to a GUI login and is followed
        // by t26d's verification scans.
        post(NOTIFY_RESCAN);
        [[NSRunLoop currentRunLoop] run];
    }
    return 0;
}
