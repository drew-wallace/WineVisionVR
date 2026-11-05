// Runs the production compositor bridge with real simulator Metal resources.
// Synthetic producer frames test queue/generation/lease behavior, not Windows VR.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "WindowsVRCompositorBridge.h"
#include <cstdio>
#include <cstdlib>
#include <atomic>
#include <thread>
#include <chrono>
static void require(bool value, const char *message) {
    if (!value) { std::fprintf(stderr, "FAIL: %s\n", message); std::exit(1); }
    std::printf("PASS: %s\n", message);
}
int main() { @autoreleasepool {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    require(device != nil, "simulator supplies a real Metal device");
    require(wvr_compositor_bind_metal_device_v1((__bridge void *)device) == 0, "bind Metal device");
    const uint32_t format = MTLPixelFormatRGBA8Unorm;
    require(wvr_compositor_publish_targets_v1(32, 32, format, 32, 32, format) == 0, "publish stereo targets");
    WVRRenderTargetInfoV1 targets = {}; targets.structSize = sizeof(targets);
    require(wvr_compositor_copy_targets_v1(&targets) == 0 && targets.generation != 0, "publish target generation");
    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:32 height:32 mipmapped:NO];
    descriptor.storageMode = MTLStorageModeShared;
    descriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    id<MTLTexture> left = [device newTextureWithDescriptor:descriptor];
    id<MTLTexture> right = [device newTextureWithDescriptor:descriptor];
    id<MTLSharedEvent> ready = [device newSharedEvent];
    require(left && right && ready, "allocate stereo textures and shared event");
    id<MTLCommandQueue> queue = [device newCommandQueue];
    id<MTLCommandBuffer> commands = [queue commandBuffer];
    for (NSUInteger eye = 0; eye < 2; ++eye) {
        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = eye == 0 ? left : right;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        pass.colorAttachments[0].clearColor = eye == 0 ? MTLClearColorMake(1,0,0,1) : MTLClearColorMake(0,1,0,1);
        [[commands renderCommandEncoderWithDescriptor:pass] endEncoding];
    }
    [commands encodeSignalEvent:ready value:1];
    [commands commit]; [commands waitUntilCompleted];
    require(commands.status == MTLCommandBufferStatusCompleted && ready.signaledValue == 1, "complete stereo GPU work and signal readiness");
    WVRSubmitStereoFrameV1 frame = {};
    frame.abiVersion = WVR_COMPOSITOR_ABI_VERSION; frame.structSize = sizeof(frame);
    frame.leftTexture = (__bridge void *)left; frame.rightTexture = (__bridge void *)right;
    frame.producerReadyEvent = (__bridge void *)ready; frame.producerReadyValue = 1;
    uint64_t ticket = 0;
    for (uint64_t id = 1; id <= 5; ++id) {
        frame.producerFrameID = id;
        require(wvr_compositor_submit_stereo_frame_for_generation_v1(&frame, targets.generation, &ticket) == 0, "enqueue stereo frame");
    }
    WVRAcquiredStereoFrameV1 acquired = {}; acquired.structSize = sizeof(acquired);
    require(wvr_compositor_acquire_latest_stereo_frame_v1(&acquired) == 0 && acquired.producerFrameID == 5, "acquire newest frame after queue overflow");
    require(acquired.leftTexture == frame.leftTexture && acquired.rightTexture == frame.rightTexture, "preserve eye texture ownership");
    uint8_t leftPixel[4] = {}, rightPixel[4] = {};
    [left getBytes:leftPixel bytesPerRow:4 fromRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0];
    [right getBytes:rightPixel bytesPerRow:4 fromRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0];
    require(leftPixel[0] == 255 && leftPixel[1] == 0 && rightPixel[0] == 0 && rightPixel[1] == 255, "preserve distinct left/right GPU output");
    uint64_t pulse = 0, replacement = 0;
    WVRHapticRequestV1 haptic = {}; haptic.structSize = sizeof(haptic);
    require(wvr_compositor_submit_haptic_v1(0, 0.8f, 120, 3.0f, &pulse) == 0, "enqueue left vibration");
    require(wvr_compositor_take_haptic_v1(1, &haptic) == WVRCompositorStatusNoHapticAvailable, "haptics isolate hands");
    require(wvr_compositor_take_haptic_v1(0, &haptic) == 0 && haptic.amplitude == 0.8f && haptic.durationSeconds == 3.0f, "preserve requested vibration duration");
    require(wvr_compositor_take_haptic_v1(0, &haptic) == WVRCompositorStatusNoHapticAvailable, "consume vibration once");
    require(wvr_compositor_submit_haptic_v1(0, 1, 100, 1, &pulse) == 0, "enqueue replacement vibration");
    require(wvr_compositor_submit_haptic_v1(0, 0, 0, 0, &replacement) == 0 && replacement > pulse, "stop supersedes queued vibration");
    require(wvr_compositor_take_haptic_v1(0, &haptic) == 0 && haptic.amplitude == 0 && haptic.durationSeconds == 0, "preserve explicit stop request");
    require(wvr_compositor_submit_haptic_v1(1, 1, 100, 1, &pulse) == 0, "enqueue right vibration before pause");
    wvr_compositor_pause_v1();
    require(acquired.leftTexture == (__bridge void *)left && [(id<MTLTexture>)(__bridge id)acquired.leftTexture width] == 32, "acquired lease survives pause");
    wvr_compositor_release_acquired_frame_v1(acquired.lease);
    void *opaqueEvent = wvr_compositor_copy_consumer_event_v1();
    id<MTLSharedEvent> consumer = (__bridge id<MTLSharedEvent>)opaqueEvent;
    require(consumer.signaledValue >= ticket, "complete dropped and consumed tickets in order");
    wvr_compositor_release_object_v1(opaqueEvent);
    WVRAcquiredStereoFrameV1 empty = {}; empty.structSize = sizeof(empty);
    require(wvr_compositor_acquire_latest_stereo_frame_v1(&empty) == WVRCompositorStatusNoFrameAvailable, "paused queue contains no stale frames");
    require(wvr_compositor_take_haptic_v1(1, &haptic) == WVRCompositorStatusNoHapticAvailable, "pause clears pending vibration");
    require(wvr_compositor_submit_haptic_v1(0, 1, 100, 1, &pulse) == WVRCompositorStatusNoHapticAvailable, "paused compositor rejects vibration");
    require(wvr_compositor_publish_targets_v1(32, 32, format, 32, 32, format) == 0, "republish targets after pause");
    require(wvr_compositor_submit_stereo_frame_for_generation_v1(&frame, targets.generation, &ticket) == WVRCompositorStatusIncompatibleTexture, "reject stale target generation");
    require(wvr_compositor_publish_targets_v1(16, 16, format, 16, 16, format) == 0, "publish cropped-eye targets");
    require(wvr_compositor_copy_targets_v1(&targets) == 0, "read new array-frame generation");
    descriptor.textureType = MTLTextureType2DArray; descriptor.arrayLength = 2;
    id<MTLTexture> array = [device newTextureWithDescriptor:descriptor];
    require(array != nil, "allocate stereo texture array");
    WVRSubmitStereoFrameV2 arrayFrame = {};
    arrayFrame.abiVersion = WVR_COMPOSITOR_ABI_VERSION_V2; arrayFrame.structSize = sizeof(arrayFrame);
    arrayFrame.targetGeneration = targets.generation; arrayFrame.producerFrameID = 6;
    arrayFrame.leftTexture = arrayFrame.rightTexture = (__bridge void *)array;
    arrayFrame.producerReadyEvent = (__bridge void *)ready; arrayFrame.producerReadyValue = 1;
    arrayFrame.leftSlice = 0; arrayFrame.rightSlice = 1;
    arrayFrame.leftX = 4; arrayFrame.leftY = 5; arrayFrame.rightX = 6; arrayFrame.rightY = 7;
    arrayFrame.leftWidth = arrayFrame.rightWidth = arrayFrame.leftHeight = arrayFrame.rightHeight = 16;
    require(wvr_compositor_submit_stereo_frame_v2(&arrayFrame, &ticket) == 0, "submit array slices and eye subrectangles");
    require(wvr_compositor_acquire_latest_stereo_frame_v1(&empty) == WVRCompositorStatusUnsupportedABI, "V1 refuses array frame without discarding it");
    WVRAcquiredStereoFrameV2 arrayAcquired = {}; arrayAcquired.structSize = sizeof(arrayAcquired);
    require(wvr_compositor_acquire_latest_stereo_frame_v2(&arrayAcquired) == 0 && arrayAcquired.rightSlice == 1 && arrayAcquired.leftX == 4 && arrayAcquired.rightY == 7 && arrayAcquired.rightWidth == 16, "V2 preserves eye slices and crop geometry");
    wvr_compositor_release_acquired_frame_v1(arrayAcquired.lease);
    float origin[16]={1,0,0,0,0,1,0,0,0,0,1,0,1,0,0,1};
    float eyes[32]={}, projections[32]={}, tangents[8]={1,1,1,1,1,1,1,1}, depthRange[2]={100,0.1f};
    for (unsigned eye=0; eye<2; ++eye) for (unsigned axis=0; axis<4; ++axis) eyes[eye*16+axis*5]=projections[eye*16+axis*5]=1;
    require(wvr_compositor_publish_frame_tracking_v1(1'000'000'000,3,origin,eyes,projections,tangents,depthRange)==0, "publish render-time pose");
    arrayFrame.producerTimestampNanoseconds=1'000'000'000; arrayFrame.producerFrameID=7;
    require(wvr_compositor_submit_stereo_frame_v2(&arrayFrame,&ticket)==0, "enqueue ready frame with render pose");
    origin[12]=2;
    require(wvr_compositor_publish_frame_tracking_v1(1'011'111'111,3,origin,eyes,projections,tangents,depthRange)==0, "publish newer head pose");
    arrayFrame.producerReadyValue=2; arrayFrame.producerFrameID=8;
    require(wvr_compositor_submit_stereo_frame_v2(&arrayFrame,&ticket)==0, "enqueue unfinished GPU frame");
    arrayAcquired.structSize=sizeof(arrayAcquired);
    require(wvr_compositor_acquire_latest_stereo_frame_v2(&arrayAcquired)==0 && arrayAcquired.producerFrameID==7, "acquire ready frame without waiting for newer GPU work");
    WVRFrameTrackingV1 renderPose{}; renderPose.structSize=sizeof(renderPose);
    require(wvr_compositor_copy_lease_tracking_v1(arrayAcquired.lease,&renderPose)==0 && renderPose.timestampNanoseconds==1'000'000'000 && renderPose.originFromDevice[12]==1, "lease retains original render pose rather than current pose");
    wvr_compositor_release_acquired_frame_v1(arrayAcquired.lease);
    arrayAcquired.structSize=sizeof(arrayAcquired);
    require(wvr_compositor_acquire_latest_stereo_frame_v2(&arrayAcquired)==WVRCompositorStatusNoFrameAvailable, "unfinished GPU frame cannot block display queue");
    commands=[queue commandBuffer]; [commands encodeSignalEvent:ready value:2]; [commands commit]; [commands waitUntilCompleted];
    require(wvr_compositor_acquire_latest_stereo_frame_v2(&arrayAcquired)==0 && arrayAcquired.producerFrameID==8, "pending frame becomes available after GPU completion");
    wvr_compositor_release_acquired_frame_v1(arrayAcquired.lease);
    arrayFrame.producerTimestampNanoseconds=999'999'999'999; arrayFrame.producerFrameID=9;
    require(wvr_compositor_submit_stereo_frame_v2(&arrayFrame,&ticket)==0 && wvr_compositor_acquire_latest_stereo_frame_v2(&arrayAcquired)==0, "acquire frame with unknown pose timestamp");
    renderPose.structSize=sizeof(renderPose);
    require(wvr_compositor_copy_lease_tracking_v1(arrayAcquired.lease,&renderPose)==WVRCompositorStatusNoFrameAvailable, "missing render pose is not fabricated from latest tracking");
    wvr_compositor_release_acquired_frame_v1(arrayAcquired.lease);
    // Mirror DXMT ordering: submit to the native bridge BEFORE committing that
    // frame's command buffer, with three reusable resources waiting for their
    // prior consumer tickets. A producer may wait, the display must never wait.
    id<MTLSharedEvent> gate=[device newSharedEvent], delayedReady=[device newSharedEvent];
    id<MTLSharedEvent> consumed=(__bridge_transfer id<MTLSharedEvent>)wvr_compositor_copy_consumer_event_v1();
    std::atomic<unsigned> produced{0}; std::atomic<bool> producerDone{false};
    std::atomic<int32_t> producerStatus{0};
    std::thread producer([&] { @autoreleasepool {
        uint64_t tickets[18]={};
        for(unsigned index=0;index<18;++index) {
            id<MTLCommandBuffer> work=[queue commandBuffer];
            if(index<3) [work encodeWaitForEvent:gate value:1];
            else [work encodeWaitForEvent:consumed value:tickets[index-3]];
            [work encodeSignalEvent:delayedReady value:index+1];
            WVRSubmitStereoFrameV2 item=arrayFrame;
            item.producerReadyEvent=(__bridge void*)delayedReady;
            item.producerReadyValue=index+1;item.producerFrameID=100+index;
            int32_t status=wvr_compositor_submit_stereo_frame_v2(&item,&tickets[index]);
            if(status) {producerStatus=status;break;}
            [work commit]; produced.fetch_add(1);
        }
        producerDone=true;
    }});
    auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(3);
    while(produced.load()<3 && std::chrono::steady_clock::now()<deadline)
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    std::this_thread::sleep_for(std::chrono::milliseconds(25));
    bool preservedPending=produced.load()==3;
    gate.signaledValue=1;
    void *held=nullptr;uint64_t latest=0;
    deadline=std::chrono::steady_clock::now()+std::chrono::seconds(3);
    while(std::chrono::steady_clock::now()<deadline && latest!=117) {
        WVRAcquiredStereoFrameV2 next={};next.structSize=sizeof(next);
        if(wvr_compositor_acquire_latest_stereo_frame_v2(&next)==0) {
            if(held)wvr_compositor_release_acquired_frame_v1(held);
            held=next.lease;latest=next.producerFrameID;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    if(held)wvr_compositor_release_acquired_frame_v1(held);
    if(!producerDone.load())wvr_compositor_pause_v1();
    producer.join();
    require(preservedPending,"full pending queue applies producer backpressure instead of discarding every unfinished frame");
    require(producerStatus.load()==0 && produced.load()==18 && latest==117,"GPU producer and display progress with commit-after-submit and held frame leases");

    // Pause/exit must release a producer waiting on a full unfinished queue.
    delayedReady=[device newSharedEvent];
    arrayFrame.producerReadyEvent=(__bridge void*)delayedReady;arrayFrame.producerReadyValue=1;
    for(unsigned index=0;index<3;++index)
        require(wvr_compositor_submit_stereo_frame_v2(&arrayFrame,&ticket)==0,"fill pending queue for pause cancellation");
    std::atomic<bool> cancelledDone{false};std::atomic<int32_t> cancelledStatus{0};
    std::thread cancelled([&] { @autoreleasepool {
        uint64_t localTicket=0;
        cancelledStatus=wvr_compositor_submit_stereo_frame_v2(&arrayFrame,&localTicket);
        cancelledDone=true;
    }});
    std::this_thread::sleep_for(std::chrono::milliseconds(25));
    bool wasWaiting=!cancelledDone.load();wvr_compositor_pause_v1();cancelled.join();
    require(wasWaiting && cancelledStatus.load()==WVRCompositorStatusNoFrameAvailable,"pause cancels pending producer without publishing a stale frame");
    auto cancelPendingProducer=[&](bool exitSession) {
        require(wvr_compositor_publish_targets_v1(24,24,format,24,24,format)==0,"resume targets for blocked-producer cancellation");
        WVRRenderTargetInfoV1 current={};current.structSize=sizeof(current);
        require(wvr_compositor_copy_targets_v1(&current)==0,"read cancellation target generation");
        id<MTLSharedEvent> unfinished=[device newSharedEvent];
        auto pending=arrayFrame;pending.targetGeneration=current.generation;
        pending.producerReadyEvent=(__bridge void*)unfinished;pending.producerReadyValue=1;
        for(unsigned i=0;i<3;++i)require(wvr_compositor_submit_stereo_frame_v2(&pending,&ticket)==0,"fill cancellation queue");
        std::atomic<bool> done{false};std::atomic<int32_t> status{0};
        std::thread waiting([&] { @autoreleasepool {
            uint64_t ignored=0;status=wvr_compositor_submit_stereo_frame_v2(&pending,&ignored);done=true;
        }});
        std::this_thread::sleep_for(std::chrono::milliseconds(25));bool blocked=!done.load();
        if(exitSession)wvr_compositor_request_session_exit_v1();
        else require(wvr_compositor_publish_targets_v1(32,32,format,32,32,format)==0,"replace targets during pending submission");
        waiting.join();
        require(blocked && status.load()==(exitSession?WVRCompositorStatusNoFrameAvailable:WVRCompositorStatusIncompatibleTexture),
            exitSession?"session exit cancels pending producer":"target replacement rejects stale pending submission");
        wvr_compositor_pause_v1();
    };
    cancelPendingProducer(false);cancelPendingProducer(true);
    std::puts("SIMULATOR COMPOSITOR CHECKS PASSED");
    return 0;
} }
