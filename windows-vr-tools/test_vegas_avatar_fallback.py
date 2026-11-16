#!/usr/bin/env python3
"""Exercise the actual avatar proxy with a controlled Steam response and clock."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
HEADER = r'''
#ifndef WINDOWS_H
#define WINDOWS_H
#include <stdint.h>
#include <stddef.h>
#include <wchar.h>
#define __cdecl
#define __declspec(x)
#define CALLBACK
#define WINAPI
#define TRUE 1
#define FALSE 0
#define DLL_PROCESS_ATTACH 1
#define INIT_ONCE_STATIC_INIT 0
#define SRWLOCK_INIT 0
typedef void *HMODULE, *HINSTANCE, *PVOID, *LPVOID;
typedef int BOOL, INIT_ONCE, *PINIT_ONCE, SRWLOCK;
typedef unsigned long DWORD;
typedef wchar_t WCHAR;
typedef unsigned long long ULONGLONG;
DWORD GetModuleFileNameW(HMODULE, WCHAR *, DWORD);
HMODULE LoadLibraryW(const WCHAR *);
void *GetProcAddress(HMODULE, const char *);
BOOL InitOnceExecuteOnce(PINIT_ONCE, BOOL (*)(PINIT_ONCE, PVOID, PVOID *), PVOID, PVOID *);
DWORD GetLastError(void);
ULONGLONG GetTickCount64(void);
void AcquireSRWLockExclusive(SRWLOCK *);
void ReleaseSRWLockExclusive(SRWLOCK *);
void DisableThreadLibraryCalls(HMODULE);
#endif
'''
HARNESS = r'''
#include <assert.h>
#include <string.h>
#include "windows.h"
#include "PROXY_SOURCE"
static int response, calls;
static ULONGLONG clock_ms;
static int fake_avatar(void *friends, uint64_t id) { (void)friends; (void)id; ++calls; return response; }
DWORD GetModuleFileNameW(HMODULE m, WCHAR *p, DWORD n) { (void)m; (void)n; wcscpy(p, L"C:\\game\\steam_api64.dll"); return (DWORD)wcslen(p); }
HMODULE LoadLibraryW(const WCHAR *p) { assert(wcsstr(p,L"wvr_steam_api64_original.dll")); return (void *)1; }
void *GetProcAddress(HMODULE m, const char *p) { (void)m; assert(!strcmp(p,"SteamAPI_ISteamFriends_GetLargeFriendAvatar")); return (void *)(uintptr_t)fake_avatar; }
BOOL InitOnceExecuteOnce(PINIT_ONCE once, BOOL (*fn)(PINIT_ONCE,PVOID,PVOID *), PVOID p, PVOID *c) { if (!*once) *once=fn(once,p,c); return *once; }
DWORD GetLastError(void) { return 0; }
ULONGLONG GetTickCount64(void) { return clock_ms; }
void AcquireSRWLockExclusive(SRWLOCK *l) { (void)l; }
void ReleaseSRWLockExclusive(SRWLOCK *l) { (void)l; }
void DisableThreadLibraryCalls(HMODULE m) { (void)m; }
static int avatar(uint64_t id, int value, ULONGLONG time) { response=value; clock_ms=time; return SteamAPI_ISteamFriends_GetLargeFriendAvatar(NULL,id); }
int main(void) {
    assert(avatar(1,42,0)==42);
    assert(avatar(1,0,0)==0);
    assert(avatar(1,-2,0)==-2);
    assert(avatar(1,-1,100)==-1);
    assert(avatar(1,-1,5099)==-1);
    assert(avatar(2,-1,5099)==-1);
    assert(avatar(1,-1,5100)==0);
    assert(avatar(1,55,5101)==55);
    assert(avatar(1,-1,5102)==-1);
    assert(avatar(1,-1,10101)==-1);
    assert(avatar(1,-1,10102)==0);
    assert(avatar(2,-1,10099)==0);
    memset(pending,0,sizeof(pending));
    for (uint64_t id=1; id<=512; ++id) assert(avatar(id,-1,20000)==-1);
    assert(avatar(513,-1,30000)==-1);
    assert(avatar(512,-1,30000)==0);
    assert(avatar(512,9,30001)==9);
    assert(avatar(513,-1,30002)==-1);
    assert(avatar(513,-1,35002)==0);
    assert(calls==529);
    puts("PASS: real avatar results, five-second pending fallback, reset and bounded table");
}
'''
with tempfile.TemporaryDirectory() as temp:
    folder = Path(temp)
    (folder / 'windows.h').write_text(HEADER)
    (folder / 'probe.c').write_text(HARNESS.replace('PROXY_SOURCE', str(ROOT / 'windows-vr-native/Compatibility/VegasInfinite/SteamAvatarFallback.c')))
    subprocess.run(['clang', '-std=c11', '-Wall', '-Wextra', '-Werror', '-fsanitize=address,undefined', '-I', str(folder), str(folder/'probe.c'), '-o', str(folder/'probe')], check=True)
    subprocess.run([str(folder/'probe')], check=True)
