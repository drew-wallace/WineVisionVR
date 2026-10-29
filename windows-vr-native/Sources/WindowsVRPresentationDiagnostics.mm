// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <objc/runtime.h>
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include "WindowsVRPresentationDiagnostics.h"

// Associate only the final render pass observed during the bounded sample.
// Both owners release it with their normal command-buffer/encoder lifetimes.
@interface WVRPresentationPassObservation : NSObject
@property(nonatomic, strong) id<MTLTexture> target;
@property(nonatomic, strong) id<MTLTexture> source;
@end
@implementation WVRPresentationPassObservation
@end

namespace {
using Present = void (*)(id, SEL, id<MTLDrawable>);
using PresentDuration = void (*)(id, SEL, id<MTLDrawable>, double);
using RenderPass = id<MTLRenderCommandEncoder> (*)(id, SEL, MTLRenderPassDescriptor *);
using FragmentTexture = void (*)(id, SEL, id<MTLTexture>, NSUInteger);
Present originalPresent;
PresentDuration originalDuration;
RenderPass originalRenderPass;
FragmentTexture originalFragmentTexture;
char passObservationKey;
NSURL *runDirectory;
dispatch_queue_t writer;
std::atomic<uint64_t> frameNumber{0};
uint64_t firstFrame = 300;
constexpr uint64_t sampleCount = 16;
thread_local unsigned nestedPresentation;

id<MTLRenderCommandEncoder> ObserveRenderPass(id self, SEL selector, MTLRenderPassDescriptor *pass) {
    id<MTLRenderCommandEncoder> encoder = originalRenderPass(self, selector, pass);
    const uint64_t next = frameNumber.load() + 1;
    if (next >= firstFrame && next - firstFrame < sampleCount && encoder) {
        WVRPresentationPassObservation *observation = [WVRPresentationPassObservation new];
        observation.target = pass.colorAttachments[0].texture;
        objc_setAssociatedObject(self, &passObservationKey, observation, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(encoder, &passObservationKey, observation, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return encoder;
}

void ObserveFragmentTexture(id self, SEL selector, id<MTLTexture> texture, NSUInteger index) {
    originalFragmentTexture(self, selector, texture, index);
    if (index == 0) {
        WVRPresentationPassObservation *observation = objc_getAssociatedObject(self, &passObservationKey);
        observation.source = texture;
    }
}

void WriteRecord(NSDictionary *record, NSString *name) {
    @autoreleasepool {
        NSData *data = [NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingPrettyPrinted error:nil];
        [data writeToURL:[runDirectory URLByAppendingPathComponent:name] options:NSDataWritingAtomic error:nil];
    }
}

void ObservePresent(id<MTLCommandBuffer> commands, id<MTLDrawable> drawable) {
    if (nestedPresentation) return;
    const uint64_t frame = frameNumber.fetch_add(1) + 1;
    if (frame < firstFrame || frame - firstFrame >= sampleCount) return;
    if (![drawable conformsToProtocol:@protocol(CAMetalDrawable)]) return;
    id<MTLTexture> texture = ((id<CAMetalDrawable>)drawable).texture;
    const NSUInteger width = texture.width, height = texture.height;
    const NSUInteger pitch = (width * 4 + 255) & ~NSUInteger(255);
    const NSUInteger bytes = pitch * height;
    const MTLPixelFormat format = texture.pixelFormat;
    const BOOL supported = format == MTLPixelFormatBGRA8Unorm || format == MTLPixelFormatBGRA8Unorm_sRGB ||
        format == MTLPixelFormatRGBA8Unorm || format == MTLPixelFormatRGBA8Unorm_sRGB ||
        format == MTLPixelFormatRGB10A2Unorm || format == MTLPixelFormatBGR10A2Unorm;
    NSMutableDictionary *record = [@{@"frame": @(frame), @"width": @(width), @"height": @(height),
        @"format": @(format), @"bytesPerRow": @(pitch), @"drawableID": @(drawable.drawableID),
        @"framebufferOnly": @(texture.framebufferOnly)} mutableCopy];
    NSString *stem = [NSString stringWithFormat:@"frame-%04llu", (unsigned long long)frame];
    [drawable addPresentedHandler:^(id<MTLDrawable> presented) {
        const double time = presented.presentedTime;
        dispatch_async(writer, ^{
            WriteRecord(@{@"frame": @(frame), @"drawableID": @(presented.drawableID),
                          @"presentedTime": @(time)}, [stem stringByAppendingString:@".presented.json"]);
        });
    }];
    id<MTLBuffer> readback = nil;
    if (supported && !texture.framebufferOnly && texture.sampleCount == 1 && texture.textureType == MTLTextureType2D &&
        width && height && width <= 8192 && height <= 8192 && bytes <= 8 * 1024 * 1024) {
        readback = [texture.device newBufferWithLength:bytes options:MTLResourceStorageModeShared];
        id<MTLBlitCommandEncoder> blit = readback ? [commands blitCommandEncoder] : nil;
        if (blit) {
            [blit copyFromTexture:texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
                       sourceSize:MTLSizeMake(width, height, 1) toBuffer:readback destinationOffset:0
              destinationBytesPerRow:pitch destinationBytesPerImage:bytes];
            [blit endEncoding];
        } else readback = nil;
    }
    record[@"pixelCopyEncoded"] = @(readback != nil);
    // Compare the final pass's texture-0 input with the drawable in the same
    // submission. This distinguishes a black backbuffer from a black present
    // conversion without changing the guest runtime or waiting on the GPU.
    WVRPresentationPassObservation *observation = objc_getAssociatedObject(commands, &passObservationKey);
    id<MTLTexture> source = observation.target == texture ? observation.source : nil;
    id<MTLBuffer> sourceReadback = nil;
    NSUInteger sourcePitch = 0, sourceBytes = 0;
    if (source && source != texture && source.sampleCount == 1 && !source.framebufferOnly &&
        source.textureType == MTLTextureType2D && source.width && source.height &&
        source.width <= 8192 && source.height <= 8192 &&
        (source.pixelFormat == MTLPixelFormatBGRA8Unorm || source.pixelFormat == MTLPixelFormatBGRA8Unorm_sRGB ||
         source.pixelFormat == MTLPixelFormatRGBA8Unorm || source.pixelFormat == MTLPixelFormatRGBA8Unorm_sRGB ||
         source.pixelFormat == MTLPixelFormatRGB10A2Unorm || source.pixelFormat == MTLPixelFormatBGR10A2Unorm)) {
        sourcePitch = (source.width * 4 + 255) & ~NSUInteger(255);
        sourceBytes = sourcePitch * source.height;
        if (sourceBytes <= 8 * 1024 * 1024) {
            sourceReadback = [source.device newBufferWithLength:sourceBytes options:MTLResourceStorageModeShared];
            id<MTLBlitCommandEncoder> blit = sourceReadback ? [commands blitCommandEncoder] : nil;
            if (blit) {
                [blit copyFromTexture:source sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
                    sourceSize:MTLSizeMake(source.width, source.height, 1) toBuffer:sourceReadback destinationOffset:0
                    destinationBytesPerRow:sourcePitch destinationBytesPerImage:sourceBytes];
                [blit endEncoding];
                record[@"source"] = @{@"format": @(source.pixelFormat), @"width": @(source.width),
                    @"height": @(source.height), @"bytesPerRow": @(sourcePitch)};
            } else sourceReadback = nil;
        }
    }
    objc_setAssociatedObject(commands, &passObservationKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // The completion block retains storage; no CPU/GPU wait or early buffer reuse.
    [commands addCompletedHandler:^(id<MTLCommandBuffer> completed) {
        NSDictionary *completion = @{@"gpuStatus": @(completed.status),
            @"gpuError": completed.error.localizedDescription ?: @"", @"gpuEndTime": @(completed.GPUEndTime)};
        dispatch_async(writer, ^{
            @autoreleasepool {
                NSMutableDictionary *final = [record mutableCopy];
                [final addEntriesFromDictionary:completion];
                if (readback && [completion[@"gpuStatus"] unsignedIntegerValue] == MTLCommandBufferStatusCompleted) {
                    NSString *name = [stem stringByAppendingString:@".pixels"];
                    NSData *pixels = [NSData dataWithBytes:readback.contents length:bytes];
                    BOOL saved = [pixels writeToURL:[runDirectory URLByAppendingPathComponent:name]
                                           options:NSDataWritingAtomic error:nil];
                    if (saved) final[@"pixels"] = name;
                }
                if (sourceReadback && [completion[@"gpuStatus"] unsignedIntegerValue] == MTLCommandBufferStatusCompleted) {
                    NSString *name = [stem stringByAppendingString:@".source.pixels"];
                    NSData *pixels = [NSData dataWithBytes:sourceReadback.contents length:sourceBytes];
                    if ([pixels writeToURL:[runDirectory URLByAppendingPathComponent:name]
                                   options:NSDataWritingAtomic error:nil]) {
                        NSMutableDictionary *input = [record[@"source"] mutableCopy];
                        input[@"pixels"] = name;
                        final[@"source"] = input;
                    }
                }
                WriteRecord(final, [stem stringByAppendingString:@".gpu.json"]);
            }
        });
    }];
}

void PresentNow(id self, SEL selector, id<MTLDrawable> drawable) {
    ObservePresent(self, drawable);
    ++nestedPresentation;
    originalPresent(self, selector, drawable);
    --nestedPresentation;
}

void PresentAfter(id self, SEL selector, id<MTLDrawable> drawable, double duration) {
    ObservePresent(self, drawable);
    ++nestedPresentation;
    originalDuration(self, selector, drawable, duration);
    --nestedPresentation;
}
} // namespace

void wvr_present_diagnostics_install_v1(const char *parent_directory) {
    const char *enabled = getenv("WVR_PRESENT_DIAGNOSTICS");
    if (!enabled || strcmp(enabled, "1") || !parent_directory || !*parent_directory) return;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        @autoreleasepool {
            id<MTLDevice> device = MTLCreateSystemDefaultDevice();
            id<MTLCommandQueue> queue = [device newCommandQueue];
            id<MTLCommandBuffer> commands = [queue commandBuffer];
            Class cls = object_getClass(commands);
            Method plain = class_getInstanceMethod(cls, @selector(presentDrawable:));
            Method duration = class_getInstanceMethod(cls, @selector(presentDrawable:afterMinimumDuration:));
            Method render = class_getInstanceMethod(cls, @selector(renderCommandEncoderWithDescriptor:));
            MTLRenderPassDescriptor *probePass = [MTLRenderPassDescriptor renderPassDescriptor];
            MTLTextureDescriptor *probeTexture = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:
                MTLPixelFormatBGRA8Unorm width:1 height:1 mipmapped:NO];
            probeTexture.usage = MTLTextureUsageRenderTarget;
            probePass.colorAttachments[0].texture = [device newTextureWithDescriptor:probeTexture];
            id<MTLRenderCommandEncoder> probeEncoder = [commands renderCommandEncoderWithDescriptor:probePass];
            Class encoderClass = object_getClass(probeEncoder);
            Method fragment = class_getInstanceMethod(encoderClass, @selector(setFragmentTexture:atIndex:));
            [probeEncoder endEncoding];
            [commands commit];
            if (!plain || !duration || !render || !fragment) return;
            NSURL *parent = [NSURL fileURLWithPath:[NSString stringWithUTF8String:parent_directory] isDirectory:YES];
            runDirectory = [parent URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
            if (![[NSFileManager defaultManager] createDirectoryAtURL:runDirectory
                  withIntermediateDirectories:YES attributes:nil error:nil]) { runDirectory = nil; return; }
            const char *start = getenv("WVR_PRESENT_DIAGNOSTICS_START");
            if (start && *start) {
                char *end = nullptr;
                const unsigned long long value = strtoull(start, &end, 10);
                if (end != start && !*end && value >= 1 && value <= 10000) firstFrame = value;
            }
            writer = dispatch_queue_create("org.avpplay.presentation-diagnostics", DISPATCH_QUEUE_SERIAL);
            originalPresent = (Present)method_getImplementation(plain);
            originalDuration = (PresentDuration)method_getImplementation(duration);
            originalRenderPass = (RenderPass)method_getImplementation(render);
            originalFragmentTexture = (FragmentTexture)method_getImplementation(fragment);
            class_replaceMethod(cls, @selector(presentDrawable:), (IMP)PresentNow, method_getTypeEncoding(plain));
            class_replaceMethod(cls, @selector(presentDrawable:afterMinimumDuration:),
                                (IMP)PresentAfter, method_getTypeEncoding(duration));
            class_replaceMethod(cls, @selector(renderCommandEncoderWithDescriptor:),
                                (IMP)ObserveRenderPass, method_getTypeEncoding(render));
            class_replaceMethod(encoderClass, @selector(setFragmentTexture:atIndex:),
                                (IMP)ObserveFragmentTexture, method_getTypeEncoding(fragment));
            WriteRecord(@{@"schemaVersion": @1, @"firstFrame": @(firstFrame), @"sampleCount": @(sampleCount),
                          @"device": device.name ?: @""}, @"run.json");
            fprintf(stderr, "[present-diagnostics] %s first=%llu count=%llu\n", runDirectory.path.UTF8String,
                    (unsigned long long)firstFrame, (unsigned long long)sampleCount);
        }
    });
}
