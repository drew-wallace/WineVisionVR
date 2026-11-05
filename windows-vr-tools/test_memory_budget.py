#!/usr/bin/env python3
"""Run the production memory-budget calculation with controlled OS snapshots."""
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="wvr-memory-budget-") as temporary:
    work = Path(temporary)
    source = work / "wine/dlls/ntdll/unix/system.c"
    source.parent.mkdir(parents=True)
    shutil.copy2(root / "third-party/madeira/wine/dlls/ntdll/unix/system.c", source)
    subprocess.run(
        ["git", "apply", str(root / "windows-runtime-plugin/patches/0028-madeira-process-memory-budget.patch")],
        cwd=work, check=True,
    )
    text = source.read_text()
    start = text.index("#ifdef WINE_IOS", text.index("static void get_performance_info("))
    end = text.index("\n}\n", start)
    calculation = text[start:end]
    harness = r"""
#include <assert.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#define FALSE 0
typedef struct { uint64_t MmNumberOfPhysicalPages; unsigned PageSize; } SYSTEM_BASIC_INFORMATION;
typedef struct { uint64_t AvailablePages, TotalCommittedPages, TotalCommitLimit; } SYSTEM_PERFORMANCE_INFORMATION;
static uint64_t remaining;
static const uint64_t gib = 1ull << 30;
static const uint64_t mib = 1ull << 20;
static const unsigned page_size = 4096;
size_t os_proc_available_memory(void) { return remaining; }
static void virtual_get_system_info(SYSTEM_BASIC_INFORMATION *info, int wow) {
    (void)wow;
    info->PageSize = page_size;
    info->MmNumberOfPhysicalPages = 8 * gib / page_size;
}
static SYSTEM_PERFORMANCE_INFORMATION calculate(uint64_t host_free, uint64_t headroom) {
    unsigned long long totalram = 16 * gib, freeram = host_free;
    unsigned long long totalswap = 4 * gib, freeswap = 2 * gib;
    SYSTEM_PERFORMANCE_INFORMATION result = {0}, *info = &result;
    remaining = headroom;
""" + calculation + r"""
    return result;
}
int main(void) {
    SYSTEM_PERFORMANCE_INFORMATION info = calculate(6 * gib, 32 * mib);
    assert(info.AvailablePages * page_size == 32 * mib);
    assert(info.TotalCommitLimit * page_size == 8 * gib + page_size);
    assert((info.TotalCommitLimit - info.TotalCommittedPages) * page_size == 32 * mib);
    info = calculate(6 * gib, 0);
    assert(info.AvailablePages == 0);
    assert(info.TotalCommittedPages == info.TotalCommitLimit);
    info = calculate(6 * gib, UINT64_MAX);
    assert(info.AvailablePages * page_size == 6 * gib);
    info = calculate(10 * gib, UINT64_MAX);
    assert(info.AvailablePages * page_size == 8 * gib);
    info = calculate(2 * gib, 5 * gib);
    assert(info.AvailablePages * page_size == 2 * gib);
    info = calculate(0, 5 * gib);
    assert(info.AvailablePages == 0);
    info = calculate(6 * gib, 12345);
    assert(info.AvailablePages == 12345 / page_size);
    puts("PROCESS MEMORY BUDGET CHECKS PASSED");
}
"""
    program = work / "memory-budget.c"
    program.write_text(harness)
    for flags, name in [(["-DWINE_IOS=1"], "corrected"), ([], "baseline")]:
        binary = work / name
        subprocess.run(
            ["xcrun", "clang", "-std=c11", "-O1", "-g", "-fsanitize=address,undefined",
             *flags, str(program), "-o", str(binary)], check=True,
        )
        result = subprocess.run([str(binary)], capture_output=True, text=True)
        if name == "corrected":
            assert result.returncode == 0, result.stderr
            print(result.stdout.strip())
        else:
            assert result.returncode != 0, "Regression must fail with the original host-wide accounting"
            print("Original host-wide calculation fails the regression as expected")
