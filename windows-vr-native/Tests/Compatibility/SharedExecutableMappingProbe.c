/* Exercise the Windows section/dual-mapping contract used by CoreCLR 9.
 * x64 guest bytes are executed only by the guest CPU translator. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>

static FILE *journal;

static void note(const char *format, ...)
{
    char line[768];
    va_list args;
    va_start(args, format);
    vsnprintf(line, sizeof(line), format, args);
    va_end(args);
    if (journal) { fprintf(journal, "%s\n", line); fflush(journal); }
    OutputDebugStringA(line);
}

static int check(int condition, const char *stage)
{
    if (condition) return 1;
    note("FAIL stage=%s win32=%lu", stage, GetLastError());
    return 0;
}

static int section_case(DWORD section_flags, DWORD view_flags, DWORD offset, int execute)
{
    const SIZE_T size = 0x10000;
    const uint64_t sentinel = UINT64_C(0xf0f0f0f0f0f0f0f0);
    /* mov rax, imm64; ret -- the patch immediate begins at byte 2. */
    unsigned char code[] = {0x48, 0xb8, 0xf0, 0xf0, 0xf0, 0xf0, 0xf0, 0xf0, 0xf0, 0xf0, 0xc3};
    HANDLE section = NULL;
    unsigned char *rx = NULL, *rw = NULL;
    int passed = 0;
    DWORD old_protect;
    note("BEGIN section=0x%lx view=0x%lx offset=0x%lx execute=%d", section_flags, view_flags, offset, execute);
    section = CreateFileMappingW(INVALID_HANDLE_VALUE, NULL,
        (execute ? PAGE_EXECUTE_READWRITE : PAGE_READWRITE) | section_flags, 0, 0x800000, NULL);
    if (!check(section != NULL, "create-section")) goto done;
    rx = MapViewOfFile(section, view_flags, 0, offset, size);
    if (!check(rx != NULL, "map-primary")) goto done;
    if (section_flags == SEC_RESERVE &&
        !check(VirtualAlloc(rx, size, MEM_COMMIT, execute ? PAGE_EXECUTE_READ : PAGE_READWRITE) == rx,
               "commit-primary")) goto done;
    rw = MapViewOfFile(section, FILE_MAP_READ | FILE_MAP_WRITE, 0, offset, size);
    if (!check(rw != NULL, "map-writer")) goto done;
    note("MAP primary=%p writer=%p", (void *)rx, (void *)rw);
    memcpy(rw, code, sizeof(code));
    /* CoreCLR checks the executable view before flushing the instruction cache. */
    note("COPY primary-immediate=0x%llx writer-immediate=0x%llx",
         (unsigned long long)*(volatile uint64_t *)(rx + 2),
         (unsigned long long)*(volatile uint64_t *)(rw + 2));
    if (!check(memcmp(rx, code, sizeof(code)) == 0, "copy-visible-before-flush")) goto done;
    if (!check(*(volatile uint64_t *)(rx + 2) == sentinel, "barrier-placeholder")) goto done;
    for (uint64_t expected = 41; expected < 49; ++expected) {
        memcpy(rw + 2, &expected, sizeof(expected));
        if (!check(*(volatile uint64_t *)(rx + 2) == expected, "patch-visible-before-flush")) goto done;
        if (!check(FlushInstructionCache(GetCurrentProcess(), rx, sizeof(code)), "flush")) goto done;
        if (execute) {
            uint64_t actual = ((uint64_t (*)(void))(uintptr_t)rx)();
            note("EXEC expected=%llu actual=%llu", (unsigned long long)expected, (unsigned long long)actual);
            if (!check(actual == expected, "execute-patched-code")) goto done;
        }
        if (!check(UnmapViewOfFile(rw), "unmap-writer")) goto done;
        rw = NULL;
        rw = MapViewOfFile(section, FILE_MAP_READ | FILE_MAP_WRITE, 0, offset, size);
        if (!check(rw != NULL, "remap-writer")) goto done;
        if (!check(*(volatile uint64_t *)(rw + 2) == expected, "remap-preserves-bytes")) goto done;
    }
    if (!check(VirtualProtect(rx, size, execute ? PAGE_EXECUTE_READ : PAGE_READONLY, &old_protect),
               "protect-primary")) goto done;
    passed = 1;
done:
    if (rw && !UnmapViewOfFile(rw)) passed = 0;
    if (rx && !UnmapViewOfFile(rx)) passed = 0;
    if (section && !CloseHandle(section)) passed = 0;
    note("END result=%s", passed ? "PASS" : "FAIL");
    return passed;
}

static int foreign_query_child(uintptr_t address)
{
    MEMORY_BASIC_INFORMATION info = {0};
    SIZE_T result = VirtualQuery((void *)address, &info, sizeof(info));
    note("QUERY child address=%p returned=%llu base=%p size=0x%llx state=0x%lx error=%lu",
         (void *)address, (unsigned long long)result, info.BaseAddress,
         (unsigned long long)info.RegionSize, info.State, GetLastError());
    if (!check(result == sizeof(info) && info.RegionSize > 0 &&
               (uintptr_t)info.BaseAddress <= address &&
               info.RegionSize > address - (uintptr_t)info.BaseAddress,
               "query-must-make-progress")) return 0;
    uintptr_t cursor = 0;
    DWORD started = GetTickCount();
    for (unsigned int regions = 0; regions < 100000; ++regions) {
        memset(&info, 0, sizeof(info));
        if (!VirtualQuery((void *)cursor, &info, sizeof(info))) {
            if (!check(GetLastError() == ERROR_INVALID_PARAMETER, "query-walk-end")) return 0;
            note("QUERY walk regions=%u elapsed-ms=%lu", regions, GetTickCount() - started);
            return 1;
        }
        uintptr_t next = (uintptr_t)info.BaseAddress + info.RegionSize;
        if (!check(info.RegionSize > 0 && (uintptr_t)info.BaseAddress <= cursor && next > cursor,
                   "query-walk-progress")) return 0;
        cursor = next;
    }
    return check(0, "query-walk-region-limit");
}

static int foreign_query_case(void)
{
    WCHAR executable[32768], command[33024];
    HANDLE section = CreateFileMappingW(INVALID_HANDLE_VALUE, NULL, PAGE_READWRITE | SEC_RESERVE,
                                       0, 0x10000, NULL);
    if (!check(section != NULL, "query-create-section")) return 0;
    void *view = MapViewOfFile(section, FILE_MAP_READ | FILE_MAP_WRITE, 0, 0, 0x10000);
    int passed = 0;
    PROCESS_INFORMATION process = {0};
    STARTUPINFOW startup = {0}; startup.cb = sizeof(startup);
    if (!check(view != NULL, "query-map-parent")) goto done;
    if (!check(GetModuleFileNameW(NULL, executable, 32768) != 0, "query-self-path")) goto done;
    swprintf(command, sizeof(command) / sizeof(*command), L"\"%ls\" --query-child %llx",
             executable, (unsigned long long)(uintptr_t)view);
    note("BEGIN foreign-query parent-view=%p", view);
    if (!check(CreateProcessW(executable, command, NULL, NULL, FALSE, 0, NULL, NULL,
                              &startup, &process), "query-create-child")) goto done;
    DWORD wait = WaitForSingleObject(process.hProcess, 15000), code = 1;
    if (wait != WAIT_OBJECT_0) {
        note("FAIL query-child wait=%lu", wait);
        TerminateProcess(process.hProcess, 1);
    } else if (GetExitCodeProcess(process.hProcess, &code)) passed = code == 0;
    note("END foreign-query result=%s exit=%lu", passed ? "PASS" : "FAIL", code);
done:
    if (process.hThread) CloseHandle(process.hThread);
    if (process.hProcess) CloseHandle(process.hProcess);
    if (view) UnmapViewOfFile(view);
    CloseHandle(section);
    return passed;
}

int main(int argc, char **argv)
{
    WCHAR path[32768];
    if (!GetModuleFileNameW(NULL, path, 32768)) return 2;
    WCHAR *tail = wcsrchr(path, L'\\');
    if (!tail) return 2;
    int child = argc == 3 && strcmp(argv[1], "--query-child") == 0;
    wcscpy(tail + 1, child ? L"mapping-query-child.txt" : L"mapping-result.txt");
    journal = _wfopen(path, L"w");
    if (!journal) return 2;
    const char *run = getenv("WINEVISION_PROBE_RUN_ID");
    note("START shared-executable-mapping-v1 pid=%lu run=%s", GetCurrentProcessId(), run ? run : "manual");
    if (child) {
        int passed = foreign_query_child((uintptr_t)strtoull(argv[2], NULL, 16));
        note("RESULT %s", passed ? "PASS" : "FAIL"); fclose(journal); return passed ? 0 : 1;
    }
    int passed = foreign_query_case();
    if (passed) passed = section_case(SEC_COMMIT, FILE_MAP_READ | FILE_MAP_WRITE, 0, 0);
    if (passed) passed = section_case(SEC_RESERVE, FILE_MAP_READ | FILE_MAP_WRITE, 0x10000, 0);
    if (passed) passed = section_case(SEC_RESERVE, FILE_MAP_EXECUTE | FILE_MAP_READ | FILE_MAP_WRITE, 0, 1);
    if (passed) passed = section_case(SEC_RESERVE, FILE_MAP_EXECUTE | FILE_MAP_READ | FILE_MAP_WRITE, 0x10000, 1);
    note("RESULT %s", passed ? "PASS" : "FAIL");
    fclose(journal);
    return passed ? 0 : 1;
}
