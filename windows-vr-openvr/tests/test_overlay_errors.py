#!/usr/bin/env python3
"""Run production overlay upload/layer assembly against counted graphics hooks."""
import argparse
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("source", type=Path)
parser.add_argument("--generated", type=Path, required=True)
args = parser.parse_args()
source = (args.source / "OpenOVR/Reimpl/BaseOverlay.cpp").read_text()


def function(signature):
    start = source.index(signature)
    end = source.index("{", start) + 1
    depth = 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


methods = "\n".join(function(signature) for signature in [
    "int BaseOverlay::_BuildLayers(",
    "EVROverlayError BaseOverlay::SetOverlayTexture(",
    "EVROverlayError BaseOverlay::SetOverlayRaw(",
    "EVROverlayError BaseOverlay::SetOverlayFromFile(",
])
handle_macro = source[source.index("#define USEH()"):source.index("#define USEHB()")]
harness = r'''
#include <openxr/openxr.h>
#include "generated/interfaces/IVRCompositor_018.h"
#include "OpenOVR/Misc/WVRProjectionLayers.h"
#include <cassert>
#include <cstring>
#include <memory>
#include <map>
#include <set>
#include <string>
#include <vector>
#include <cstdio>
using namespace vr;
struct Counts { int query=0, hook=0, upload=0, create=0, load=0, reset=0, reg=0, keyboard=0, stub=0; } calls;
static const char* runtimeName="WineVision VR";
static XrResult queryResult=XR_SUCCESS;
XrResult xrGetInstanceProperties(XrInstance, XrInstanceProperties* out) {
    ++calls.query;
    assert(out->type==XR_TYPE_INSTANCE_PROPERTIES);
    if (XR_SUCCEEDED(queryResult)) std::strcpy(out->runtimeName,runtimeName);
    return queryResult;
}
static XrInstance xr_instance=XR_NULL_HANDLE;
struct Compositor {
    void LoadSubmitContext() { ++calls.load; }
    void ResetSubmitContext() { ++calls.reset; }
    void Invoke(const Texture_t*, const VRTextureBounds_t*, XrSwapchainSubImage&) { ++calls.upload; }
};
struct BaseCompositor {
    static std::shared_ptr<Compositor> CreateCompositorAPI(const Texture_t*) {
        ++calls.create; return std::make_shared<Compositor>();
    }
} baseCompositor;
static BaseCompositor* GetUnsafeBaseCompositor() { return &baseCompositor; }
struct XrBackend {
    std::vector<std::shared_ptr<Compositor>> owned;
    void RegisterOverlayCompositor(std::shared_ptr<Compositor> value) { ++calls.reg; owned.push_back(value); }
} backend;
struct BackendManager {
    static BackendManager& Instance() { static BackendManager manager; return manager; }
    void OnOverlayTexture(const Texture_t*) { ++calls.hook; }
    bool IsGraphicsConfigured() { return true; }
    void* GetBackendInstance() { return &backend; }
};
struct System { int currentSpace=0; } systemState;
static System* GetUnsafeBaseSystem() { return &systemState; }
static XrSpace xr_space_from_ref_space_type(int) { return XR_NULL_HANDLE; }
struct Keyboard {
    XrCompositionLayerQuad layer{XR_TYPE_COMPOSITION_LAYER_QUAD};
    XrCompositionLayerBaseHeader* Update() { ++calls.keyboard; return reinterpret_cast<XrCompositionLayerBaseHeader*>(&layer); }
    bool IsClosed() { return false; }
};
struct BaseOverlay {
    struct OverlayData {
        std::string key="loading";
        bool visible=true;
        Texture_t texture{};
        VRTextureBounds_t textureBounds{0,0,1,1};
        XrCompositionLayerQuad layerQuad{XR_TYPE_COMPOSITION_LAYER_QUAD};
        std::weak_ptr<Compositor> compositor;
        float widthMeters=1;
        float overlayTransform[4][4]{{1,0,0,0},{0,1,0,0},{0,0,1,-1},{0,0,0,1}};
    };
    std::map<std::string,OverlayData*> overlays;
    std::set<OverlayData*> validOverlays;
    std::vector<XrCompositionLayerBaseHeader*> layerHeaders;
    std::unique_ptr<Keyboard> keyboard;
    bool usingInput=true;
    void HideKeyboard() { keyboard.reset(); }
    int _BuildLayers(XrCompositionLayerBaseHeader*, XrCompositionLayerBaseHeader const* const*&);
    EVROverlayError SetOverlayTexture(VROverlayHandle_t,const Texture_t*);
    EVROverlayError SetOverlayRaw(VROverlayHandle_t,void*,uint32_t,uint32_t,uint32_t);
    EVROverlayError SetOverlayFromFile(VROverlayHandle_t,const char*);
};
#define OOVR_LOG_ONCE(...) ((void)0)
#define STUBBED() do { ++calls.stub; return VROverlayError_RequestFailed; } while(false)
''' + handle_macro + methods + r'''
int main() {
    BaseOverlay api; BaseOverlay::OverlayData overlay;
    api.overlays[overlay.key]=&overlay; api.validOverlays.insert(&overlay);
    api.keyboard=std::make_unique<Keyboard>();
    overlay.texture.handle=reinterpret_cast<void*>(uintptr_t(2));
    overlay.layerQuad.subImage.swapchain=reinterpret_cast<XrSwapchain>(uintptr_t(1));
    overlay.layerQuad.subImage.imageRect.extent={64,64};
    const auto handle=reinterpret_cast<uintptr_t>(&overlay);
    const auto* invalidTexture=reinterpret_cast<const Texture_t*>(uintptr_t(1));
    for(int n=0;n<100;++n) {
        calls={};
        assert(api.SetOverlayTexture(handle,invalidTexture)==VROverlayError_RequestFailed);
        assert(api.SetOverlayTexture(handle,nullptr)==VROverlayError_RequestFailed);
        assert(api.SetOverlayRaw(handle,reinterpret_cast<void*>(uintptr_t(1)),1024,1024,4)==VROverlayError_RequestFailed);
        assert(api.SetOverlayFromFile(handle,reinterpret_cast<const char*>(uintptr_t(1)))==VROverlayError_RequestFailed);
        assert(calls.hook==0 && calls.upload==0 && calls.create==0 && calls.load==0 && calls.reset==0 && calls.reg==0 && calls.stub==0);
        assert(overlay.texture.handle==reinterpret_cast<void*>(uintptr_t(2)) && overlay.compositor.expired());
    }
    calls={};
    assert(api.SetOverlayTexture(1,invalidTexture)==VROverlayError_InvalidHandle);
    assert(api.SetOverlayRaw(1,nullptr,1,1,4)==VROverlayError_InvalidHandle);
    assert(api.SetOverlayFromFile(1,nullptr)==VROverlayError_InvalidHandle);
    assert(calls.query==0);
    XrCompositionLayerProjection projection{XR_TYPE_COMPOSITION_LAYER_PROJECTION};
    auto* scene=reinterpret_cast<XrCompositionLayerBaseHeader*>(&projection);
    XrCompositionLayerBaseHeader const* const* layers=nullptr;
    calls={};
    assert(api._BuildLayers(scene,layers)==1 && layers[0]==scene);
    assert(!api.usingInput && calls.keyboard==0);
    assert(api._BuildLayers(nullptr,layers)==0 && calls.keyboard==0);
    // Another runtime retains the real upload, compositor registration and
    // scene/keyboard/overlay assembly paths. Failed queries retain that path.
    Texture_t texture{}; texture.handle=reinterpret_cast<void*>(uintptr_t(3));
    for (const char* name : {"Other OpenXR Runtime","WineVision VR successor",""}) {
        runtimeName=name; calls={}; overlay.compositor.reset();
        assert(api.SetOverlayTexture(handle,&texture)==VROverlayError_None);
        assert(calls.hook==1 && calls.upload==1 && calls.create==1 && calls.load==1 && calls.reset==1 && calls.reg==1);
        assert(api._BuildLayers(scene,layers)==3 && layers[0]==scene && api.usingInput);
        assert(calls.keyboard==1);
        assert(api.SetOverlayRaw(handle,nullptr,1,1,4)==VROverlayError_RequestFailed && calls.stub==1);
        assert(api.SetOverlayFromFile(handle,nullptr)==VROverlayError_RequestFailed && calls.stub==2);
    }
    runtimeName="WineVision VR"; queryResult=XR_ERROR_RUNTIME_FAILURE; calls={};
    assert(api.SetOverlayTexture(handle,&texture)==VROverlayError_None && calls.upload==1);
    std::puts("PASS: production overlay entry points reject before upload; scene-only assembly preserves projection and input; other runtimes retain behavior");
}
'''
with tempfile.TemporaryDirectory(prefix="winevision-overlays-") as temporary:
    work = Path(temporary)
    (work / "test.cpp").write_text(harness)
    executable = work / "test"
    subprocess.run(["xcrun", "clang++", "-std=c++20", "-O1", "-g",
                    "-fsanitize=address,undefined", "-fno-omit-frame-pointer",
                    "-I", str(args.source), "-I", str(args.source / "libs/openxr-sdk/include"),
                    "-I", str(args.generated), str(work / "test.cpp"), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True, timeout=30)
