#pragma once
#include <windows.h>
#include <climits>
#include <cstdint>
#include <atomic>

// Called after Bigscreen releases its pending-callback mutex, on its existing
// Unity callback thread. Collection uses IL2CPP's exported API and requires an
// attached thread. Game-controlled collection disabling is respected.
class BigscreenMemoryPressure {
public:
    using Logger = void (*)(const char*, ...);

    void check(Logger log) {
        if (checking.test_and_set(std::memory_order_acquire)) return;
        CheckGuard guard{checking};
        const ULONGLONG now = GetTickCount64();
        if (now < nextCheck) return;
        nextCheck = now + 1000;

        wchar_t overrideValue[2]{};
        if (GetEnvironmentVariableW(L"WVR_BIGSCREEN_MEMORY_PRESSURE", overrideValue, 2) == 1 &&
            overrideValue[0] == L'0') return;
        if (!bind()) return;

        MEMORYSTATUSEX memory{};
        memory.dwLength = sizeof(memory);
        if (!GlobalMemoryStatusEx(&memory) || !memory.ullTotalPhys ||
            memory.ullAvailPhys > memory.ullTotalPhys) return;
        const int64_t used = getUsed();
        const int64_t heap = getHeap();
        if (used < 0 || heap < used || heap > int64_t(32ull << 30)) return;
        const bool disabled = isDisabled();
        const bool attached = currentThread() != nullptr;

        if (now >= nextReport) {
            log("managed-memory: usedMiB=%lld heapMiB=%lld availableMiB=%llu disabled=%d attached=%d",
                static_cast<long long>(used >> 20), static_cast<long long>(heap >> 20),
                memory.ullAvailPhys >> 20, disabled, attached);
            nextReport = now + 10000;
        }
        if (memory.ullAvailPhys > (3ull << 30)) unsuccessfulCollections = 0;
        if (memory.ullAvailPhys > (2ull << 30) || used < int64_t(512ull << 20) ||
            disabled || !attached || now < nextCollection || unsuccessfulCollections >= 2) return;

        collect(INT_MAX);
        const ULONGLONG finished = GetTickCount64();
        nextCollection = finished + 30000;
        nextCheck = finished + 1000;
        const int64_t after = getUsed();
        if (after >= 0 && used - after >= int64_t(32ull << 20)) unsuccessfulCollections = 0;
        else ++unsuccessfulCollections;
        MEMORYSTATUSEX afterMemory{};
        afterMemory.dwLength = sizeof(afterMemory);
        const bool haveAfterMemory = GlobalMemoryStatusEx(&afterMemory);
        log("memory-pressure collection: beforeMiB=%lld afterMiB=%lld durationMs=%llu availableMiB=%llu unsuccessful=%u",
            static_cast<long long>(used >> 20), static_cast<long long>(after >> 20),
            finished - now, haveAfterMemory ? afterMemory.ullAvailPhys >> 20 : 0,
            unsuccessfulCollections);
    }

private:
    using GetSize = int64_t (*)();
    using IsDisabled = bool (*)();
    using CurrentThread = void* (*)();
    using Collect = void (*)(int);
    struct CheckGuard {
        std::atomic_flag& flag;
        ~CheckGuard() { flag.clear(std::memory_order_release); }
    };
    std::atomic_flag checking = ATOMIC_FLAG_INIT;
    ULONGLONG nextCheck = 0;
    ULONGLONG nextReport = 0;
    ULONGLONG nextCollection = 0;
    unsigned unsuccessfulCollections = 0;
    GetSize getUsed = nullptr;
    GetSize getHeap = nullptr;
    IsDisabled isDisabled = nullptr;
    CurrentThread currentThread = nullptr;
    Collect collect = nullptr;

    bool bind() {
        if (getUsed) return true;
        HMODULE assembly = GetModuleHandleW(L"GameAssembly.dll");
        if (!assembly) return false;
        auto used = reinterpret_cast<GetSize>(GetProcAddress(assembly, "il2cpp_gc_get_used_size"));
        auto heap = reinterpret_cast<GetSize>(GetProcAddress(assembly, "il2cpp_gc_get_heap_size"));
        auto disabled = reinterpret_cast<IsDisabled>(GetProcAddress(assembly, "il2cpp_gc_is_disabled"));
        auto thread = reinterpret_cast<CurrentThread>(GetProcAddress(assembly, "il2cpp_thread_current"));
        auto collection = reinterpret_cast<Collect>(GetProcAddress(assembly, "il2cpp_gc_collect"));
        if (!used || !heap || !disabled || !thread || !collection) return false;
        getUsed = used;
        getHeap = heap;
        isDisabled = disabled;
        currentThread = thread;
        collect = collection;
        return true;
    }
};
