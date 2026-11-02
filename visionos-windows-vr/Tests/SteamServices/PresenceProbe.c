#include "presence.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
static int32_t current, friends, set_calls, events, reported_count;
static uint32_t idle;
static int activity_calls;
static uint32_t get_idle(void *p) { assert(p); return idle; }
static void active(void *p, uint32_t source) { assert(p && source == 2); ++activity_calls; idle = 0; }
static int32_t state(void *p) { assert(p); return current; }
static void set(void *p, int32_t s) { assert(p && s == 1); ++set_calls; current = s; }
static int32_t count(void *p, int32_t flags) { assert(p && flags == 4); return friends; }
static void event(const char *key, int32_t value) {
    ++events;
    if (!strcmp(key, "session-social-friend-count")) reported_count = value;
}
static struct dock_presence make(void) {
    return (struct dock_presence){ .friends = &current, .state = state, .set_state = set, .friend_count = count };
}
int main(void) {
    assert(!dock_presence_poll(NULL, 0, event));
    struct dock_presence invalid = {0}; assert(!dock_presence_poll(&invalid, 0, event));
    for (int s = 0; s <= 7; ++s) {
        struct dock_presence p = make(); current = s; set_calls = 0; friends = 12;
        assert(dock_presence_poll(&p, 0, event));
        assert(set_calls == (s == 0 || s == 1 || s == 3 || s == 4));
        assert(current == ((s == 0 || s == 3 || s == 4) ? 1 : s));
    }
    puts("PASS Online wake-up preserves Busy, Invisible and explicit presence states");
    struct dock_presence p = make(); current = 3; set_calls = 0; friends = 0;
    assert(dock_presence_poll(&p, 100, event)); assert(current == 1 && set_calls == 1);
    int before = events; current = 4;
    assert(dock_presence_poll(&p, 500, event)); assert(set_calls == 1 && events == before);
    assert(dock_presence_poll(&p, 5100, event)); assert(current == 1 && set_calls == 2);
    before = events; assert(dock_presence_poll(&p, 10100, event)); assert(events == before);
    friends = 14; assert(dock_presence_poll(&p, 15100, event)); assert(reported_count == 14);
    friends = 70000; assert(dock_presence_poll(&p, 20100, event)); assert(reported_count == -1);
    puts("PASS active-game polling refreshes auto-away, rate-limits calls and reports numeric friend readiness");
    p = make(); p.utils = &idle; p.idle_seconds = get_idle; p.computer_active = active;
    current = 7; set_calls = activity_calls = 0; idle = 800;
    assert(dock_presence_poll(&p, 100, event));
    assert(idle == 0 && activity_calls == 1 && current == 7 && set_calls == 0);
    idle = 4; assert(dock_presence_poll(&p, 4100, event)); assert(idle == 4 && activity_calls == 1);
    assert(dock_presence_poll(&p, 5100, event)); assert(idle == 0 && activity_calls == 2);
    p.computer_active = NULL; idle = 900;
    assert(dock_presence_poll(&p, 10100, event)); assert(idle == 900 && activity_calls == 2);
    puts("PASS independent engine idle timer resets on bounded VR activity, preserving Invisible and tolerating unavailable utils");
    return 0;
}
