#include "windows.h"
#include <cassert>
#include <cstring>
#include <climits>
#include <cstdio>
#include "BigscreenMemoryPressure.hpp"

// Mock Unity exports and Windows headroom; execute the actual production class.
// The collection mock also calls back into check() to exercise reentrancy.
static ULONGLONG now = 100000, available = 1ull << 30;
static int64_t used = 1ll << 30, heap = 2ll << 30, after = 128ll << 20;
static bool disabled = false, attached = true, overrideOff = false, missing = false;
static unsigned collections = 0;
static BigscreenMemoryPressure* reentrant = nullptr;
static void log(const char*, ...) {}
ULONGLONG GetTickCount64() { return now; }
DWORD GetEnvironmentVariableW(const wchar_t*, wchar_t* out, DWORD) {
    if (!overrideOff) return 0; out[0]=L'0';out[1]=0;return 1;
}
HMODULE GetModuleHandleW(const wchar_t*) { return reinterpret_cast<void*>(1); }
bool GlobalMemoryStatusEx(MEMORYSTATUSEX* out) {
    out->ullTotalPhys=8ull<<30;out->ullAvailPhys=available;return true;
}
static int64_t getUsed() { return used; }
static int64_t getHeap() { return heap; }
static bool isDisabled() { return disabled; }
static void* currentThread() { return attached ? reinterpret_cast<void*>(1) : nullptr; }
static void collect(int generation) {
    assert(generation==INT_MAX);++collections;
    if (reentrant) reentrant->check(log);
    used=after;now+=5;
}
void* GetProcAddress(HMODULE, const char* name) {
    if (missing) return nullptr;
    if (!strcmp(name,"il2cpp_gc_get_used_size")) return reinterpret_cast<void*>(getUsed);
    if (!strcmp(name,"il2cpp_gc_get_heap_size")) return reinterpret_cast<void*>(getHeap);
    if (!strcmp(name,"il2cpp_gc_is_disabled")) return reinterpret_cast<void*>(isDisabled);
    if (!strcmp(name,"il2cpp_thread_current")) return reinterpret_cast<void*>(currentThread);
    if (!strcmp(name,"il2cpp_gc_collect")) return reinterpret_cast<void*>(collect);
    return nullptr;
}
static void reset() {
    now=100000;available=1ull<<30;used=1ll<<30;heap=2ll<<30;after=128ll<<20;
    disabled=overrideOff=missing=false;attached=true;collections=0;reentrant=nullptr;
}
int main() {
    {
        // Collection frees garbage, is reentrant, and observes its cooldown.
        reset();BigscreenMemoryPressure pressure;reentrant=&pressure;
        pressure.check(log);assert(collections==1&&used==after);
        used=1ll<<30;now+=2000;pressure.check(log);assert(collections==1);
        now+=30000;pressure.check(log);assert(collections==2);
    }
    {
        // Never enable game-disabled GC or attach a new Unity thread.
        reset();BigscreenMemoryPressure pressure;disabled=true;
        pressure.check(log);assert(collections==0);
        disabled=false;attached=false;now+=2000;pressure.check(log);assert(collections==0);
        attached=true;now+=2000;pressure.check(log);assert(collections==1);
    }
    {
        // High headroom and small heaps skip collection; cached APIs remain valid.
        reset();BigscreenMemoryPressure pressure;available=4ull<<30;
        pressure.check(log);assert(collections==0);
        available=1ull<<30;used=256ll<<20;now+=2000;pressure.check(log);assert(collections==0);
        used=1ll<<30;missing=true;now+=2000;pressure.check(log);assert(collections==1);
    }
    {
        // An unavailable export set can be retried after Unity initialization.
        reset();BigscreenMemoryPressure pressure;missing=true;
        pressure.check(log);assert(collections==0);
        missing=false;now+=2000;pressure.check(log);assert(collections==1);
    }
    {
        // A per-process opt-out suppresses intervention entirely.
        reset();BigscreenMemoryPressure pressure;overrideOff=true;
        pressure.check(log);assert(collections==0);
    }
    {
        // Stop after two collections without progress; recover with headroom.
        reset();BigscreenMemoryPressure pressure;after=used;
        pressure.check(log);now+=31000;pressure.check(log);now+=31000;
        pressure.check(log);assert(collections==2);
        available=4ull<<30;now+=2000;pressure.check(log);
        available=1ull<<30;now+=2000;pressure.check(log);assert(collections==3);
    }
    {
        // Invalid counter ordering fails closed.
        reset();BigscreenMemoryPressure pressure;heap=1;
        pressure.check(log);assert(collections==0);
    }
    puts("MANAGED MEMORY PRESSURE CHECKS PASSED");
}
