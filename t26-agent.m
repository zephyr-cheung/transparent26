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

        post(NOTIFY_REAPPLY);
        [[NSRunLoop currentRunLoop] run];
    }
    return 0;
}
