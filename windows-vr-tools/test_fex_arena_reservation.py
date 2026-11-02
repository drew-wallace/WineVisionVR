#!/usr/bin/env python3
"""Exercise the production arena reservation with mocked Mach/Wine allocation.

The real device must still prove that the larger range can actually be owned.
These checks cover opt-in validation, fallback, caps, cleanup and publication.
"""
import argparse
from pathlib import Path
import subprocess
import tempfile

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--source', type=Path, required=True)
a = p.parse_args()
source = a.source.read_text()
start = source.index('void ios_reserve_fex_arena(void)')
end = source.index('\nNTSTATUS WINAPI NtAllocateVirtualMemoryEx', start)
function = source[start:end]
mock = r'''
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef uintptr_t ULONG_PTR;
typedef size_t SIZE_T;
typedef uint64_t mach_vm_address_t, mach_vm_size_t;
typedef int kern_return_t, mach_msg_type_number_t;
typedef void *task_info_t;
typedef struct { uint64_t max_address; } task_vm_info_data_t;
typedef struct { void *LowestStartingAddress, *HighestEndingAddress; size_t Alignment; } MEM_ADDRESS_REQUIREMENTS;
typedef struct { int Type; void *Pointer; } MEM_EXTENDED_PARAMETER;
typedef int NTSTATUS;
#define ARRAY_SIZE(a) (sizeof(a)/sizeof((a)[0]))
#define KERN_SUCCESS 0
#define KERN_FAILURE 1
#define VM_FLAGS_ANYWHERE 1
#define VM_FLAGS_FIXED 0
#define MEMORY_OBJECT_NULL 0
#define PROT_NONE 0
#define VM_PROT_ALL 7
#define VM_INHERIT_COPY 0
#define TASK_VM_INFO_COUNT 1
#define TASK_VM_INFO 1
#define MEM_RESERVE 1
#define MEM_RESERVE_PLACEHOLDER 2
#define PAGE_NOACCESS 0
#define MemExtendedParameterAddressRequirements 1
#define ERR(...) dprintf(2, __VA_ARGS__)
#define NtCurrentProcess() 0
static uint64_t ios_layerkit_lo, ios_layerkit_hi;
static ULONG_PTR ios_fex_arena_base_unix, ios_fex_arena_end_unix;
static int scenario, allocations, releases, registrations;
static uint64_t sizes[16], cap_mb;
static int mach_task_self(void) { return 0; }
static int task_info(int t, int f, task_info_t out, int *count) {
    ((task_vm_info_data_t*)out)->max_address = 0x8000000000ull; return 0;
}
static long long madeira_cfg_int(const char *name, int fallback) { return cap_mb; }
static int NtAllocateVirtualMemoryEx(int p, void **b, size_t *s, int t, int prot, void *params, int n) { return 1; }
static int mach_vm_map(int task, uint64_t *addr, uint64_t size, int mask, int flags,
                      int object, int offset, int copy, int prot, int maxprot, int inherit) {
    assert(!ios_fex_arena_base_unix && !getenv("WINE_IOS_FEX_ARENA_SIZE"));
    sizes[allocations++] = size;
    if (scenario == 6 || (scenario == 2 && size == 0x800000000ull)) return KERN_FAILURE;
    return KERN_SUCCESS;
}
static int mach_vm_deallocate(int t, uint64_t addr, uint64_t size) { releases++; return 0; }
static int mmap_add_fex_reserved_area(void *base, size_t size) {
    assert(!ios_fex_arena_base_unix && !getenv("WINE_IOS_FEX_ARENA_SIZE"));
    registrations++;
    return !(scenario == 3 && size == 0x800000000ull);
}
'''
main = r'''
int main(int argc, char **argv) {
    scenario = atoi(argv[1]);
    unsetenv("MADEIRA_FEX_ARENA"); unsetenv("WVR_FEX_ARENA_GIB");
    unsetenv("WINE_IOS_FEX_ARENA_SIZE");
    if (scenario != 0) setenv("WVR_FEX_ARENA_GIB", scenario == 5 ? "32garbage" : "32", 1);
    if (scenario == 4) cap_mb = 16384;
    if (scenario == 7) setenv("MADEIRA_FEX_ARENA", "0", 1);
    ios_reserve_fex_arena();
    if (scenario == 6 || scenario == 7) {
        assert(!ios_fex_arena_base_unix && !getenv("WINE_IOS_FEX_ARENA_SIZE"));
        assert(scenario != 7 || allocations == 0);
    } else {
        uint64_t expected = scenario == 1 ? 0x800000000ull : 0x400000000ull;
        assert(ios_fex_arena_end_unix - ios_fex_arena_base_unix == expected);
        assert(strtoull(getenv("WINE_IOS_FEX_ARENA_SIZE"), 0, 16) == expected);
        assert(!strcmp(getenv("WINE_IOS_FEX_ARENA_VERSION"), "1"));
        if (scenario == 2 || scenario == 3) assert(allocations == 2);
        else assert(allocations == 1);
        assert(releases == (scenario == 3));
        if (scenario == 0 || scenario == 4 || scenario == 5) assert(sizes[0] == 0x400000000ull);
    }
    int count = allocations;
    ios_reserve_fex_arena();
    assert(allocations == count); /* one reservation per Mach task */
    return 0;
}
'''
with tempfile.TemporaryDirectory(prefix='wvr-arena-test-') as d:
    root = Path(d)
    (root / 'test.c').write_text(mock + function + main)
    subprocess.run(['clang', '-std=c11', '-fsanitize=address,undefined', '-g',
                    str(root / 'test.c'), '-o', str(root / 'test')], check=True)
    for scenario in range(8):
        subprocess.run([str(root / 'test'), str(scenario)], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
print('PASS: production reservation: default, 32 GiB opt-in, allocation/registration fallback, cap, malformed override, all failures, disable, single ownership (ASan/UBSan)')
