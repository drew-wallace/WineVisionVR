#include <windows.h>
#include <d3d11.h>
#include <cwchar>
#include <mutex>
#include <cstdio>
#include <cstdarg>
#include "IUnityInterface.h"
#include "IUnityGraphicsD3D11.h"
#include "BigSoupDecoderDispatch.hpp"
#include "BigscreenMemoryPressure.hpp"

// Only incoming decoder selection uses the AMF-compatible backend. The game's
// GPU description and outgoing encoder selection retain their actual values.
static IUnityInterfaces* originalInterfaces=nullptr;
static IUnityGraphicsD3D11* originalGraphics=nullptr;
extern "C" __declspec(dllexport) int WVRBigSoupVideoPrepareV1();
static void trace(const char* format,...) {
    HMODULE self=nullptr;wchar_t path[1024];
    if(!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS|GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                         reinterpret_cast<LPCWSTR>(&trace),&self))return;
    DWORD n=GetModuleFileNameW(self,path,1024);if(!n||n>=1024)return;
    auto* slash=wcsrchr(path,L'\\');if(!slash)return;
    if(size_t(slash-path)+32>=1024)return;
    wcscpy(slash+1,L"wvr-video-adapter.log");
    FILE* file=_wfopen(path,L"a");if(!file)return;
    fprintf(file,"tick=%llu ",GetTickCount64());va_list args;va_start(args,format);vfprintf(file,format,args);va_end(args);
    fputc('\n',file);fclose(file);
}
static decltype(&D3D11CreateDevice) originalCreateDevice=nullptr;
using CreateAdapter=ID3D11Device*(*)(ID3D11Device*);
static CreateAdapter createAdapter=nullptr;
static HRESULT WINAPI createDevice(IDXGIAdapter* adapter,D3D_DRIVER_TYPE type,HMODULE software,UINT flags,
    const D3D_FEATURE_LEVEL* levels,UINT count,UINT sdk,ID3D11Device** device,D3D_FEATURE_LEVEL* level,ID3D11DeviceContext** context) {
    HRESULT result=originalCreateDevice(adapter,type,software,flags,levels,count,sdk,device,level,context);
    if(SUCCEEDED(result) && device && *device) {
        auto* real=*device;auto* wrapped=createAdapter(real);
        if(!wrapped){real->Release();*device=nullptr;if(context&&*context){(*context)->Release();*context=nullptr;}return E_OUTOFMEMORY;}
        *device=wrapped;real->Release();
        trace("D3D11CreateDevice: decoder device wrapped");
    }
    return result;
}
static bool installDeviceFactory(HMODULE module) {
    auto amf=GetModuleHandleW(L"amfrt64.dll");
    createAdapter=amf?reinterpret_cast<CreateAdapter>(GetProcAddress(amf,"WVRCreateD3D11DeviceAdapterV1")):nullptr;
    if(!createAdapter)return false;
    auto* bytes=reinterpret_cast<unsigned char*>(module);
    auto* pe=reinterpret_cast<IMAGE_NT_HEADERS64*>(bytes+reinterpret_cast<IMAGE_DOS_HEADER*>(bytes)->e_lfanew);
    auto* imports=reinterpret_cast<IMAGE_IMPORT_DESCRIPTOR*>(bytes+pe->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT].VirtualAddress);
    for(;imports->Name;++imports) {
        if(_stricmp(reinterpret_cast<char*>(bytes+imports->Name),"d3d11.dll"))continue;
        if(!imports->OriginalFirstThunk)return false;
        auto* names=reinterpret_cast<IMAGE_THUNK_DATA64*>(bytes+imports->OriginalFirstThunk);
        auto* addresses=reinterpret_cast<IMAGE_THUNK_DATA64*>(bytes+imports->FirstThunk);
        for(;names->u1.AddressOfData;++names,++addresses) {
            if(IMAGE_SNAP_BY_ORDINAL64(names->u1.Ordinal))continue;
            auto* name=reinterpret_cast<IMAGE_IMPORT_BY_NAME*>(bytes+names->u1.AddressOfData);
            if(strcmp(reinterpret_cast<char*>(name->Name),"D3D11CreateDevice"))continue;
            DWORD prior=0,ignored=0;
            if(!VirtualProtect(&addresses->u1.Function,sizeof(void*),PAGE_READWRITE,&prior))return false;
            originalCreateDevice=reinterpret_cast<decltype(originalCreateDevice)>(addresses->u1.Function);
            addresses->u1.Function=reinterpret_cast<ULONGLONG>(&createDevice);
            VirtualProtect(&addresses->u1.Function,sizeof(void*),prior,&ignored);return true;
        }
    }return false;
}
static HMODULE original() {
    static HMODULE value=LoadLibraryW(L"wvr_bigsoup_original.dll");return value;
}
static ID3D11Device* UNITY_INTERFACE_API getDevice() {
    if(!originalGraphics)return nullptr;auto* device=originalGraphics->GetDevice();
    using Wrap=ID3D11Device*(*)(ID3D11Device*);
    static HMODULE amf=LoadLibraryW(L"amfrt64.dll");
    static auto wrap=amf?reinterpret_cast<Wrap>(GetProcAddress(amf,"WVRWrapD3D11DeviceV1")):nullptr;
    return wrap?wrap(device):nullptr;
}
static ID3D11Resource* UNITY_INTERFACE_API fromRenderBuffer(UnityRenderBuffer value){return originalGraphics->TextureFromRenderBuffer(value);}
static ID3D11Resource* UNITY_INTERFACE_API fromTexture(UnityTextureID value){return originalGraphics->TextureFromNativeTexture(value);}
static ID3D11RenderTargetView* UNITY_INTERFACE_API renderView(UnityRenderBuffer value){return originalGraphics->RTVFromRenderBuffer(value);}
static ID3D11ShaderResourceView* UNITY_INTERFACE_API shaderView(UnityTextureID value){return originalGraphics->SRVFromNativeTexture(value);}
static IUnityGraphicsD3D11 graphics{{},getDevice,fromRenderBuffer,fromTexture,renderView,shaderView};
static IUnityInterface* UNITY_INTERFACE_API getInterface(UnityInterfaceGUID guid) {
    auto* value=originalInterfaces->GetInterface(guid);
    if(guid==GetUnityInterfaceGUID<IUnityGraphicsD3D11>() && value) {
        originalGraphics=static_cast<IUnityGraphicsD3D11*>(value);return &graphics;
    }return value;
}
static void UNITY_INTERFACE_API registerInterface(UnityInterfaceGUID guid,IUnityInterface* value) {
    originalInterfaces->RegisterInterface(guid,value);
}
static IUnityInterface* UNITY_INTERFACE_API getSplit(unsigned long long high,unsigned long long low) {
    return getInterface({high,low});
}
static void UNITY_INTERFACE_API registerSplit(unsigned long long high,unsigned long long low,IUnityInterface* value) {
    registerInterface({high,low},value);
}
static IUnityInterfaces interfaces{getInterface,registerInterface,getSplit,registerSplit};
extern "C" __declspec(dllexport) void UNITY_INTERFACE_API UnityPluginLoad(IUnityInterfaces* value) {
    trace("UnityPluginLoad: prepare=%d",WVRBigSoupVideoPrepareV1());
    originalInterfaces=value;
    using Load=void(UNITY_INTERFACE_API*)(IUnityInterfaces*);
    auto load=reinterpret_cast<Load>(GetProcAddress(original(),"UnityPluginLoad"));
    if(load)load(&interfaces);
}
extern "C" __declspec(dllexport) int WVRBigSoupVideoPrepareV1() {
    auto module=original();
    if(!module)return 0;
    static std::once_flag once;static int status=0;
    std::call_once(once,[module] {
            auto* bytes=reinterpret_cast<unsigned char*>(module);
            // Initialize BigSoup's existing AMF factory independently of its
            // outgoing encoder, which the Apple path does not initialize.
            const unsigned char expected[]{0x40,0x53,0x48,0x83,0xec,0x20,0x48,0x83,0x79,0x08,0x00};
            using Initialize=int(*)(void*);
            bool initialized=!memcmp(bytes+0x76250,expected,sizeof(expected)) &&
                reinterpret_cast<Initialize>(bytes+0x76250)(bytes+0x359130)==0;
            bool factory=initialized && installDeviceFactory(module);
            bool installed=factory && installBigSoupDecoderDispatch(bytes);
            status=installed?7:factory?5:initialized?1:0;
            trace("prepare: factory=%d deviceFactory=%d selectors=%d status=%d",initialized,factory,installed,status);
            OutputDebugStringA(installed?"[wvr-video] BigSoup incoming H264 adapter installed\n":"[wvr-video] BigSoup decoder adapter initialization failed\n");
    });
    return status;
}
extern "C" __declspec(dllexport) void BigSoupInitiate(int mode,const wchar_t* gpu) {
    using Initiate=void(*)(int,const wchar_t*);
    auto module=original();if(!module)return;
    auto initiate=reinterpret_cast<Initiate>(GetProcAddress(module,"BigSoupInitiate"));
    trace("BigSoupInitiate: mode=%d prepare=%d",mode,WVRBigSoupVideoPrepareV1());
    if(initiate)initiate(mode,gpu);
}
extern "C" __declspec(dllexport) void BigSoupCreate() {
    trace("BigSoupCreate: prepare=%d",WVRBigSoupVideoPrepareV1());
    using Create=void(*)();auto module=original();if(!module)return;
    auto create=reinterpret_cast<Create>(GetProcAddress(module,"BigSoupCreate"));if(create)create();
}

extern "C" __declspec(dllexport) void BigSoupExecutePendingCallbacks() {
    using Execute = void (*)();
    auto module = original();
    if (!module) return;
    static auto execute = reinterpret_cast<Execute>(
        GetProcAddress(module, "BigSoupExecutePendingCallbacks"));
    if (!execute) return;
    execute();
    static BigscreenMemoryPressure pressure;
    pressure.check(trace);
}
