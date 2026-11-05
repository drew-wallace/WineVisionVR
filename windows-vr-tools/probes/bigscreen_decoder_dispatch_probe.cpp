// Diagnostic only: execute the installed BigSoup revision's actual decoder
// selection instructions in a separate process. Never load or alter the game.
#include <windows.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cwchar>
#include "BigSoupDecoderDispatch.hpp"

extern "C" void run_decoder_dispatch(void* entry, void* context);
static FILE* output;
static unsigned nvidiaCalls, amdCalls;
static unsigned char bufferMarker;
static void check(bool ok, const char* name) {
  fprintf(output, "%s %s\n", ok ? "PASS" : "FAIL", name); fflush(output);
  if (!ok) { fprintf(output, "RESULT FAIL\n"); fclose(output); ExitProcess(1); }
}
static int nvidia(void* context) {
  ++nvidiaCalls; *reinterpret_cast<void**>(static_cast<char*>(context)+0x30) = &bufferMarker; return 0;
}
static int amd(void* context) {
  ++amdCalls; *reinterpret_cast<void**>(static_cast<char*>(context)+0x30) = &bufferMarker; return 0;
}
static void redirect(unsigned char* at, void* function) {
  // movabs rax, function; jmp rax. Applies to this probe's private mapping only.
  unsigned char instruction[]{0x48,0xb8,0,0,0,0,0,0,0,0,0xff,0xe0};
  memcpy(instruction+2, &function, 8); memcpy(at,instruction,sizeof(instruction));
}
int main() {
  output = fopen("mapping-result.txt", "w"); if (!output) return 2;
  fprintf(output,"START bigscreen-decoder-dispatch run=%s\n", getenv("WINEVISION_PROBE_RUN_ID") ?: "missing"); fflush(output);
  // Suppress DLL initialization and dependency resolution: no BigSoup worker,
  // network connection, audio, graphics device, or game is started.
  auto* module = reinterpret_cast<unsigned char*>(LoadLibraryExW(L"BigSoup.fixture.dll", nullptr, DONT_RESOLVE_DLL_REFERENCES));
  check(module != nullptr, "map isolated fixture without initialization");
  auto* dos = reinterpret_cast<IMAGE_DOS_HEADER*>(module);
  auto* pe = reinterpret_cast<IMAGE_NT_HEADERS64*>(module+dos->e_lfanew);
  check(pe->FileHeader.Machine == IMAGE_FILE_MACHINE_AMD64 && pe->OptionalHeader.SizeOfImage == 0x38a000,
        "fixture image layout");
  const unsigned char end[]{0x4c,0x8b,0x44,0x24,0x38,0x41,0xc6,0x40,0x03,0x01};
  const unsigned char start[]{0x48,0x8b,0x3d,0x41,0x54,0x2c,0x00};
  check(!memcmp(module+0x968d0,end,sizeof(end)) && !memcmp(module+0x96678,start,sizeof(start)),
        "exact decoder dispatch instructions");
  DWORD old = 0;
  check(VirtualProtect(module+0x8f000, 0x9000, PAGE_EXECUTE_READWRITE, &old) != 0, "make private diagnostic mapping writable");
  redirect(module+0x905f0,reinterpret_cast<void*>(&nvidia));
  redirect(module+0x8f480,reinterpret_cast<void*>(&amd));
  module[0x968d0+sizeof(end)] = 0xc3; // Return after the original initialized flag store.
  FlushInstructionCache(GetCurrentProcess(),module+0x8f000,0x9000);
  auto* owner = static_cast<unsigned char*>(calloc(1,0x21400));
  check(owner != nullptr,"allocate isolated owner");
  DWORD dataOld = 0;
  check(VirtualProtect(module+0x35bac0,sizeof(void*),PAGE_READWRITE,&dataOld) != 0,"make private owner slot writable");
  *reinterpret_cast<void**>(module+0x35bac0) = owner;
  struct WString { const wchar_t* data; size_t unused, length, capacity; };
  const wchar_t* names[]{L"Apple M5 GPU",L"NVIDIA diagnostic GPU",L"AMD diagnostic GPU",L"Radeon diagnostic GPU"};
  for (unsigned index=0;index<4;++index) {
    unsigned char context[1024]{};
    auto* name = reinterpret_cast<WString*>(owner+0x213c8);
    *name = {names[index],0,wcslen(names[index]),wcslen(names[index])};
    nvidiaCalls=amdCalls=0;
    run_decoder_dispatch(module+0x96678, context);
    void* buffer = *reinterpret_cast<void**>(context+0x30);
    fprintf(output,"GPU index=%u initialized=%u nvidia=%u amd=%u buffer=%s\n",index,context[3],nvidiaCalls,amdCalls,buffer ? "present" : "null"); fflush(output);
    check(context[3] == 1, "original initialized flag set");
    if (index==0) check(!buffer && !nvidiaCalls && !amdCalls,"Apple description skips both initializers and leaves buffer null");
    else check(buffer && nvidiaCalls==(index==1) && amdCalls==(index>=2),"recognized description selects its initializer");
  }
    check(installBigSoupDecoderDispatch(module),"install production incoming-decoder selectors");
    check(!installBigSoupDecoderDispatch(module),"reject unexpected/already changed instructions");
    unsigned char patchedContext[1024]{};
    auto* apple=reinterpret_cast<WString*>(owner+0x213c8);
    *apple={names[0],0,wcslen(names[0]),wcslen(names[0])};
    nvidiaCalls=amdCalls=0;
    run_decoder_dispatch(module+0x96678,patchedContext);
    check(patchedContext[3] && *reinterpret_cast<void**>(patchedContext+0x30) && amdCalls==1 && !nvidiaCalls,
          "Apple incoming stream now initializes its AMF backend and packet buffer");
    check(!wcscmp(apple->data,names[0]),"real GPU name and outgoing selection remain unchanged");
  free(owner);
  fprintf(output,"RESULT PASS\n"); fclose(output); return 0;
}
