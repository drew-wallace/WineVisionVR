// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include <cassert>
#include <cstdlib>
#include <unistd.h>
#include "WindowsVRPresentationDiagnostics.h"

int main(int argc, const char *argv[]) {
    assert(argc == 2);
    @autoreleasepool {
        setenv("WVR_PRESENT_DIAGNOSTICS", "1", 1);
        setenv("WVR_PRESENT_DIAGNOSTICS_START", "1", 1);
        wvr_present_diagnostics_install_v1(argv[1]);
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        assert(device);
        CAMetalLayer *layer = [CAMetalLayer layer];
        layer.device = device;
        layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        layer.framebufferOnly = NO;
        layer.drawableSize = CGSizeMake(4, 4);
        id<CAMetalDrawable> drawable = [layer nextDrawable];
        assert(drawable);
        id<MTLCommandQueue> queue = [device newCommandQueue];
        NSError *error = nil;
        id<MTLLibrary> library = [device newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\n"
            "vertex float4 probe_vertex(uint i [[vertex_id]]) { "
            "float2 p[3] = {float2(-1,-1),float2(3,-1),float2(-1,3)}; return float4(p[i],0,1); }\n"
            "fragment float4 probe_fragment(float4 p [[position]], texture2d<float> t [[texture(0)]]) { "
            "return t.read(uint2(p.xy)) * float4(1,0.5,1,1); }"
            options:nil error:&error];
        assert(library && !error);
        MTLRenderPipelineDescriptor *pipeline = [MTLRenderPipelineDescriptor new];
        pipeline.vertexFunction = [library newFunctionWithName:@"probe_vertex"];
        pipeline.fragmentFunction = [library newFunctionWithName:@"probe_fragment"];
        pipeline.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        id<MTLRenderPipelineState> bgraPipeline = [device newRenderPipelineStateWithDescriptor:pipeline error:&error];
        assert(bgraPipeline && !error);
        pipeline.colorAttachments[0].pixelFormat = MTLPixelFormatRGB10A2Unorm;
        id<MTLRenderPipelineState> packedPipeline = [device newRenderPipelineStateWithDescriptor:pipeline error:&error];
        assert(packedPipeline && !error);
        MTLTextureDescriptor *sourceInfo = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:
            MTLPixelFormatRGBA8Unorm width:4 height:4 mipmapped:NO];
        sourceInfo.storageMode = MTLStorageModeShared;
        id<MTLTexture> source = [device newTextureWithDescriptor:sourceInfo];
        unsigned char sourcePixels[64];
        for (unsigned i = 0; i < 16; ++i) {
            sourcePixels[i * 4] = sourcePixels[i * 4 + 1] = sourcePixels[i * 4 + 3] = 255;
            sourcePixels[i * 4 + 2] = 0;
        }
        [source replaceRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:0 withBytes:sourcePixels bytesPerRow:16];
        id<MTLCommandBuffer> commands = [queue commandBuffer];
        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = drawable.texture;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        pass.colorAttachments[0].clearColor = MTLClearColorMake(1, 0.5, 0, 1);
        id<MTLRenderCommandEncoder> encoder = [commands renderCommandEncoderWithDescriptor:pass];
        [encoder setRenderPipelineState:bgraPipeline];
        [encoder setFragmentTexture:source atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [encoder endEncoding];
        [commands presentDrawable:drawable];
        [commands commit];
        [commands waitUntilCompleted];
        assert(commands.status == MTLCommandBufferStatusCompleted);
        layer.pixelFormat = MTLPixelFormatRGB10A2Unorm;
        id<CAMetalDrawable> packedDrawable = [layer nextDrawable];
        assert(packedDrawable);
        id<MTLCommandBuffer> packed = [queue commandBuffer];
        pass.colorAttachments[0].texture = packedDrawable.texture;
        encoder = [packed renderCommandEncoderWithDescriptor:pass];
        [encoder setRenderPipelineState:packedPipeline];
        [encoder setFragmentTexture:source atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [encoder endEncoding];
        [packed presentDrawable:packedDrawable afterMinimumDuration:0.001];
        [packed commit];
        [packed waitUntilCompleted];
        assert(packed.status == MTLCommandBufferStatusCompleted);
        NSURL *parent = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]] isDirectory:YES];
        NSArray<NSURL *> *runs = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:parent
            includingPropertiesForKeys:nil options:0 error:nil];
        assert(runs.count == 1);
        NSURL *recordURL = [runs[0] URLByAppendingPathComponent:@"frame-0001.gpu.json"];
        NSData *json = nil;
        for (unsigned i = 0; i < 100 && !json; ++i) {
            usleep(50000);
            json = [NSData dataWithContentsOfURL:recordURL];
        }
        assert(json);
        NSDictionary *record = [NSJSONSerialization JSONObjectWithData:json options:0 error:nil];
        assert([record[@"gpuStatus"] unsignedIntegerValue] == MTLCommandBufferStatusCompleted);
        assert([record[@"format"] unsignedIntegerValue] == MTLPixelFormatBGRA8Unorm);
        NSData *pixels = [NSData dataWithContentsOfURL:[runs[0] URLByAppendingPathComponent:record[@"pixels"]]];
        const unsigned char *bytes = (const unsigned char *)pixels.bytes;
        const NSUInteger pitch = [record[@"bytesPerRow"] unsignedIntegerValue];
        assert(pixels.length == pitch * 4);
        for (unsigned y = 0; y < 4; ++y) for (unsigned x = 0; x < 4; ++x) {
            const unsigned char *p = bytes + pitch * y + 4 * x;
            assert(p[0] == 0 && p[1] >= 127 && p[1] <= 128 && p[2] == 255 && p[3] == 255);
        }
        recordURL = [runs[0] URLByAppendingPathComponent:@"frame-0002.gpu.json"];
        json = nil;
        for (unsigned i = 0; i < 100 && !json; ++i) {
            usleep(50000); json = [NSData dataWithContentsOfURL:recordURL];
        }
        assert(json);
        record = [NSJSONSerialization JSONObjectWithData:json options:0 error:nil];
        assert([record[@"format"] unsignedIntegerValue] == MTLPixelFormatRGB10A2Unorm);
        pixels = [NSData dataWithContentsOfURL:[runs[0] URLByAppendingPathComponent:record[@"pixels"]]];
        bytes = (const unsigned char *)pixels.bytes;
        const NSUInteger packedPitch = [record[@"bytesPerRow"] unsignedIntegerValue];
        assert(pixels.length == packedPitch * 4);
        for (unsigned y = 0; y < 4; ++y) for (unsigned x = 0; x < 4; ++x) {
            uint32_t value; memcpy(&value, bytes + packedPitch * y + 4 * x, sizeof(value));
            assert((value & 1023) == 1023 && ((value >> 10) & 1023) >= 511 &&
                ((value >> 10) & 1023) <= 512 && ((value >> 20) & 1023) == 0 && (value >> 30) == 3);
        }
        for (unsigned frame = 1; frame <= 2; ++frame) {
            recordURL = [runs[0] URLByAppendingPathComponent:
                [NSString stringWithFormat:@"frame-%04u.gpu.json", frame]];
            record = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfURL:recordURL] options:0 error:nil];
            NSDictionary *input = record[@"source"];
            assert([input[@"format"] unsignedIntegerValue] == MTLPixelFormatRGBA8Unorm);
            pixels = [NSData dataWithContentsOfURL:[runs[0] URLByAppendingPathComponent:input[@"pixels"]]];
            bytes = (const unsigned char *)pixels.bytes;
            const NSUInteger inputPitch = [input[@"bytesPerRow"] unsignedIntegerValue];
            assert(pixels.length == inputPitch * 4);
            for (unsigned y = 0; y < 4; ++y) for (unsigned x = 0; x < 4; ++x)
                assert(memcmp(bytes + inputPitch * y + 4 * x, sourcePixels + 4 * x, 4) == 0);
        }
        puts("PASS: both Metal presentation entry points, distinct input/output pixels, completion lifetime and padded stride");
    }
}
