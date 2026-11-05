#!/usr/bin/env python3
"""Run the patched production skybox entry point against a counted OpenXR driver."""
import argparse
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("source", type=Path, help="Patched OpenComposite source tree")
parser.add_argument("--generated", type=Path, required=True, help="OpenComposite build tree containing generated interfaces")
args = parser.parse_args()
source = (args.source / "DrvOpenXR/XrBackend.cpp").read_text()
signature = "IBackend::openvr_enum_t XrBackend::SetSkyboxOverride("
start = source.index(signature)
brace = source.index("{", start)
end, depth = brace + 1, 1
while depth:
    depth += (source[end] == "{") - (source[end] == "}")
    end += 1
method = source[start:end]

harness = r'''
#include <openxr/openxr.h>
#include "generated/interfaces/IVRCompositor_018.h"
#include "OpenOVR/Misc/WVRProjectionLayers.h"
#include <cassert>
#include <cstring>
#include <memory>
#include <cstdio>
struct Counts { int query=0, init=0, wait=0, begin=0, invoke=0, end=0, log=0; } calls;
static const char* runtimeName = "WineVision VR";
static XrResult queryResult = XR_SUCCESS;
XrResult xrGetInstanceProperties(XrInstance, XrInstanceProperties* out) {
    ++calls.query;
    assert(out->type == XR_TYPE_INSTANCE_PROPERTIES);
    if (XR_SUCCEEDED(queryResult)) std::strcpy(out->runtimeName, runtimeName);
    return queryResult;
}
XrResult xrWaitFrame(XrSession, const XrFrameWaitInfo*, XrFrameState* out) {
    ++calls.wait; out->predictedDisplayTime=123; return XR_SUCCESS;
}
XrResult xrBeginFrame(XrSession, const XrFrameBeginInfo*) { ++calls.begin; return XR_SUCCESS; }
XrResult xrEndFrame(XrSession, const XrFrameEndInfo* info) {
    ++calls.end; assert(info->layerCount==1); return XR_SUCCESS;
}
struct IBackend { using openvr_enum_t=int; };
struct Compositor {
    void Invoke(const vr::Texture_t*, const vr::VRTextureBounds_t*, XrSwapchainSubImage&) { ++calls.invoke; }
};
struct BaseCompositor {
    static std::unique_ptr<Compositor> CreateCompositorAPI(const vr::Texture_t*) {
        return std::make_unique<Compositor>();
    }
};
struct Session { XrSession get() { return XR_NULL_HANDLE; } } xr_session;
struct Globals { XrTime nextPredictedFrameTime=77; } globals, *xr_gbl=&globals;
static XrInstance xr_instance=XR_NULL_HANDLE;
struct System { int currentSpace=0; } systemState;
static System* GetUnsafeBaseSystem() { return &systemState; }
static XrSpace xr_space_from_ref_space_type(int) { return XR_NULL_HANDLE; }
struct XrBackend {
    bool sessionActive=true, usingApplicationGraphicsAPI=true, renderingFrame=true;
    std::unique_ptr<Compositor> skybox_compositor;
    void CheckOrInitCompositors(const vr::Texture_t*) { ++calls.init; }
    IBackend::openvr_enum_t SetSkyboxOverride(const vr::Texture_t*, uint32_t);
};
#define OOVR_LOG_ONCE(...) (++calls.log)
#define OOVR_FAILED_XR_ABORT(call) assert(XR_SUCCEEDED(call))
#define OOVR_FAILED_XR_SOFT_ABORT(call) assert(XR_SUCCEEDED(call))
#define OOVR_SOFT_ABORT(...) ((void)0)
''' + method + r'''
int main() {
    // One, six, compressed, mipmapped or invalid texture handles must never
    // enter the upload path on the projection-only runtime.
    auto* invalidTexture=reinterpret_cast<const vr::Texture_t*>(uintptr_t(1));
    for (auto count : {0u,1u,2u,6u}) for (int n=0;n<100;++n) {
        calls={}; XrBackend backend; globals.nextPredictedFrameTime=77;
        assert(backend.SetSkyboxOverride(invalidTexture,count)==vr::IVRCompositor_018::VRCompositorError_RequestFailed);
        assert(calls.query==1 && calls.init==0 && calls.wait==0 && calls.begin==0 && calls.end==0 && calls.invoke==0);
        assert(backend.renderingFrame && !backend.skybox_compositor && globals.nextPredictedFrameTime==77);
    }
    { XrBackend backend; assert(backend.SetSkyboxOverride(nullptr,0)==vr::IVRCompositor_018::VRCompositorError_RequestFailed); }
    // Other runtimes retain the existing frame/upload behavior, including
    // inactive-session and unavailable-runtime-property paths.
    for (const char* name : {"Other OpenXR Runtime", "WineVision VR successor", ""}) {
        runtimeName=name; calls={}; XrBackend backend; vr::Texture_t texture{};
        assert(backend.SetSkyboxOverride(&texture,1)==0);
        assert(calls.init==1 && calls.wait==1 && calls.begin==1 && calls.invoke==1 && calls.end==1);
        assert(!backend.renderingFrame && backend.skybox_compositor);
    }
    runtimeName="WineVision VR"; queryResult=XR_ERROR_RUNTIME_FAILURE; calls={};
    { XrBackend backend; backend.sessionActive=false; vr::Texture_t texture{};
      assert(backend.SetSkyboxOverride(&texture,1)==0);
      assert(calls.init==1 && calls.wait==0 && backend.renderingFrame); }
    std::puts("PASS: production skybox entry returns RequestFailed without frame/upload side effects; other runtimes retain behavior");
}
'''
with tempfile.TemporaryDirectory(prefix="winevision-skybox-") as temporary:
    work = Path(temporary)
    (work / "test.cpp").write_text(harness)
    executable = work / "test"
    subprocess.run(["xcrun", "clang++", "-std=c++20", "-O1", "-g",
                    "-fsanitize=address,undefined", "-fno-omit-frame-pointer",
                    "-I", str(args.source), "-I", str(args.source / "libs/openxr-sdk/include"),
                    "-I", str(args.generated),
                    str(work / "test.cpp"), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True, timeout=30)
