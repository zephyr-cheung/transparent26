// t26 — transparent menu bar through WindowServer's committed render tree.
//
//   sudo t26                         apply now (one-shot)
//   sudo t26 service install         install t26d + t26-agent via launchd
//   sudo t26 service uninstall       remove the service
//        t26 service status          show the launchd state
//
// No lldb, no ptrace, no kernel extension, no process suspension.  The scan and
// the two writes live in t26-core.c; this file is the CLI and service installer.
#include "t26-core.h"

#include <mach/mach.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#define DAEMON_LABEL "com.zephyr.t26d"
#define AGENT_LABEL  "com.zephyr.t26agent"
#define DAEMON_PLIST "/Library/LaunchDaemons/" DAEMON_LABEL ".plist"
#define AGENT_PLIST  "/Library/LaunchAgents/"  AGENT_LABEL  ".plist"
#define DAEMON_PATH  "/usr/local/libexec/t26/t26d"
#define AGENT_PATH   "/usr/local/libexec/t26/t26-agent"

static int one_shot(void) {
    task_t task;
    pid_t pid;
    uint64_t layers[T26_MAX_LAYERS] = {0};
    double secs = 0;
    int n, ok = 0, rc = 1;

    pid = t26_window_server_pid();
    if (pid <= 0) {
        fprintf(stderr, "t26: WindowServer not found\n");
        return 1;
    }
    if (task_for_pid(mach_task_self(), pid, &task) != KERN_SUCCESS) {
        fprintf(stderr, "t26: task_for_pid(%d) failed; SIP must be disabled\n", (int)pid);
        return 1;
    }

    n = t26_find_layers(task, layers, T26_MAX_LAYERS, &secs);
    if (n <= 0) {
        fprintf(stderr, "t26: no SLMenuBarBackdropLayer render layer found\n");
        mach_port_deallocate(mach_task_self(), task);
        return 1;
    }
    if (n > T26_MAX_LAYERS) n = T26_MAX_LAYERS;
    printf("found %d backdrop render layer(s) in %.2fs\n", n, secs);

    for (int i = 0; i < n; i++) {
        struct t26_layer st;
        if (t26_read_state(task, layers[i], &st)) {
            fprintf(stderr, "t26: layer %#llx unreadable, skipped\n",
                    (unsigned long long)layers[i]);
            continue;
        }
        {
            int already = t26_is_transparent(&st);
            printf("  layer %#llx: %s (contents=%#llx flags=%#llx)\n",
                   (unsigned long long)layers[i],
                   already ? "transparent" : "not transparent",
                   (unsigned long long)st.contents, (unsigned long long)st.flags);
            if (already) { ok++; continue; }
        }
        if (t26_write_state(task, layers[i])) {
            fprintf(stderr, "t26: layer %#llx write failed\n",
                    (unsigned long long)layers[i]);
            continue;
        }
        printf("  enabled %#llx\n", (unsigned long long)layers[i]);
        ok++;
    }
    printf("%s: %d/%d layer(s) transparent\n", ok == n ? "ok" : "partial", ok, n);
    if (ok == n) rc = 0;
    mach_port_deallocate(mach_task_self(), task);
    return rc;
}

static int write_text(const char *path, const char *text) {
    FILE *f = fopen(path, "w");
    if (!f) return -1;
    if (fputs(text, f) == EOF) { fclose(f); return -1; }
    fclose(f);
    chmod(path, 0644);
    chown(path, 0, 0);
    return 0;
}

static int run_cmd(const char *fmt, ...) {
    char cmd[2048];
    va_list ap;
    int st;
    va_start(ap, fmt);
    vsnprintf(cmd, sizeof cmd, fmt, ap);
    va_end(ap);
    st = system(cmd);
    if (st == -1) return -1;
    return WIFEXITED(st) ? WEXITSTATUS(st) : -1;
}

static uid_t agent_uid(void) {
    const char *s = getenv("SUDO_UID");
    struct stat st;
    if (s && *s) return (uid_t)strtoul(s, NULL, 10);
    if (stat("/dev/console", &st) == 0 && st.st_uid != 0) return st.st_uid;
    return 0;
}

static const char *daemon_plist_text =
"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
"<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" "
"\"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
"<plist version=\"1.0\">\n"
"<dict>\n"
"  <key>Label</key><string>" DAEMON_LABEL "</string>\n"
"  <key>ProgramArguments</key><array><string>" DAEMON_PATH "</string></array>\n"
"  <key>RunAtLoad</key><true/>\n"
"  <key>KeepAlive</key><true/>\n"
"  <key>ProcessType</key><string>Background</string>\n"
"  <key>Nice</key><integer>10</integer>\n"
"  <key>ThrottleInterval</key><integer>5</integer>\n"
"  <key>StandardOutPath</key><string>/var/log/t26d.log</string>\n"
"  <key>StandardErrorPath</key><string>/var/log/t26d.log</string>\n"
"</dict>\n"
"</plist>\n";

static const char *agent_plist_text =
"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
"<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" "
"\"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
"<plist version=\"1.0\">\n"
"<dict>\n"
"  <key>Label</key><string>" AGENT_LABEL "</string>\n"
"  <key>ProgramArguments</key><array><string>" AGENT_PATH "</string></array>\n"
"  <key>RunAtLoad</key><true/>\n"
"  <key>KeepAlive</key><true/>\n"
"  <key>LimitLoadToSessionType</key><string>Aqua</string>\n"
"  <key>ProcessType</key><string>Background</string>\n"
"</dict>\n"
"</plist>\n";

static int service_install(void) {
    uid_t uid;

    if (access(DAEMON_PATH, X_OK) != 0 || access(AGENT_PATH, X_OK) != 0) {
        fprintf(stderr, "t26: service binaries missing; run 'sudo make install' first\n");
        return 1;
    }
    if (write_text(DAEMON_PLIST, daemon_plist_text) ||
        write_text(AGENT_PLIST, agent_plist_text)) {
        fprintf(stderr, "t26: cannot write launchd plists\n");
        return 1;
    }

    run_cmd("launchctl bootout system/" DAEMON_LABEL " 2>/dev/null");
    if (run_cmd("launchctl bootstrap system " DAEMON_PLIST) != 0)
        fprintf(stderr, "t26: launchctl bootstrap daemon failed\n");
    run_cmd("launchctl enable system/" DAEMON_LABEL);

    uid = agent_uid();
    if (uid != 0) {
        run_cmd("launchctl bootout gui/%u/" AGENT_LABEL " 2>/dev/null", uid);
        if (run_cmd("launchctl bootstrap gui/%u " AGENT_PLIST, uid) != 0)
            fprintf(stderr, "t26: agent will load at next GUI login\n");
        else
            run_cmd("launchctl enable gui/%u/" AGENT_LABEL, uid);
    } else {
        fprintf(stderr, "t26: agent will load at next GUI login\n");
    }

    printf("installed " DAEMON_LABEL " and " AGENT_LABEL "\n");
    printf("log: /var/log/t26d.log\n");
    return 0;
}

static int service_uninstall(void) {
    uid_t uid = agent_uid();
    run_cmd("launchctl bootout system/" DAEMON_LABEL " 2>/dev/null");
    if (uid != 0)
        run_cmd("launchctl bootout gui/%u/" AGENT_LABEL " 2>/dev/null", uid);
    unlink(DAEMON_PLIST);
    unlink(AGENT_PLIST);
    printf("removed " DAEMON_LABEL " and " AGENT_LABEL "\n");
    return 0;
}

static int service_status(void) {
    uid_t uid = agent_uid();
    if (access(DAEMON_PLIST, F_OK) != 0 && access(AGENT_PLIST, F_OK) != 0) {
        printf("not installed\n");
        return 0;
    }
    printf("== " DAEMON_LABEL " ==\n");
    run_cmd("launchctl print system/" DAEMON_LABEL " 2>&1 | head -30");
    if (uid != 0) {
        printf("\n== " AGENT_LABEL " (uid %u) ==\n", uid);
        run_cmd("launchctl print gui/%u/" AGENT_LABEL " 2>&1 | head -30", uid);
    }
    printf("\nlog: /var/log/t26d.log\n");
    return 0;
}

static void usage(const char *argv0) {
    fprintf(stderr,
            "usage: %s                         apply now\n"
            "       %s service install          install launchd daemon + agent\n"
            "       %s service uninstall        remove the service\n"
            "       %s service status           show launchd state\n",
            argv0, argv0, argv0, argv0);
}

int main(int argc, char **argv) {
    if (argc == 1) {
        if (geteuid() != 0) {
            fprintf(stderr, "t26: needs root: sudo %s\n", argv[0]);
            return 3;
        }
        return one_shot();
    }
    if (argc == 3 && strcmp(argv[1], "service") == 0) {
        if (geteuid() != 0) {
            fprintf(stderr, "t26: needs root: sudo %s %s %s\n",
                    argv[0], argv[1], argv[2]);
            return 3;
        }
        if (strcmp(argv[2], "install") == 0) return service_install();
        if (strcmp(argv[2], "uninstall") == 0) return service_uninstall();
        if (strcmp(argv[2], "status") == 0) return service_status();
    }
    usage(argv[0]);
    return 2;
}
