// t26 — transparent menu bar through WindowServer's committed render tree.
//
//   sudo t26            remove the menu bar backdrop (keep text/icons)
//
// No lldb, no ptrace, no kernel extension, no process suspension.  The tool
// reads WindowServer's memory (task_for_pid + mach_vm_read_overwrite), finds
// the CA::Render::Layer whose CA::Render::String name is
// "SLMenuBarBackdropLayer", and writes two fields with mach_vm_write:
//
//     CA::Render::Layer + 0x60 = 0                (contents)
//     CA::Render::Layer + 0x24 |= 1 << 34         (hidden/backdrop-only)
//
// Undo is log out / restart WindowServer (there is no disable command).
// Requires root and SIP disabled (task_for_pid on WindowServer).
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <unistd.h>

#define MAX_LAYERS 8
#define NAME "SLMenuBarBackdropLayer"
#define NAME_LEN 22
#define HIDDEN_BIT 34

#define OFF_CONTENTS 0x60
#define OFF_FLAGS    0x24
#define OFF_NAME     0x78
#define OFF_HANDLE   0x90

#define SCAN_DEADLINE 60

static int is_user_ptr(uint64_t p) {
    return p >= 0x100000000ULL && p < 0x800000000000ULL;
}

static int read_mem(task_t task, uint64_t addr, void *buf, size_t len) {
    mach_vm_size_t got = 0;
    kern_return_t kr = mach_vm_read_overwrite(task, addr, len,
                                              (mach_vm_address_t)buf, &got);
    return (kr == KERN_SUCCESS && got == len) ? 0 : -1;
}

static int write_mem(task_t task, uint64_t addr, const void *buf, size_t len) {
    return mach_vm_write(task, addr, (vm_offset_t)buf,
                         (mach_msg_type_number_t)len) == KERN_SUCCESS ? 0 : -1;
}

static pid_t window_server_pid(void) {
    int pid = 0;
    size_t size = sizeof pid;
    if (sysctlbyname("kern.windowserver_pid", &pid, &size, NULL, 0) == 0 && pid)
        return (pid_t)pid;
    FILE *p = popen("pgrep -x WindowServer", "r");
    if (p) {
        if (fscanf(p, "%d", &pid) != 1) pid = 0;
        pclose(p);
    }
    return (pid_t)pid;
}

static const unsigned char *find_sub(const unsigned char *buf, size_t len,
                                     const char *needle, size_t nlen) {
    const unsigned char *p = buf;
    size_t left = len;
    if (nlen == 0 || len < nlen) return NULL;
    while (left >= nlen) {
        const unsigned char *hit = memchr(p, (unsigned char)needle[0],
                                          left - nlen + 1);
        if (!hit) return NULL;
        if (!memcmp(hit, needle, nlen)) return hit;
        left -= (size_t)(hit - p) + 1;
        p = hit + 1;
    }
    return NULL;
}

// Find committed CA::Render::Layer objects whose +0x78 name is the menu bar
// backdrop.  The name is a CA::Render::String with inline characters at +0x1c;
// find those strings first, then pointers to them.
static int find_render_layers(task_t task, uint64_t *out, int max, double *secs) {
    uint64_t strings[64];
    int nstrings = 0, found = 0;
    const size_t chunk = 16u << 20;
    const size_t overlap = 64;
    unsigned char *buf = malloc(chunk);
    time_t deadline = time(NULL) + SCAN_DEADLINE;
    mach_vm_address_t addr = 0;
    struct timeval tv0, tv1;
    gettimeofday(&tv0, NULL);

    if (!buf) return -1;

    // Pass 1: CA::Render::String("SLMenuBarBackdropLayer").
    while (1) {
        mach_vm_size_t size = 0;
        vm_region_basic_info_data_64_t info;
        mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t object = MACH_PORT_NULL;
        if (time(NULL) > deadline) { free(buf); return -1; }
        if (mach_vm_region(task, &addr, &size, VM_REGION_BASIC_INFO_64,
                           (vm_region_info_t)&info, &count, &object) != KERN_SUCCESS)
            break;
        if ((info.protection & (VM_PROT_READ | VM_PROT_WRITE)) ==
            (VM_PROT_READ | VM_PROT_WRITE) && size <= (1ull << 30)) {
            uint64_t off = 0;
            while (off < size) {
                size_t len = (size_t)((size - off < chunk) ? (size - off) : chunk);
                mach_vm_size_t got = 0;
                if (mach_vm_read_overwrite(task, addr + off, len,
                                           (mach_vm_address_t)buf, &got) == KERN_SUCCESS) {
                    const unsigned char *p = buf;
                    size_t left = (size_t)got;
                    for (;;) {
                        const unsigned char *hit = find_sub(p, left, NAME, NAME_LEN);
                        uint64_t saddr, sobj, hdr[4] = {0};
                        if (!hit) break;
                        saddr = addr + off + (uint64_t)(hit - buf);
                        sobj = saddr - 0x1c;
                        if (is_user_ptr(sobj) && !read_mem(task, sobj, hdr, sizeof hdr)) {
                            uint32_t ref = (uint32_t)hdr[1];
                            uint32_t type = (uint32_t)(hdr[1] >> 32);
                            uint32_t len32 = (uint32_t)hdr[3];
                            if (ref > 0 && type == 0x31 && len32 == NAME_LEN) {
                                int dup = 0;
                                for (int i = 0; i < nstrings; i++)
                                    if (strings[i] == sobj) { dup = 1; break; }
                                if (!dup && nstrings < 64) strings[nstrings++] = sobj;
                            }
                        }
                        {
                            size_t adv = (size_t)(hit - p) + 1;
                            p += adv;
                            left -= adv;
                        }
                    }
                }
                if (len <= overlap) break;
                off += len - overlap;
            }
        }
        addr += size;
    }
    if (nstrings == 0) { free(buf); return 0; }

    // Pass 2: pointers to those strings; render layer = pointer - 0x78.
    addr = 0;
    deadline = time(NULL) + SCAN_DEADLINE;
    while (1) {
        mach_vm_size_t size = 0;
        vm_region_basic_info_data_64_t info;
        mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t object = MACH_PORT_NULL;
        if (time(NULL) > deadline) { free(buf); return -1; }
        if (mach_vm_region(task, &addr, &size, VM_REGION_BASIC_INFO_64,
                           (vm_region_info_t)&info, &count, &object) != KERN_SUCCESS)
            break;
        if ((info.protection & (VM_PROT_READ | VM_PROT_WRITE)) ==
            (VM_PROT_READ | VM_PROT_WRITE) && size <= (1ull << 30)) {
            for (uint64_t off = 0; off < size; off += chunk) {
                size_t len = (size_t)((size - off < chunk) ? (size - off) : chunk);
                mach_vm_size_t got = 0;
                if (mach_vm_read_overwrite(task, addr + off, len,
                                           (mach_vm_address_t)buf, &got) != KERN_SUCCESS)
                    continue;
                for (size_t i = 0; i + 8 <= got; i += 8) {
                    uint64_t v = *(uint64_t *)(buf + i);
                    int is_string = 0;
                    for (int k = 0; k < nstrings; k++)
                        if (strings[k] == v) { is_string = 1; break; }
                    if (!is_string) continue;
                    {
                        uint64_t layer = addr + off + i - OFF_NAME;
                        uint64_t name = 0, contents = 0, handle = 0;
                        if (!is_user_ptr(layer)) continue;
                        if (read_mem(task, layer + OFF_NAME, &name, 8) || name != v) continue;
                        if (read_mem(task, layer + OFF_CONTENTS, &contents, 8)) continue;
                        if (contents && !is_user_ptr(contents)) continue;
                        if (read_mem(task, layer + OFF_HANDLE, &handle, 8)) continue;
                        if (handle && !is_user_ptr(handle)) continue;
                        {
                            int dup = 0;
                            for (int k = 0; k < found; k++)
                                if (out[k] == layer) { dup = 1; break; }
                            if (dup) continue;
                        }
                        if (found < max) out[found] = layer;
                        found++;
                    }
                }
            }
        }
        addr += size;
    }
    free(buf);
    gettimeofday(&tv1, NULL);
    if (secs) *secs = (tv1.tv_sec - tv0.tv_sec) + (tv1.tv_usec - tv0.tv_usec) / 1e6;
    return found;
}

static int enable(task_t task) {
    uint64_t layers[MAX_LAYERS] = {0};
    double secs = 0;
    int n, ok = 0;

    n = find_render_layers(task, layers, MAX_LAYERS, &secs);
    if (n <= 0) {
        fprintf(stderr, "t26: no SLMenuBarBackdropLayer render layer found\n");
        return 1;
    }
    if (n > MAX_LAYERS) n = MAX_LAYERS;
    printf("found %d backdrop render layer(s) in %.2fs\n", n, secs);

    for (int i = 0; i < n; i++) {
        uint64_t contents = 0, flags = 0;
        uint64_t zero = 0, nf;
        uint64_t rb_c = 1, rb_f = 0;

        if (read_mem(task, layers[i] + OFF_CONTENTS, &contents, 8) ||
            read_mem(task, layers[i] + OFF_FLAGS, &flags, 8)) {
            fprintf(stderr, "t26: layer %#llx unreadable, skipped\n",
                    (unsigned long long)layers[i]);
            continue;
        }
        if (contents == 0 && (flags & (1ULL << HIDDEN_BIT)))
            fprintf(stderr, "t26: warning: layer %#llx is already transparent\n",
                    (unsigned long long)layers[i]);

        nf = flags | (1ULL << HIDDEN_BIT);
        if (write_mem(task, layers[i] + OFF_CONTENTS, &zero, 8) ||
            write_mem(task, layers[i] + OFF_FLAGS, &nf, 8) ||
            read_mem(task, layers[i] + OFF_CONTENTS, &rb_c, 8) ||
            read_mem(task, layers[i] + OFF_FLAGS, &rb_f, 8)) {
            fprintf(stderr, "t26: layer %#llx write failed\n",
                    (unsigned long long)layers[i]);
            continue;
        }
        if (rb_c != 0 || !(rb_f & (1ULL << HIDDEN_BIT))) {
            fprintf(stderr, "t26: layer %#llx readback mismatch\n",
                    (unsigned long long)layers[i]);
            continue;
        }
        printf("  enabled %#llx\n", (unsigned long long)layers[i]);
        ok++;
    }
    printf("%s: %d/%d layer(s) transparent\n", ok == n ? "ok" : "partial", ok, n);
    return ok == n ? 0 : 1;
}

static void usage(const char *argv0) {
    fprintf(stderr, "usage: %s\n"
                    "  make the menu bar transparent (keeps text/icons)\n"
                    "  undo: log out / restart WindowServer\n", argv0);
}

int main(int argc, char **argv) {
    task_t task;
    pid_t pid;
    int rc;

    if (argc != 1) {
        usage(argv[0]);
        return 2;
    }
    if (geteuid() != 0) {
        fprintf(stderr, "t26: needs root: sudo %s\n", argv[0]);
        return 3;
    }
    pid = window_server_pid();
    if (pid <= 0) {
        fprintf(stderr, "t26: WindowServer not found\n");
        return 1;
    }
    if (task_for_pid(mach_task_self(), pid, &task) != KERN_SUCCESS) {
        fprintf(stderr, "t26: task_for_pid(%d) failed; SIP must be disabled\n", (int)pid);
        return 1;
    }
    rc = enable(task);
    mach_port_deallocate(mach_task_self(), task);
    return rc;
}
