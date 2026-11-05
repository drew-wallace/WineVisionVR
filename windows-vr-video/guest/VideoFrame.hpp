#pragma once
#include "VideoDevice.hpp"
#include <mutex>
#include <unordered_map>

// An NV12 resource whose two planes are real, independent D3D11 textures.
// The adapter device turns plane SRVs into ordinary DXMT SRVs. No decoder
// bind flags, NV12 texture layout, or multi-plane Metal view is fabricated.
struct VideoFrame final : ID3D11Texture2D {
    inline static std::mutex registryMutex;
    inline static std::unordered_map<ID3D11Resource*,VideoFrame*> registry;
    std::atomic<ULONG> references{1};
    ID3D11Device* device;
    ID3D11Texture2D *y=nullptr,*uv=nullptr;
    D3D11_TEXTURE2D_DESC description{};
    explicit VideoFrame(ID3D11Device* value):device(value) { device->AddRef(); }
    ~VideoFrame() {
        { std::lock_guard lock(registryMutex);registry.erase(static_cast<ID3D11Resource*>(this)); }
        if(y)y->Release();if(uv)uv->Release();device->Release();
    }
    static HRESULT create(ID3D11Device* device,UINT width,UINT height,const uint8_t* luma,const uint8_t* chroma,VideoFrame** out) {
        if(!out)return E_POINTER;*out=nullptr;
        auto* frame=new VideoFrame(device);
        D3D11_TEXTURE2D_DESC d{};d.Width=width;d.Height=height;d.MipLevels=d.ArraySize=d.SampleDesc.Count=1;
        d.Format=DXGI_FORMAT_R8_UNORM;d.Usage=D3D11_USAGE_IMMUTABLE;d.BindFlags=D3D11_BIND_SHADER_RESOURCE;
        D3D11_SUBRESOURCE_DATA data{luma,width,0};
        HRESULT hr=device->CreateTexture2D(&d,&data,&frame->y);
        d.Width=width/2;d.Height=height/2;d.Format=DXGI_FORMAT_R8G8_UNORM;data.pSysMem=chroma;
        if(SUCCEEDED(hr))hr=device->CreateTexture2D(&d,&data,&frame->uv);
        if(FAILED(hr)){frame->Release();return hr;}
        frame->description=d;frame->description.Width=width;frame->description.Height=height;frame->description.Format=DXGI_FORMAT_NV12;
        {std::lock_guard lock(registryMutex);registry.emplace(static_cast<ID3D11Resource*>(frame),frame);}
        *out=frame;return S_OK;
    }
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid,void** out) override {
        if(!out)return E_POINTER;*out=nullptr;
        if(iid==__uuidof(IUnknown)||iid==__uuidof(ID3D11DeviceChild)||iid==__uuidof(ID3D11Resource)||iid==__uuidof(ID3D11Texture2D)) {
            *out=static_cast<ID3D11Texture2D*>(this);AddRef();return S_OK;
        }return E_NOINTERFACE;
    }
    ULONG STDMETHODCALLTYPE AddRef() override{return ++references;}
    ULONG STDMETHODCALLTYPE Release() override{
        ULONG n;
        {std::lock_guard lock(registryMutex);n=--references;if(!n)registry.erase(static_cast<ID3D11Resource*>(this));}
        if(!n)delete this;return n;
    }
    void STDMETHODCALLTYPE GetDevice(ID3D11Device** out) override{if(out){*out=device;device->AddRef();}}
    HRESULT STDMETHODCALLTYPE GetPrivateData(REFGUID guid,UINT* size,void* data) override{return y->GetPrivateData(guid,size,data);}
    HRESULT STDMETHODCALLTYPE SetPrivateData(REFGUID guid,UINT size,const void* data) override{return y->SetPrivateData(guid,size,data);}
    HRESULT STDMETHODCALLTYPE SetPrivateDataInterface(REFGUID guid,const IUnknown* data) override{return y->SetPrivateDataInterface(guid,data);}
    void STDMETHODCALLTYPE GetType(D3D11_RESOURCE_DIMENSION* out) override{if(out)*out=D3D11_RESOURCE_DIMENSION_TEXTURE2D;}
    void STDMETHODCALLTYPE SetEvictionPriority(UINT p) override{y->SetEvictionPriority(p);uv->SetEvictionPriority(p);}
    UINT STDMETHODCALLTYPE GetEvictionPriority() override{return y->GetEvictionPriority();}
    void STDMETHODCALLTYPE GetDesc(D3D11_TEXTURE2D_DESC* out) override{if(out)*out=description;}
};
inline HRESULT VideoDevice::CreateShaderResourceView(ID3D11Resource* resource,const D3D11_SHADER_RESOURCE_VIEW_DESC* desc,ID3D11ShaderResourceView** out) {
    VideoFrame* frame=nullptr;
    { std::lock_guard lock(VideoFrame::registryMutex);auto it=VideoFrame::registry.find(resource);
      if(it!=VideoFrame::registry.end()){frame=it->second;frame->AddRef();} }
    if(!frame)return real->CreateShaderResourceView(resource,desc,out);
    if(out)*out=nullptr;
    HRESULT hr=E_INVALIDARG;
    if(desc && desc->ViewDimension==D3D11_SRV_DIMENSION_TEXTURE2D && desc->Texture2D.MostDetailedMip==0 &&
       (desc->Texture2D.MipLevels==1 || desc->Texture2D.MipLevels==UINT(-1))) {
        auto* plane=desc->Format==DXGI_FORMAT_R8_UNORM ? frame->y : desc->Format==DXGI_FORMAT_R8G8_UNORM ? frame->uv : nullptr;
        if(plane)hr=real->CreateShaderResourceView(plane,desc,out);
    }
    frame->Release();return hr;
}
