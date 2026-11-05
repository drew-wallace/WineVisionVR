#include <windows.h>
#include <winternl.h>
#include "VideoFrame.hpp"
#include "WindowsVRVideoDecoder.h"
#include "WindowsVRH264AnnexB.hpp"
#include "core/Factory.h"
#include <algorithm>
#include <atomic>
#include <mutex>
#include <type_traits>
#include <vector>

using namespace amf;
using UnixCall=LONG(WINAPI*)(uint64_t,unsigned,void*);
static UnixCall unixCall=nullptr;
extern "C" {
UnixCall wvr_video_unix_dispatcher=nullptr;
#ifdef __arm64ec__
// Match Wine's native unix-call trampoline. An ordinary guarded indirect call
// would interpret the host dispatcher as a Windows/EC function target.
__attribute__((naked)) LONG wvr_video_unix_native(uint64_t handle,unsigned code,void* args) {
    asm(".seh_proc \"#wvr_video_unix_native\"\n\t"
        ".seh_endprologue\n\t"
        "adrp x16, wvr_video_unix_dispatcher\n\t"
        "ldr x16, [x16, #:lo12:wvr_video_unix_dispatcher]\n\t"
        "br x16\n\t"
        ".seh_endproc");
}
#endif
}
static uint64_t unixHandle=0;
static std::once_flag unixOnce;
static void initializeUnix() {
    HMODULE self=nullptr;
    if(!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS|GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                          reinterpret_cast<LPCWSTR>(&initializeUnix),&self))return;
    auto ntdll=GetModuleHandleW(L"ntdll.dll");
    using Query=LONG(WINAPI*)(HANDLE,const void*,int,void*,SIZE_T,SIZE_T*);
    auto query=reinterpret_cast<Query>(GetProcAddress(ntdll,"NtQueryVirtualMemory"));
#ifdef __arm64ec__
    auto slot=GetProcAddress(ntdll,"__wine_unix_call_dispatcher_arm64ec");
#else
    auto slot=GetProcAddress(ntdll,"__wine_unix_call_dispatcher");
#endif
    if(!query||!slot||query(GetCurrentProcess(),self,1000,&unixHandle,sizeof(unixHandle),nullptr)<0)return;
    unixCall=*reinterpret_cast<UnixCall*>(slot);
    wvr_video_unix_dispatcher=unixCall;
}
static WVRVideoCall call(uint64_t stream=0) { WVRVideoCall c{};c.version=WVR_VIDEO_ABI;c.size=sizeof(c);c.stream=stream;return c; }
static bool invoke(unsigned index,WVRVideoCall& c) {
    std::call_once(unixOnce,initializeUnix);
    if(!unixCall || !unixHandle)return false;
#ifdef __arm64ec__
    return wvr_video_unix_native(unixHandle,index,&c)>=0;
#else
    return unixCall(unixHandle,index,&c)>=0;
#endif
}
extern "C" __declspec(dllexport) int WVRVideoCallV1(unsigned index,WVRVideoCall* c) {
    return c && index<WVR_VIDEO_CALL_COUNT && invoke(index,*c) ? 0 : -1;
}
static AMF_RESULT translate(int result) {
    switch(result) {
    case WVR_VIDEO_OK:return AMF_OK;
    case WVR_VIDEO_NO_FRAME:return AMF_REPEAT;
    case WVR_VIDEO_QUEUE_FULL:return AMF_INPUT_FULL;
    case WVR_VIDEO_CLOSED:return AMF_NOT_INITIALIZED;
    case WVR_VIDEO_UNSUPPORTED:return AMF_NOT_SUPPORTED;
    case WVR_VIDEO_INVALID:return AMF_INVALID_ARG;
    default:return AMF_FAIL;
    }
}
template<class Interface> struct Object : Interface {
    std::atomic<amf_long> references{1};
    virtual ~Object()=default;
    amf_long AMF_STD_CALL Acquire() override{return ++references;}
    amf_long AMF_STD_CALL Release() override{auto n=--references;if(!n)delete this;return n;}
    AMF_RESULT AMF_STD_CALL QueryInterface(const AMFGuid& iid,void** out) override {
        if(!out)return AMF_INVALID_POINTER;*out=nullptr;
        bool supported=iid==Interface::IID()||iid==AMFInterface::IID();
        if constexpr(std::is_base_of_v<AMFPropertyStorage,Interface>)supported|=iid==AMFPropertyStorage::IID();
        if constexpr(std::is_base_of_v<AMFData,Interface>)supported|=iid==AMFData::IID();
        if constexpr(std::is_base_of_v<AMFPropertyStorageEx,Interface>)supported|=iid==AMFPropertyStorageEx::IID();
        if(!supported)return AMF_NO_INTERFACE;*out=static_cast<Interface*>(this);Acquire();return AMF_OK;
    }
};
template<class Interface> struct Properties : Object<Interface> {
    using Object<Interface>::AddObserver;
    using Object<Interface>::RemoveObserver;
    AMF_RESULT AMF_STD_CALL SetProperty(const wchar_t*,AMFVariantStruct) override{return AMF_NOT_FOUND;}
    AMF_RESULT AMF_STD_CALL GetProperty(const wchar_t*,AMFVariantStruct* value) const override{if(value)AMFVariantInit(value);return value?AMF_NOT_FOUND:AMF_INVALID_POINTER;}
    amf_bool AMF_STD_CALL HasProperty(const wchar_t*) const override{return false;}
    amf_size AMF_STD_CALL GetPropertyCount() const override{return 0;}
    AMF_RESULT AMF_STD_CALL GetPropertyAt(amf_size,wchar_t* name,amf_size size,AMFVariantStruct* value) const override{
        if(name&&size)*name=0;if(value)AMFVariantInit(value);return AMF_OUT_OF_RANGE;}
    AMF_RESULT AMF_STD_CALL Clear() override{return AMF_OK;}
    AMF_RESULT AMF_STD_CALL AddTo(AMFPropertyStorage* dest,amf_bool,amf_bool) const override{return dest?AMF_OK:AMF_INVALID_POINTER;}
    AMF_RESULT AMF_STD_CALL CopyTo(AMFPropertyStorage* dest,amf_bool) const override{return dest?dest->Clear():AMF_INVALID_POINTER;}
    void AMF_STD_CALL AddObserver(AMFPropertyStorageObserver*) override{}
    void AMF_STD_CALL RemoveObserver(AMFPropertyStorageObserver*) override{}
};
template<class Interface> struct Data : Properties<Interface> {
    AMF_MEMORY_TYPE memory;amf_pts pts=0,duration=0;
    explicit Data(AMF_MEMORY_TYPE type):memory(type){}
    AMF_MEMORY_TYPE AMF_STD_CALL GetMemoryType() override{return memory;}
    AMF_RESULT AMF_STD_CALL Duplicate(AMF_MEMORY_TYPE,AMFData** out) override{if(out)*out=nullptr;return out?AMF_NOT_SUPPORTED:AMF_INVALID_POINTER;}
    AMF_RESULT AMF_STD_CALL Convert(AMF_MEMORY_TYPE type) override{return type==memory?AMF_OK:AMF_NOT_SUPPORTED;}
    AMF_RESULT AMF_STD_CALL Interop(AMF_MEMORY_TYPE type) override{return Convert(type);}
    amf_bool AMF_STD_CALL IsReusable() override{return false;}
    void AMF_STD_CALL SetPts(amf_pts value) override{pts=value;}
    amf_pts AMF_STD_CALL GetPts() override{return pts;}
    void AMF_STD_CALL SetDuration(amf_pts value) override{duration=value;}
    amf_pts AMF_STD_CALL GetDuration() override{return duration;}
};
struct Buffer final : Data<AMFBuffer> {
    using Data<AMFBuffer>::AddObserver;
    using Data<AMFBuffer>::RemoveObserver;
    std::vector<uint8_t> owned;void* bytes;size_t size;std::vector<AMFBufferObserver*> observers;
    Buffer(void* data,size_t n):Data(AMF_MEMORY_HOST),bytes(data),size(n){}
    explicit Buffer(size_t n):Data(AMF_MEMORY_HOST),owned(n),bytes(owned.data()),size(n){}
    ~Buffer(){for(auto* o:observers)o->OnBufferDataRelease(this);}
    AMF_DATA_TYPE AMF_STD_CALL GetDataType() override{return AMF_DATA_BUFFER;}
    AMF_RESULT AMF_STD_CALL SetSize(amf_size n) override{
        if(owned.empty())return n==size?AMF_OK:AMF_NOT_SUPPORTED;
        if(n>WVR_VIDEO_MAX_PACKET)return AMF_OUT_OF_RANGE;owned.resize(n);bytes=owned.data();size=n;return AMF_OK;}
    amf_size AMF_STD_CALL GetSize() override{return size;}
    void* AMF_STD_CALL GetNative() override{return bytes;}
    void AMF_STD_CALL AddObserver(AMFBufferObserver* o) override{if(o&&std::find(observers.begin(),observers.end(),o)==observers.end())observers.push_back(o);}
    void AMF_STD_CALL RemoveObserver(AMFBufferObserver* o) override{std::erase(observers,o);}
};
struct Plane final : Object<AMFPlane> {
    VideoFrame* frame;unsigned index;
    Plane(VideoFrame* value,unsigned i):frame(value),index(i){frame->AddRef();}
    ~Plane(){frame->Release();}
    AMF_PLANE_TYPE AMF_STD_CALL GetType() override{return index?AMF_PLANE_UV:AMF_PLANE_Y;}
    void* AMF_STD_CALL GetNative() override{return static_cast<ID3D11Texture2D*>(frame);}
    amf_int32 AMF_STD_CALL GetPixelSizeInBytes() override{return index?2:1;}
    amf_int32 AMF_STD_CALL GetOffsetX() override{return 0;}
    amf_int32 AMF_STD_CALL GetOffsetY() override{return 0;}
    amf_int32 AMF_STD_CALL GetWidth() override{return frame->description.Width/(index?2:1);}
    amf_int32 AMF_STD_CALL GetHeight() override{return frame->description.Height/(index?2:1);}
    amf_int32 AMF_STD_CALL GetHPitch() override{return frame->description.Width;}
    amf_int32 AMF_STD_CALL GetVPitch() override{return GetHeight();}
    bool AMF_STD_CALL IsTiled() override{return false;}
};
struct Surface final : Data<AMFSurface> {
    using Data<AMFSurface>::AddObserver;
    using Data<AMFSurface>::RemoveObserver;
    Plane *y,*uv;AMF_FRAME_TYPE frameType=AMF_FRAME_PROGRESSIVE;std::vector<AMFSurfaceObserver*> observers;
    explicit Surface(VideoFrame* value):Data(AMF_MEMORY_DX11),y(new Plane(value,0)),uv(new Plane(value,1)){}
    ~Surface(){for(auto* o:observers)o->OnSurfaceDataRelease(this);y->Release();uv->Release();}
    AMF_DATA_TYPE AMF_STD_CALL GetDataType() override{return AMF_DATA_SURFACE;}
    AMF_SURFACE_FORMAT AMF_STD_CALL GetFormat() override{return AMF_SURFACE_NV12;}
    amf_size AMF_STD_CALL GetPlanesCount() override{return 2;}
    AMFPlane* AMF_STD_CALL GetPlaneAt(amf_size i) override{return i==0?y:i==1?uv:nullptr;}
    AMFPlane* AMF_STD_CALL GetPlane(AMF_PLANE_TYPE type) override{return type==AMF_PLANE_Y?y:type==AMF_PLANE_UV?uv:nullptr;}
    AMF_FRAME_TYPE AMF_STD_CALL GetFrameType() override{return frameType;}
    void AMF_STD_CALL SetFrameType(AMF_FRAME_TYPE type) override{frameType=type;}
    AMF_RESULT AMF_STD_CALL SetCrop(amf_int32,amf_int32,amf_int32,amf_int32) override{return AMF_NOT_SUPPORTED;}
    AMF_RESULT AMF_STD_CALL CopySurfaceRegion(AMFSurface*,amf_int32,amf_int32,amf_int32,amf_int32,amf_int32,amf_int32) override{return AMF_NOT_SUPPORTED;}
    void AMF_STD_CALL AddObserver(AMFSurfaceObserver* o) override{if(o&&std::find(observers.begin(),observers.end(),o)==observers.end())observers.push_back(o);}
    void AMF_STD_CALL RemoveObserver(AMFSurfaceObserver* o) override{std::erase(observers,o);}
};
#include "ContextFallback.hpp"
struct Context final : ContextFallback {
    ID3D11Device* device=nullptr;std::recursive_mutex dx11;
    ~Context(){Terminate();}
    AMF_RESULT AMF_STD_CALL Terminate() override{if(device){device->Release();device=nullptr;}return AMF_OK;}
    AMF_RESULT AMF_STD_CALL InitDX11(void* value,AMF_DX_VERSION version) override{
        if(!value)return AMF_INVALID_POINTER;if(version>AMF_DX11_1)return AMF_NOT_SUPPORTED;
        auto* next=static_cast<ID3D11Device*>(value);next->AddRef();Terminate();device=next;return AMF_OK;}
    void* AMF_STD_CALL GetDX11Device(AMF_DX_VERSION version) override{return version<=AMF_DX11_1?device:nullptr;}
    AMF_RESULT AMF_STD_CALL LockDX11() override{dx11.lock();return AMF_OK;}
    AMF_RESULT AMF_STD_CALL UnlockDX11() override{dx11.unlock();return AMF_OK;}
    AMF_RESULT AMF_STD_CALL AllocBuffer(AMF_MEMORY_TYPE type,amf_size size,AMFBuffer** out) override{
        if(!out)return AMF_INVALID_POINTER;*out=nullptr;if(type!=AMF_MEMORY_HOST)return AMF_NOT_SUPPORTED;
        if(!size||size>WVR_VIDEO_MAX_PACKET)return AMF_INVALID_ARG;*out=new Buffer(size);return AMF_OK;}
    AMF_RESULT AMF_STD_CALL CreateBufferFromHostNative(void* data,amf_size size,AMFBuffer** out,AMFBufferObserver* observer) override{
        if(!out)return AMF_INVALID_POINTER;*out=nullptr;if(!data||!size||size>WVR_VIDEO_MAX_PACKET)return AMF_INVALID_ARG;
        auto* buffer=new Buffer(data,size);buffer->AddObserver(observer);*out=buffer;return AMF_OK;}
};
struct Component final : Properties<AMFComponent> {
    Context* context;uint64_t stream=0,lastDecoded=0;std::mutex operations;bool draining=false;
    explicit Component(Context* value):context(value){context->Acquire();}
    ~Component(){Terminate();context->Release();}
    AMF_RESULT AMF_STD_CALL Init(AMF_SURFACE_FORMAT format,amf_int32 width,amf_int32 height) override{
        std::lock_guard lock(operations);if(stream)return AMF_ALREADY_INITIALIZED;
        if(format!=AMF_SURFACE_NV12)return AMF_NOT_SUPPORTED;if(!context->device)return AMF_NOT_INITIALIZED;
        auto c=call();c.width=width;c.height=height;if(!invoke(WVR_VIDEO_OPEN,c))return AMF_FAIL;
        if(c.result==WVR_VIDEO_OK){stream=c.stream;lastDecoded=0;draining=false;}return translate(c.result);}
    AMF_RESULT AMF_STD_CALL ReInit(amf_int32 width,amf_int32 height) override{Terminate();return Init(AMF_SURFACE_NV12,width,height);}
    AMF_RESULT AMF_STD_CALL Terminate() override{
        std::lock_guard lock(operations);if(stream){auto c=call(stream);invoke(WVR_VIDEO_CLOSE,c);stream=0;}draining=false;return AMF_OK;}
    AMF_RESULT AMF_STD_CALL Drain() override{std::lock_guard lock(operations);if(!stream)return AMF_NOT_INITIALIZED;draining=true;return AMF_OK;}
    AMF_RESULT AMF_STD_CALL Flush() override{
        std::lock_guard lock(operations);if(!stream)return AMF_NOT_INITIALIZED;auto c=call(stream);draining=false;return invoke(WVR_VIDEO_FLUSH,c)?translate(c.result):AMF_FAIL;}
    AMF_RESULT AMF_STD_CALL SubmitInput(AMFData* data) override{
        std::lock_guard lock(operations);if(!stream)return AMF_NOT_INITIALIZED;if(draining)return AMF_EOF;
        if(!data){draining=true;return AMF_OK;}AMFBuffer* buffer=nullptr;
        if(data->QueryInterface(AMFBuffer::IID(),reinterpret_cast<void**>(&buffer))!=AMF_OK)return AMF_INVALID_DATA_TYPE;
        auto c=call(stream);c.input=reinterpret_cast<uint64_t>(buffer->GetNative());c.inputSize=buffer->GetSize();c.pts=buffer->GetPts();
        std::vector<wvr::video::NAL> nals;bool picture=false;
        if(!wvr::video::splitAnnexB(static_cast<const uint8_t*>(buffer->GetNative()),buffer->GetSize(),nals)){buffer->Release();return AMF_INVALID_ARG;}
        for(auto nal:nals)if(nal.type>=1 && nal.type<=5)picture=true;
        bool success=invoke(WVR_VIDEO_SUBMIT,c);buffer->Release();if(!success)return AMF_FAIL;
        if(c.result==WVR_VIDEO_NO_FRAME)return AMF_NEED_MORE_INPUT;
        if(c.result!=WVR_VIDEO_OK)return translate(c.result);
        // BigSoup blocks in QueryOutput after a successful SubmitInput. Its
        // SPS/PPS-only packets, and pictures held for reference/reordering,
        // must request more input instead of promising an output picture.
        if(!picture || c.framesDecoded<=lastDecoded)return AMF_NEED_MORE_INPUT;
        lastDecoded=c.framesDecoded;return AMF_OK;}
    AMF_RESULT AMF_STD_CALL QueryOutput(AMFData** out) override{
        if(!out)return AMF_INVALID_POINTER;*out=nullptr;std::lock_guard lock(operations);if(!stream)return AMF_NOT_INITIALIZED;
        auto c=call(stream);if(!invoke(WVR_VIDEO_READ,c))return AMF_FAIL;
        if(c.result==WVR_VIDEO_NO_FRAME)return draining?AMF_EOF:AMF_REPEAT;
        if(c.result!=WVR_VIDEO_BUFFER_TOO_SMALL)return translate(c.result);
        if(!c.width||!c.height||c.width>WVR_VIDEO_MAX_DIMENSION||c.height>WVR_VIDEO_MAX_DIMENSION||c.width%2||c.height%2)return AMF_NOT_SUPPORTED;
        std::vector<uint8_t> y(size_t(c.width)*c.height),uv(size_t(c.width)*c.height/2);
        c.y=reinterpret_cast<uint64_t>(y.data());c.uv=reinterpret_cast<uint64_t>(uv.data());c.yPitch=c.uvPitch=c.width;c.yCapacity=y.size();c.uvCapacity=uv.size();
        if(!invoke(WVR_VIDEO_READ,c)||c.result!=WVR_VIDEO_OK)return AMF_FAIL;
        VideoFrame* frame=nullptr;HRESULT hr=VideoFrame::create(context->device,c.width,c.height,y.data(),uv.data(),&frame);
        if(FAILED(hr))return AMF_DIRECTX_FAILED;auto* surface=new Surface(frame);frame->Release();surface->SetPts(c.pts);*out=surface;return AMF_OK;
    }
    AMFContext* AMF_STD_CALL GetContext() override{return context;}
    AMF_RESULT AMF_STD_CALL SetOutputDataAllocatorCB(AMFDataAllocatorCB*) override{return AMF_NOT_SUPPORTED;}
    AMF_RESULT AMF_STD_CALL GetCaps(AMFCaps** out) override{if(out)*out=nullptr;return out?AMF_NOT_SUPPORTED:AMF_INVALID_POINTER;}
    AMF_RESULT AMF_STD_CALL Optimize(AMFComponentOptimizationCallback*) override{return AMF_NOT_SUPPORTED;}
    amf_size AMF_STD_CALL GetPropertiesInfoCount() const override{return 0;}
    AMF_RESULT AMF_STD_CALL GetPropertyInfo(amf_size,const AMFPropertyInfo** out) const override{if(out)*out=nullptr;return out?AMF_NOT_FOUND:AMF_INVALID_POINTER;}
    AMF_RESULT AMF_STD_CALL GetPropertyInfo(const wchar_t*,const AMFPropertyInfo** out) const override{if(out)*out=nullptr;return out?AMF_NOT_FOUND:AMF_INVALID_POINTER;}
    AMF_RESULT AMF_STD_CALL ValidateProperty(const wchar_t*,AMFVariantStruct,AMFVariantStruct* out) const override{if(out)AMFVariantInit(out);return out?AMF_NOT_FOUND:AMF_INVALID_POINTER;}
};
struct Factory final : AMFFactory {
    AMF_RESULT AMF_STD_CALL CreateContext(AMFContext** out) override{if(!out)return AMF_INVALID_POINTER;*out=new Context;return AMF_OK;}
    AMF_RESULT AMF_STD_CALL CreateComponent(AMFContext* value,const wchar_t* id,AMFComponent** out) override{
        if(!out)return AMF_INVALID_POINTER;*out=nullptr;if(!value||!id)return AMF_INVALID_POINTER;
        if(wcscmp(id,L"AMFVideoDecoderUVD_H264_AVC"))return AMF_NOT_SUPPORTED;
        auto* context=dynamic_cast<Context*>(value);if(!context)return AMF_INVALID_ARG;*out=new Component(context);return AMF_OK;}
    AMF_RESULT AMF_STD_CALL SetCacheFolder(const wchar_t*) override{return AMF_NOT_SUPPORTED;}
    const wchar_t* AMF_STD_CALL GetCacheFolder() override{return L"";}
    AMF_RESULT AMF_STD_CALL GetDebug(AMFDebug** out) override{if(out)*out=nullptr;return AMF_NOT_SUPPORTED;}
    AMF_RESULT AMF_STD_CALL GetTrace(AMFTrace** out) override{if(out)*out=nullptr;return AMF_NOT_SUPPORTED;}
    AMF_RESULT AMF_STD_CALL GetPrograms(AMFPrograms** out) override{if(out)*out=nullptr;return AMF_NOT_SUPPORTED;}
};
extern "C" __declspec(dllexport) AMF_RESULT AMF_CDECL_CALL AMFInit(amf_uint64 version,AMFFactory** out) {
    if(!out)return AMF_INVALID_POINTER;*out=nullptr;
    if((version>>48)!=1)return AMF_NOT_SUPPORTED;
    static Factory factory;*out=&factory;return AMF_OK;
}
extern "C" __declspec(dllexport) AMF_RESULT AMF_CDECL_CALL AMFQueryVersion(amf_uint64* out) {
    if(!out)return AMF_INVALID_POINTER;*out=0x0001000400090000ULL;return AMF_OK;
}
extern "C" __declspec(dllexport) ID3D11Device* WVRWrapD3D11DeviceV1(ID3D11Device* real) {
    if(!real)return nullptr;
    struct Cache{std::mutex lock;std::vector<VideoDevice*> devices;~Cache(){for(auto* d:devices)d->Release();}};
    static Cache cache;std::lock_guard guard(cache.lock);
    for(auto* d:cache.devices)if(d->real==real||d==real)return d;
    auto* device=new VideoDevice(real);cache.devices.push_back(device);return device;
}
extern "C" __declspec(dllexport) ID3D11Device* WVRCreateD3D11DeviceAdapterV1(ID3D11Device* real) {
    // An owned reference for a newly created decoder device. It is released
    // with that stream; no per-stream device remains pinned in the Unity cache.
    return real?new VideoDevice(real):nullptr;
}
