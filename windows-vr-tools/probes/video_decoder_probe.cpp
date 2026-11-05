#include <windows.h>
#include <d3d11.h>
#include <cstdio>
#include <cstdlib>
#include <vector>
#include <algorithm>
#include "WindowsVRH264AnnexB.hpp"
#include "core/Factory.h"
using namespace amf;
static FILE* logFile;
static void check(bool ok,const char* message) {
    fprintf(logFile,"%s %s\n",ok?"PASS":"FAIL",message);fflush(logFile);
    if(!ok){fprintf(logFile,"RESULT FAIL\n");fclose(logFile);ExitProcess(1);}
}
int main() {
    logFile=fopen("mapping-result.txt","w");if(!logFile)return 2;
    fprintf(logFile,"START video-decoder run=%s\n",getenv("WINEVISION_PROBE_RUN_ID")?:"missing");fflush(logFile);
    HMODULE dll=LoadLibraryW(L"amfrt64.dll");check(dll,"load AMF compatibility adapter");
    auto init=reinterpret_cast<AMFInit_Fn>(GetProcAddress(dll,"AMFInit"));check(init,"resolve factory");
    AMFFactory* factory=nullptr;check(init(0x0001000400000000ULL,&factory)==AMF_OK && factory,"create factory");
    ID3D11Device* real=nullptr;ID3D11DeviceContext* commands=nullptr;
    check(SUCCEEDED(D3D11CreateDevice(nullptr,D3D_DRIVER_TYPE_HARDWARE,nullptr,0,nullptr,0,D3D11_SDK_VERSION,&real,nullptr,&commands)),"create real D3D11 device");
    using Wrap=ID3D11Device*(*)(ID3D11Device*);
    auto wrap=reinterpret_cast<Wrap>(GetProcAddress(dll,"WVRWrapD3D11DeviceV1"));check(wrap,"resolve planar device adapter");
    ID3D11Device* device=wrap(real);check(device,"wrap streaming device");
    AMFContext* context=nullptr;check(factory->CreateContext(&context)==AMF_OK && context,"create AMF context");
    check(context->InitDX11(device,AMF_DX11_0)==AMF_OK,"initialize DX11 context");
    AMFComponent* component=nullptr;
    check(factory->CreateComponent(context,L"unsupported-codec",&component)==AMF_NOT_SUPPORTED && !component,"unsupported codec rejected");
    check(factory->CreateComponent(context,L"AMFVideoDecoderUVD_H264_AVC",&component)==AMF_OK && component,"create H264 component");
    AMF_RESULT status=component->Init(AMF_SURFACE_NV12,32,32);
    fprintf(logFile,"Init status=%d\n",int(status));fflush(logFile);check(status==AMF_OK,"open native H264 transport");
    FILE* fixture=fopen("red32.h264","rb");check(fixture,"open encoded fixture");fseek(fixture,0,SEEK_END);long size=ftell(fixture);rewind(fixture);
    std::vector<unsigned char> bytes(size);check(fread(bytes.data(),1,bytes.size(),fixture)==bytes.size(),"read encoded fixture");fclose(fixture);
    for(int cycle=0;cycle<3;++cycle) {
        AMFBuffer* input=nullptr;check(context->CreateBufferFromHostNative(bytes.data(),bytes.size(),&input,nullptr)==AMF_OK,"wrap packet");input->SetPts(100+cycle);
        status=component->SubmitInput(input);input->Release();fprintf(logFile,"Submit status=%d\n",int(status));fflush(logFile);check(status==AMF_OK,"decode real H264 packet");
        AMFData* output=nullptr;check(component->QueryOutput(&output)==AMF_OK && output,"receive decoded surface");
        check(output->GetPts()==100+cycle && output->GetMemoryType()==AMF_MEMORY_DX11,"preserve timestamp and memory contract");
        AMFSurface* surface=nullptr;check(output->QueryInterface(AMFSurface::IID(),reinterpret_cast<void**>(&surface))==AMF_OK,"surface interface");output->Release();
        check(surface->GetFormat()==AMF_SURFACE_NV12 && surface->GetPlanesCount()==2,"NV12 planes");
        auto* resource=static_cast<ID3D11Texture2D*>(surface->GetPlaneAt(0)->GetNative());
        for(unsigned plane=0;plane<2;++plane) {
            D3D11_SHADER_RESOURCE_VIEW_DESC view{};view.Format=plane?DXGI_FORMAT_R8G8_UNORM:DXGI_FORMAT_R8_UNORM;view.ViewDimension=D3D11_SRV_DIMENSION_TEXTURE2D;view.Texture2D.MipLevels=1;
            ID3D11ShaderResourceView* srv=nullptr;check(SUCCEEDED(device->CreateShaderResourceView(resource,&view,&srv))&&srv,"create real GPU plane SRV");
            ID3D11Resource* texture=nullptr;srv->GetResource(&texture);srv->Release();ID3D11Texture2D* typed=nullptr;
            check(SUCCEEDED(texture->QueryInterface(IID_PPV_ARGS(&typed))),"plane GPU texture");texture->Release();D3D11_TEXTURE2D_DESC desc{};typed->GetDesc(&desc);
            check(desc.Width==(plane?16u:32u) && desc.Height==(plane?16u:32u) && desc.Format==view.Format,"plane extent and format");
            desc.Usage=D3D11_USAGE_STAGING;desc.BindFlags=desc.MiscFlags=0;desc.CPUAccessFlags=D3D11_CPU_ACCESS_READ;ID3D11Texture2D* staging=nullptr;
            check(SUCCEEDED(real->CreateTexture2D(&desc,nullptr,&staging)),"create plane readback");commands->CopyResource(staging,typed);typed->Release();D3D11_MAPPED_SUBRESOURCE pixels{};
            check(SUCCEEDED(commands->Map(staging,0,D3D11_MAP_READ,0,&pixels)) && pixels.pData,"read real GPU plane pixels");
            bool valid=true;for(unsigned y=0;y<desc.Height;++y)for(unsigned x=0;x<32;++x) {
                unsigned value=static_cast<unsigned char*>(pixels.pData)[y*pixels.RowPitch+x],expected=plane?(x%2?240:90):82;
                if(value+4<expected || value>expected+4)valid=false;
            }
            commands->Unmap(staging,0);staging->Release();check(valid,"decoded H264 pixels reached GPU");
        }
        surface->Release();AMFData* empty=reinterpret_cast<AMFData*>(1);check(component->QueryOutput(&empty)==AMF_REPEAT && !empty,"empty queue returns repeat");
        check(component->Flush()==AMF_OK,"flush decoder");
    }
    check(component->Terminate()==AMF_OK,"close decoder");component->Release();context->Release();commands->Release();real->Release();
    HMODULE proxy=LoadLibraryW(L"BigSoup.dll");check(proxy,"load streaming plugin adapter");
    auto* image=reinterpret_cast<unsigned char*>(proxy);
    auto* header=reinterpret_cast<IMAGE_NT_HEADERS64*>(image+reinterpret_cast<IMAGE_DOS_HEADER*>(image)->e_lfanew);
    auto* exports=reinterpret_cast<IMAGE_EXPORT_DIRECTORY*>(image+header->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_EXPORT].VirtualAddress);
    auto* names=reinterpret_cast<DWORD*>(image+exports->AddressOfNames);
    bool all=true;for(DWORD i=0;i<exports->NumberOfNames;++i) {
        auto* name=reinterpret_cast<const char*>(image+names[i]);
        if(!GetProcAddress(proxy,name)){fprintf(logFile,"Unresolved export %s error=%lu\n",name,GetLastError());all=false;}
    }
    check(all && exports->NumberOfNames>=93,"resolve original plugin exports and data through forwarder");
    using Prepare=int(*)();auto prepare=reinterpret_cast<Prepare>(GetProcAddress(proxy,"WVRBigSoupVideoPrepareV1"));
    check(prepare && prepare()==7,"initialize original plugin AMF factory, device creation and decoder selection");
    check(prepare()==7,"plugin preparation is idempotent");
    // Exercise BigSoup's actual AMD decoder, including its separate device,
    // AMF calls, shaders and double-buffered output. This fixture has no room,
    // sockets, microphone stream, or running game.
    auto* original=reinterpret_cast<unsigned char*>(GetModuleHandleW(L"wvr_bigsoup_original.dll"));
    check(original,"locate original decoder image");
    ID3D11Device* fixtureDevice=nullptr;ID3D11DeviceContext* fixtureCommands=nullptr;
    check(SUCCEEDED(D3D11CreateDevice(nullptr,D3D_DRIVER_TYPE_HARDWARE,nullptr,0,nullptr,0,D3D11_SDK_VERSION,&fixtureDevice,nullptr,&fixtureCommands)),"create fixture adapter device");
    IDXGIDevice* dxgi=nullptr;IDXGIAdapter* adapter=nullptr;
    check(SUCCEEDED(fixtureDevice->QueryInterface(IID_PPV_ARGS(&dxgi))) && SUCCEEDED(dxgi->GetAdapter(&adapter)),"fixture DXGI adapter");dxgi->Release();
    std::vector<unsigned char> owner(0x21400);
    *reinterpret_cast<IDXGIAdapter**>(owner.data()+0x213e8)=adapter;
    auto** ownerSlot=reinterpret_cast<void**>(original+0x35bac0);void* previousOwner=*ownerSlot;*ownerSlot=owner.data();
    alignas(16) unsigned char decoder[0x210]{};
    *reinterpret_cast<unsigned*>(decoder+0xe4)=32;*reinterpret_cast<unsigned*>(decoder+0xe8)=32;
    using MutexInit=void*(*)(void*);auto mutexInit=reinterpret_cast<MutexInit>(original+0x95780);
    mutexInit(decoder+0x40);mutexInit(decoder+0x90);
    using DecoderInit=int(*)(void*);int initialized=reinterpret_cast<DecoderInit>(original+0x8f480)(decoder);
    fprintf(logFile,"Original decoder init=%d\n",initialized);fflush(logFile);
    check(initialized!=-1 && *reinterpret_cast<void**>(decoder+0x1a8) && *reinterpret_cast<void**>(decoder+0x30),"original decoder allocates packet buffer and initializes component");
    using Decode=int(*)(void*,const void*,unsigned);
    std::vector<wvr::video::NAL> nals;check(wvr::video::splitAnnexB(bytes.data(),bytes.size(),nals),"split original decoder packets");
    for(auto nal:nals) {
        std::vector<unsigned char> packet{0,0,0,1};packet.insert(packet.end(),nal.data,nal.data+nal.size);
        fprintf(logFile,"Original decoder submitting NAL=%u bytes=%zu\n",nal.type,packet.size());fflush(logFile);
        reinterpret_cast<Decode>(original+0x8ecf0)(decoder,packet.data(),unsigned(packet.size()));
    }
    check(decoder[0]!=0,"original decoder publishes a rendered frame");
    auto* decoderDevice=*reinterpret_cast<ID3D11Device**>(decoder+0x100);
    auto* decoderCommands=*reinterpret_cast<ID3D11DeviceContext**>(decoder+0x108);
    unsigned rendered=decoder[0xe0]?0:1;
    for(unsigned plane=0;plane<2;++plane) {
        auto* texture=*reinterpret_cast<ID3D11Texture2D**>(decoder+(plane?0x120:0x110)+rendered*8);
        check(texture,"original decoder output texture");D3D11_TEXTURE2D_DESC desc{};texture->GetDesc(&desc);
        fprintf(logFile,"Original output plane=%u width=%u height=%u format=%u\n",plane,desc.Width,desc.Height,unsigned(desc.Format));fflush(logFile);
        check(desc.Width==32 && desc.Height==(plane?16u:32u),"original output plane extent");
        desc.Usage=D3D11_USAGE_STAGING;desc.BindFlags=desc.MiscFlags=0;desc.CPUAccessFlags=D3D11_CPU_ACCESS_READ;
        ID3D11Texture2D* staging=nullptr;check(SUCCEEDED(decoderDevice->CreateTexture2D(&desc,nullptr,&staging)),"original output staging texture");
        decoderCommands->CopyResource(staging,texture);D3D11_MAPPED_SUBRESOURCE pixels{};
        check(SUCCEEDED(decoderCommands->Map(staging,0,D3D11_MAP_READ,0,&pixels)),"read original decoder GPU output");
        bool valid=true;unsigned low=255,high=0;
        for(unsigned row=0;row<desc.Height;++row)for(unsigned col=0;col<32;++col) {
            unsigned value=static_cast<unsigned char*>(pixels.pData)[row*pixels.RowPitch+col],expected=plane?(col%2?240:90):82;
            low=std::min(low,value);high=std::max(high,value);if(value+4<expected || value>expected+4)valid=false;
        }
        fprintf(logFile,"Original output plane=%u range=%u..%u\n",plane,low,high);fflush(logFile);
        decoderCommands->Unmap(staging,0);staging->Release();check(valid,"BigSoup decoder shaders rendered the expected H264 pixels");
    }
    reinterpret_cast<void(*)(void*)>(original+0x8fc80)(decoder);
    for(unsigned offset:{0x1b8u,0x1b0u,0x1a8u,0x1a0u}) {
        auto* object=*reinterpret_cast<AMFInterface**>(decoder+offset);if(object)object->Release();
    }
    *ownerSlot=previousOwner;adapter->Release();fixtureCommands->Release();fixtureDevice->Release();
    fprintf(logFile,"RESULT PASS\n");fclose(logFile);return 0;
}
