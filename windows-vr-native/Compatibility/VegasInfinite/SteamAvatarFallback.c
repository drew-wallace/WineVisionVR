#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <wchar.h>

typedef int (__cdecl *get_avatar_fn)(void *, uint64_t);
static HMODULE proxy_module;
static INIT_ONCE initialized = INIT_ONCE_STATIC_INIT;
static get_avatar_fn original;
static SRWLOCK lock = SRWLOCK_INIT;
static struct { uint64_t id; ULONGLONG since; } pending[512];
static unsigned fallbacks;

static BOOL CALLBACK initialize(PINIT_ONCE once, PVOID parameter, PVOID *context) {
    (void)once; (void)parameter; (void)context;
    WCHAR path[32768];
    DWORD n = GetModuleFileNameW(proxy_module, path, 32768);
    if (!n || n >= 32768) return FALSE;
    WCHAR *last = wcsrchr(path, L'\\');
    if (!last || last - path > 32700) return FALSE;
    wcscpy(last + 1, L"wvr_steam_api64_original.dll");
    HMODULE real = LoadLibraryW(path);
    if (!real) return FALSE;
    original = (get_avatar_fn)(uintptr_t)GetProcAddress(real, "SteamAPI_ISteamFriends_GetLargeFriendAvatar");
    return original != NULL;
}

__declspec(dllexport) int __cdecl SteamAPI_ISteamFriends_GetLargeFriendAvatar(void *friends, uint64_t id) {
    if (!InitOnceExecuteOnce(&initialized, initialize, NULL, NULL)) {
        fprintf(stderr, "[vegas-avatar] original resolution failed error=%lu\n", GetLastError());
        return -1;
    }
    int result = original(friends, id);
    ULONGLONG now = GetTickCount64();
    AcquireSRWLockExclusive(&lock);
    unsigned slot = 512, vacant = 512;
    for (unsigned i = 0; i < 512; ++i) {
        if (pending[i].id == id) { slot = i; break; }
        if (!pending[i].id && vacant == 512) vacant = i;
    }
    if (slot == 512 && result == -1) {
        slot = vacant;
        if (slot < 512) { pending[slot].id = id; pending[slot].since = now; }
    }
    if (result == -1 && slot < 512 && now - pending[slot].since >= 5000) {
        result = 0;
        ++fallbacks;
        if (fallbacks <= 16) fprintf(stderr, "[vegas-avatar] pending image -> default picture, elapsed=%llu ms fallback=%u\n", now - pending[slot].since, fallbacks);
    } else if (result >= 0 && slot < 512) {
        pending[slot].id = 0; pending[slot].since = 0;
    }
    ReleaseSRWLockExclusive(&lock);
    return result;
}
BOOL WINAPI DllMain(HINSTANCE module, DWORD reason, LPVOID reserved) {
    (void)reserved;
    if (reason == DLL_PROCESS_ATTACH) { proxy_module = module; DisableThreadLibraryCalls(module); }
    return TRUE;
}
