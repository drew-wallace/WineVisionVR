#!/usr/bin/env python3
"""Compile the prepared native Metal eligibility policy and check descriptor boundaries."""
import argparse
from pathlib import Path
import re
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime-source", type=Path, required=True)
    args = parser.parse_args()
    root = args.runtime_source / "dxmt/src"
    source = (root / "winemetal/unix/winemetal_unix.c").read_text()
    start = source.index("static BOOL\nwmt_lossy_texture_eligible")
    opening = source.index("{", start)
    end, depth = opening + 1, 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    helper = source[start:end]
    bare = []
    for path in root.rglob("*"):
        if path.suffix in {".cpp", ".hpp"}:
            if re.search(r"^\s*WMTTextureInfo\s+\w+;", path.read_text(), re.MULTILINE):
                bare.append(str(path.relative_to(root)))
    if bare:
        raise SystemExit("Uninitialized WMT texture descriptors: " + ", ".join(bare))
    fixture = '''
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <assert.h>
''' + helper + r'''
int main(void) {
  @autoreleasepool {
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
        width:16 height:16 mipmapped:NO];
    d.storageMode = MTLStorageModePrivate;
    d.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
    MTLPixelFormat supported[] = {MTLPixelFormatRGBA8Unorm, MTLPixelFormatBGRA8Unorm,
        MTLPixelFormatRGBA16Float, MTLPixelFormatRG11B10Float, MTLPixelFormatRGB10A2Unorm};
    for (unsigned i=0;i<sizeof(supported)/sizeof(*supported);++i) {
      d.pixelFormat=supported[i]; assert(wmt_lossy_texture_eligible(d,1));
    }
    MTLPixelFormat rejected[] = {MTLPixelFormatBC7_RGBAUnorm, MTLPixelFormatBC7_RGBAUnorm_sRGB,
        MTLPixelFormatBC1_RGBA, MTLPixelFormatASTC_4x4_LDR, MTLPixelFormatEAC_RGBA8,
        MTLPixelFormatDepth32Float, MTLPixelFormatStencil8, MTLPixelFormatRGBA8Unorm_sRGB,
        MTLPixelFormatRGBA8Uint, MTLPixelFormatInvalid};
    for (unsigned i=0;i<sizeof(rejected)/sizeof(*rejected);++i) {
      d.pixelFormat=rejected[i]; assert(!wmt_lossy_texture_eligible(d,1));
      assert(d.storageMode==MTLStorageModePrivate);
      assert(d.compressionType==MTLTextureCompressionTypeLossless);
    }
    d.pixelFormat=MTLPixelFormatRGBA8Unorm;
    assert(!wmt_lossy_texture_eligible(d,0));
    assert(!wmt_lossy_texture_eligible(d,0xdeadbeef));
    d.sampleCount=4; assert(!wmt_lossy_texture_eligible(d,1)); d.sampleCount=1;
    d.arrayLength=2; assert(!wmt_lossy_texture_eligible(d,1)); d.arrayLength=1;
    d.depth=4; assert(!wmt_lossy_texture_eligible(d,1)); d.depth=1;
    d.textureType=MTLTextureType2DArray; assert(!wmt_lossy_texture_eligible(d,1)); d.textureType=MTLTextureType2D;
    d.storageMode=MTLStorageModeShared; assert(!wmt_lossy_texture_eligible(d,1)); d.storageMode=MTLStorageModePrivate;
    d.usage=MTLTextureUsageShaderRead; assert(!wmt_lossy_texture_eligible(d,1));
    d.usage=MTLTextureUsageRenderTarget|MTLTextureUsagePixelFormatView; assert(!wmt_lossy_texture_eligible(d,1));
    d.usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderWrite; assert(!wmt_lossy_texture_eligible(d,1));
  }
}
'''
    with tempfile.TemporaryDirectory(prefix="wvr-lossy-policy-") as work:
        work = Path(work)
        (work / "probe.m").write_text(fixture)
        subprocess.run(["xcrun", "clang", "-Wall", "-Wextra", "-Werror", "-fsanitize=address,undefined",
                        "-framework", "Foundation", "-framework", "Metal", str(work / "probe.m"),
                        "-o", str(work / "probe")], check=True)
        subprocess.run([str(work / "probe")], check=True, timeout=15)
    print("PASS: native lossy policy, BC7/block/depth/integer exclusions, explicit requests, initialized descriptors; ASan/UBSan")


if __name__ == "__main__":
    main()
