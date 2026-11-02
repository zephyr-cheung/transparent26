#ifndef T26_CORE_H
#define T26_CORE_H

#include <mach/mach.h>
#include <stdint.h>
#include <sys/types.h>

#define T26_MAX_LAYERS 8
#define T26_HIDDEN_BIT 34

struct t26_layer {
    uint64_t layer;
    uint64_t contents;
    uint64_t flags;
    uint64_t handle;
};

pid_t t26_window_server_pid(void);
int t26_find_layers(task_t task, uint64_t *out, int max, double *secs);
int t26_read_state(task_t task, uint64_t layer, struct t26_layer *out);
int t26_is_backdrop(task_t task, uint64_t layer);
int t26_is_transparent(const struct t26_layer *layer);
int t26_write_state(task_t task, uint64_t layer);

#endif
