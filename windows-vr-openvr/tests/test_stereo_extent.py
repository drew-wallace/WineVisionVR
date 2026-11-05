#!/usr/bin/env python3
"""Exercise production extent normalization and UV setup for oversized eye images."""
import argparse
from pathlib import Path
import subprocess
import tempfile

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument("source",type=Path)
args=parser.parse_args()
source=(args.source/"OpenOVR/Compositor/dx11compositor.cpp").read_text()
start=source.index("\tresampleToTarget = false;")
normalization=source[start:source.index("\tbool usable =",start)]
start=source.index("\t\tconst vr::VRTextureBounds_t fullBounds")
end=source.index("\t\tID3D11Texture2D* sampleTexture",start)
uv_setup=source[start:end]
assert "if ((bounds || resampleToTarget) && !swapchain_rtvs.empty())" in source
code=r'''
#include "OpenOVR/Compositor/WVRTextureExtent.h"
#include "OpenOVR/Compositor/WVRTextureBounds.h"
#include <cassert>
#include <cstdio>
#include "OpenVRHeaders/openvr-1.23.7.h"
struct View {uint32_t recommendedImageRectWidth,recommendedImageRectHeight;} views[2]{{1920,1792},{1920,1792}};
enum {XruEyeLeft,XruEyeRight};
static const View& xr_main_view(int eye) {return views[eye];}
static bool projectionOnly=true;
static int xr_instance=0;
static bool WVRIsProjectionOnlyRuntime(int) {return projectionOnly;}
struct Extent {uint32_t Width,Height;};
static bool normalize(Extent& srcDesc,bool cube=false) {
 bool resampleToTarget;
''' + normalization + r'''
 return resampleToTarget;
}
#define OOVR_FALSE_ABORT(value) assert(value)
static WVRBoundsUniform sampleUV(const vr::VRTextureBounds_t* bounds) {
''' + uv_setup + r'''
 return uv;
}
int main() {
 Extent size{2880,2688};assert(normalize(size)&&size.Width==1920&&size.Height==1792);
 assert(!normalize(size)&&size.Width==1920&&size.Height==1792);
 size={960,896};assert(!normalize(size)&&size.Width==960&&size.Height==896);
 size={2880,896};assert(normalize(size)&&size.Width==1920&&size.Height==896);
 size={960,2688};assert(normalize(size)&&size.Width==960&&size.Height==1792);
 views[1]={1800,1600};size={2880,2688};assert(normalize(size)&&size.Width==1800&&size.Height==1600);
 projectionOnly=false;size={2880,2688};assert(!normalize(size)&&size.Width==2880&&size.Height==2688);
 projectionOnly=true;size={2880,2688};assert(!normalize(size,true)&&size.Width==2880&&size.Height==2688);
 views[1]={0,0};size={2880,2688};assert(!normalize(size)&&size.Width==2880&&size.Height==2688);
 auto uv=sampleUV(nullptr);assert(uv.originX==0&&uv.originY==0&&uv.extentX==1&&uv.extentY==1);
 vr::VRTextureBounds_t inverted{0,1,1,0};uv=sampleUV(&inverted);
 assert(uv.originX==0&&uv.originY==1&&uv.extentX==1&&uv.extentY==-1);
 vr::VRTextureBounds_t cropped{0.5f,1,1,0};uv=sampleUV(&cropped);
 assert(uv.originX==0.5f&&uv.originY==1&&uv.extentX==0.5f&&uv.extentY==-1);
 // The destination size never enters UV selection: all source corners survive
 // resizing, including the signed vertical inversion and one-eye atlas crop.
 for(float x:{0.f,1.f}) for(float y:{0.f,1.f}) {
  assert(uv.originX+x*uv.extentX==0.5f+x*0.5f);
  assert(uv.originY+y*uv.extentY==1-y);
 }
 std::puts("PASS: production eye extent normalization, stable repeated dimensions, smaller images, asymmetric targets, other-runtime/cube exclusion and full/cropped/inverted source UVs");
}
'''
with tempfile.TemporaryDirectory(prefix="winevision-stereo-fit-") as temporary:
    work=Path(temporary);(work/"test.cpp").write_text(code)
    subprocess.run(["xcrun","clang++","-std=c++20","-O1","-g","-fsanitize=address,undefined",
        "-I",str(args.source),str(work/"test.cpp"),"-o",str(work/"test")],check=True)
    subprocess.run([str(work/"test")],check=True,timeout=30)
