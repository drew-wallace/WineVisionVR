#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <objc/runtime.h>
#include <atomic>
#include "WindowsVRDesktopPointerTiming.h"

namespace {
using Present = void (*)(id, SEL, id<MTLDrawable>);
using PresentAfter = void (*)(id, SEL, id<MTLDrawable>, double);
Present originalPresent;
PresentAfter originalAfter;
std::atomic<uint64_t> frames{0};
thread_local unsigned nested;
int installed;

void Note(id<MTLDrawable> drawable) {
    if (!nested && [drawable conformsToProtocol:@protocol(CAMetalDrawable)])
        frames.fetch_add(1, std::memory_order_relaxed);
}
void PresentNow(id self, SEL sel, id<MTLDrawable> drawable) {
    Note(drawable);
    ++nested;
    originalPresent(self, sel, drawable);
    --nested;
}
void PresentDuration(id self, SEL sel, id<MTLDrawable> drawable, double duration) {
    Note(drawable);
    ++nested;
    originalAfter(self, sel, drawable, duration);
    --nested;
}
}

int wvr_desktop_pointer_timing_install_v1(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        id<MTLCommandQueue> queue = [device newCommandQueue];
        id<MTLCommandBuffer> commands = [queue commandBuffer];
        Class cls = object_getClass(commands);
        Method plain = class_getInstanceMethod(cls, @selector(presentDrawable:));
        Method after = class_getInstanceMethod(cls, @selector(presentDrawable:afterMinimumDuration:));
        if (!plain || !after) return;
        originalPresent = (Present)method_getImplementation(plain);
        originalAfter = (PresentAfter)method_getImplementation(after);
        class_replaceMethod(cls, @selector(presentDrawable:), (IMP)PresentNow, method_getTypeEncoding(plain));
        class_replaceMethod(cls, @selector(presentDrawable:afterMinimumDuration:),
                            (IMP)PresentDuration, method_getTypeEncoding(after));
        installed = 1;
    });
    return installed;
}

uint64_t wvr_desktop_pointer_frame_v1(void) {
    return frames.load(std::memory_order_relaxed);
}
