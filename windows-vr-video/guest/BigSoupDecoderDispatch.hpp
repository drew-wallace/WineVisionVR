#pragma once
#include <windows.h>
#include <cstdint>
#include <cstring>
#include <limits>

// Exact-revision, process-local routing of the five incoming-decoder selector
// reads. The original DLL file, the real GPU name, and outgoing encoder routing
// stay intact. No packet check or failed allocation is suppressed.
inline bool installBigSoupDecoderDispatch(unsigned char* module) {
    struct Site { uint32_t rva; unsigned char expected[7], replacement[3]; };
    static const Site sites[]{
        {0x95f36,{0x49,0x81,0xc4,0xc8,0x13,0x02,0},{0x4c,0x8b,0x25}},
        {0x961c2,{0x49,0x81,0xc5,0xc8,0x13,0x02,0},{0x4c,0x8b,0x2d}},
        {0x9667f,{0x48,0x81,0xc7,0xc8,0x13,0x02,0},{0x48,0x8b,0x3d}},
        {0x97142,{0x48,0x81,0xc7,0xc8,0x13,0x02,0},{0x48,0x8b,0x3d}},
        {0x9935b,{0x4c,0x8d,0xb3,0xc8,0x13,0x02,0},{0x4c,0x8b,0x35}},
    };
    for(const auto& site:sites)if(memcmp(module+site.rva,site.expected,7))return false;
    unsigned char* island=nullptr;
    uintptr_t base=reinterpret_cast<uintptr_t>(module)&~uintptr_t(0xffff);
    for(uintptr_t distance=0x100000;!island && distance<0x40000000;distance+=0x100000) {
        const int directions[]{1,-1};
        for(int direction:directions) {
            uintptr_t address=direction>0?base+distance:base-distance;
            MEMORY_BASIC_INFORMATION info{};
            if(VirtualQuery(reinterpret_cast<void*>(address),&info,sizeof(info)) && info.State==MEM_FREE)
                island=static_cast<unsigned char*>(VirtualAlloc(reinterpret_cast<void*>(address),0x1000,MEM_RESERVE|MEM_COMMIT,PAGE_READWRITE));
            if(island)break;
        }
    }
    if(!island)return false;
    static const wchar_t name[]=L"AMD WineVision VideoToolbox";
    struct WString { const wchar_t* data; uint64_t unused,length,capacity; };
    auto* string=reinterpret_cast<WString*>(island+8);
    auto* text=reinterpret_cast<wchar_t*>(island+8+sizeof(WString));
    memcpy(text,name,sizeof(name));*string={text,0,sizeof(name)/sizeof(wchar_t)-1,sizeof(name)/sizeof(wchar_t)-1};
    *reinterpret_cast<WString**>(island)=string;
    int32_t offsets[5]{};
    for(unsigned i=0;i<5;++i) {
        intptr_t delta=reinterpret_cast<intptr_t>(island)-reinterpret_cast<intptr_t>(module+sites[i].rva+7);
        if(delta<INT32_MIN || delta>INT32_MAX){VirtualFree(island,0,MEM_RELEASE);return false;}offsets[i]=static_cast<int32_t>(delta);
    }
    DWORD prior=0,ignored=0;
    if(!VirtualProtect(island,0x1000,PAGE_READONLY,&prior) ||
       !VirtualProtect(module+0x95000,0x5000,PAGE_EXECUTE_READWRITE,&prior)) {
        VirtualFree(island,0,MEM_RELEASE);return false;
    }
    for(unsigned i=0;i<5;++i){memcpy(module+sites[i].rva,sites[i].replacement,3);memcpy(module+sites[i].rva+3,&offsets[i],4);}
    FlushInstructionCache(GetCurrentProcess(),module+0x95000,0x5000);
    VirtualProtect(module+0x95000,0x5000,prior,&ignored);
    // Keep the read-only selector alive through original DLL teardown. The
    // guest process owns this allocation and reclaims it with its address space.
    return true;
}
