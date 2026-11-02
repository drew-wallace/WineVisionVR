#include "frame.h"
#include <assert.h>
#include <stdio.h>
static unsigned calls;
static int engine;
static void frame(void *p) { assert(p == &engine); ++calls; }
int main(void) {
    assert(!dock_frame_poll(NULL));
    struct dock_frame_pump pump = {0};
    assert(!dock_frame_poll(&pump));
    pump.engine = &engine; assert(!dock_frame_poll(&pump));
    pump.frame = frame;
    for (unsigned i = 0; i < 1000; ++i) assert(dock_frame_poll(&pump));
    assert(calls == 1000 && pump.ticks == 1000);
    pump.ticks = UINT64_MAX; assert(dock_frame_poll(&pump));
    assert(pump.ticks == UINT64_MAX && calls == 1001);
    pump.engine = NULL;
    assert(!dock_frame_poll(&pump) && calls == 1001);
    puts("PASS frame pump runs every host cycle, stops without an engine and bounds its counter");
    return 0;
}
