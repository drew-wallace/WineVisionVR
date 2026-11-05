#pragma once
#include <cstdint>
using HMODULE = void*;
using DWORD = uint32_t;
using ULONGLONG = unsigned long long;
struct MEMORYSTATUSEX { DWORD dwLength, dwMemoryLoad; ULONGLONG ullTotalPhys, ullAvailPhys; };
ULONGLONG GetTickCount64();
DWORD GetEnvironmentVariableW(const wchar_t*, wchar_t*, DWORD);
HMODULE GetModuleHandleW(const wchar_t*);
void* GetProcAddress(HMODULE, const char*);
bool GlobalMemoryStatusEx(MEMORYSTATUSEX*);
